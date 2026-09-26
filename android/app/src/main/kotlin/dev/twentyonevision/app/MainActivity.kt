package dev.twentyonevision.app

import android.content.ContentValues
import android.graphics.Color
import android.os.Bundle
import androidx.core.view.WindowCompat
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.media.MediaMetadataRetriever
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

import androidx.exifinterface.media.ExifInterface
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf

import dev.twentyonevision.app.embedder.EmbeddingEngine
import dev.twentyonevision.app.embedder.ScanEngineHolder
import dev.twentyonevision.app.embedder.ScanForegroundService
import dev.twentyonevision.app.embedder.ScanWorker
import dev.twentyonevision.app.embedder.VideoFrameExtractor
import dev.twentyonevision.app.embedder.faces.FaceClusterConfig
import dev.twentyonevision.app.embedder.faces.FaceModelKind
import dev.twentyonevision.app.embedder.faces.FaceScanHub
import dev.twentyonevision.app.embedder.faces.FaceScanWorker
import dev.twentyonevision.app.embedder.faces.FaceServices
import dev.twentyonevision.app.embedder.faces.FaceTuner
import dev.twentyonevision.app.embedder.faces.FaceSettings
import dev.twentyonevision.app.embedder.models.ModelManager
import dev.twentyonevision.app.embedder.models.ModelsNotReadyException

class MainActivity : FlutterActivity() {

    private val CHANNEL = "twentyonevision/native"
    private val PROGRESS_CHANNEL = "twentyonevision/progress"
    private val FACE_PROGRESS_CHANNEL = "twentyonevision/faceProgress"
    private val MODEL_DOWNLOAD_CHANNEL = "twentyonevision/modelDownload"
    private val PICK_REQUEST = 2001

    // A "compressed" load (loadImageBytes/loadVideoThumbnail) only ever
    // backs a grid thumbnail or, at most, a phone-sized full-screen view -
    // never worth decoding a multi-thousand-pixel original for. This caps
    // the longest side well above any phone screen's long edge, so it's
    // still sharp full-screen, while avoiding the memory a full-resolution
    // decode would cost for no visible benefit.
    private val MAX_COMPRESSED_DIMENSION = 1600

    private var pendingPickResult: MethodChannel.Result? = null
    // Both process-wide (ScanEngineHolder), not per-Activity instances -
    // see its doc for why a lateinit var here was the actual bug behind
    // "cancelEmbedding does nothing after the app is reopened from
    // Recents". These properties keep every existing call site unchanged.
    private val modelManager: ModelManager get() = ScanEngineHolder.modelManager(this)
    private val embeddingEngine: EmbeddingEngine get() = ScanEngineHolder.embeddingEngine(this)
    // The progress EventChannel's sink now lives on ScanForegroundService
    // (process-wide, not tied to this Activity instance) - see there for
    // why. modelDownloadSink doesn't need the same treatment: a model
    // download isn't kept alive by a foreground service, so it can't
    // outlive this Activity anyway.
    private var modelDownloadSink: EventChannel.EventSink? = null
    // Deliberately NOT process-wide, unlike modelManager/embeddingEngine
    // above - see ScanEngineHolder's doc for why sharing this one thread
    // between a running scan and quick queries like areModelsReady was
    // tried and caused those quick calls to hang behind the scan.
    private val executor = Executors.newSingleThreadExecutor()
    // Downloads get their own thread so a long-running download never blocks
    // unrelated calls (e.g. loading an already-cached thumbnail) sitting
    // behind it on the shared executor.
    private val downloadExecutor = Executors.newSingleThreadExecutor()
    // Search gets its own thread too, so it doesn't sit queued behind a
    // scan that can run for an hour or more. EmbeddingEngine/EmbeddingStore
    // are built to allow this now (locks around the shared vision module
    // and the on-disk store) - see their comments.
    private val searchExecutor = Executors.newSingleThreadExecutor()
    // Grid thumbnails only: a few in parallel so a collection's tiles fill in
    // together, and off searchExecutor so they never queue behind a search.
    private val thumbnailExecutor = Executors.newFixedThreadPool(3)
    // Face pictures get their own threads: a grid of photo thumbnails filling in
    // (or a search) must never make an avatar wait, and the other way round.
    private val faceCropExecutor = Executors.newFixedThreadPool(3)
    // Face detection has its own thread and detector (with its own ONNX
    // session), so it never waits behind - or holds up - search or a scan.
    private val faceExecutor = Executors.newSingleThreadExecutor()
    private val faces by lazy { FaceServices.get(applicationContext) }

    // Runs [block] on the face thread and hands its value (or its error) to Flutter.
    private fun faceTask(result: MethodChannel.Result, block: () -> Any?) {
        faceExecutor.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (e: Throwable) {
                runOnUiThread { result.error("FACE_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Draw behind the system bars, with the navigation bar (gesture
        // pill / 3-button strip) in the app background colour. Flutter's own
        // SystemChrome calls ask for this too, but some OEM skins (this app
        // was tested on a vivo/iQOO) keep an opaque black bar unless the
        // window itself opts in natively.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.WHITE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "pickFolder" -> {
                    if (pendingPickResult != null) {
                        result.error("BUSY", "Picker already open", null)
                        return@setMethodCallHandler
                    }
                    pendingPickResult = result
                    launchSafPicker(SafPickerActivity.MODE_FOLDER)
                }

                "pickImage" -> {
                    if (pendingPickResult != null) {
                        result.error("BUSY", "Picker already open", null)
                        return@setMethodCallHandler
                    }
                    pendingPickResult = result
                    launchSafPicker(SafPickerActivity.MODE_IMAGE)
                }


                "scanImagesAndOrVideos" -> {
                    val mode        = call.argument<String>("mode") ?: "folder"
                    val uri         = call.argument<String>("uri")
                    val folderId    = call.argument<String>("folderId") ?: "default"
                    val contentMode = call.argument<String>("contentMode") ?: "both"

                    // A quick check, not the scan itself - still needs a
                    // background thread since areModelsReady() can hash a
                    // whole model file (see its own handler's comment
                    // below). Enqueueing WorkManager work that would just
                    // immediately fail isn't worth it - better to report
                    // this the same way the old synchronous path did.
                    executor.execute {
                        if (!modelManager.areModelsReady()) {
                            runOnUiThread {
                                result.error(
                                    "MODELS_NOT_READY",
                                    "CLIP models are not downloaded yet",
                                    null
                                )
                            }
                            return@execute
                        }

                        val request = OneTimeWorkRequestBuilder<ScanWorker>()
                            .setInputData(
                                workDataOf(
                                    ScanWorker.KEY_MODE to mode,
                                    ScanWorker.KEY_URI to (uri ?: ""),
                                    ScanWorker.KEY_FOLDER_ID to folderId,
                                    ScanWorker.KEY_CONTENT_MODE to contentMode
                                )
                            )
                            .build()

                        // REPLACE, not APPEND - this is only ever called
                        // when the Dart side already knows nothing else is
                        // scanning (see NativeController.pickAndScanFolders'
                        // isScanning guard), so it's always "start the one
                        // scan", never a queue of several.
                        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                            ScanWorker.UNIQUE_WORK_NAME,
                            ExistingWorkPolicy.REPLACE,
                            request
                        )

                        // Resolves once the work is *enqueued*, not once it
                        // *finishes* - completion is reported entirely
                        // through the progress stream (see
                        // ScanForegroundService.pushProgress), which was
                        // already how NativeController tracked it even
                        // before this: a resumed scan (app reopened
                        // mid-scan) never had a pending RPC to await in the
                        // first place, so its done-handling already lived
                        // there, not here.
                        runOnUiThread { result.success(true) }
                    }
                }

                "areModelsReady" -> {
                    // isModelVerified() can occasionally hash a whole model
                    // file (see ModelManager) - never call it on the UI thread.
                    executor.execute {
                        val ready = modelManager.areModelsReady()
                        runOnUiThread { result.success(ready) }
                    }
                }

                "getModelInfo" -> {
                    executor.execute {
                        val statuses = modelManager.getModelStatuses().map {
                            mapOf(
                                "id"         to it.id,
                                "fileName"   to it.fileName,
                                "sizeBytes"  to it.sizeBytes,
                                "downloaded" to it.downloaded,
                                "verified"   to it.verified
                            )
                        }
                        runOnUiThread { result.success(statuses) }
                    }
                }

                "downloadModels" -> {
                    executor.execute {
                        if (modelManager.areModelsReady()) {
                            runOnUiThread { result.success(true) }
                            return@execute
                        }
                        if (!modelManager.hasEnoughFreeSpace()) {
                            runOnUiThread {
                                result.error(
                                    "INSUFFICIENT_STORAGE",
                                    "Not enough free space to download the models",
                                    null
                                )
                            }
                            return@execute
                        }

                        downloadExecutor.execute {
                            try {
                                modelManager.downloadAll { progress ->
                                    runOnUiThread {
                                        modelDownloadSink?.success(
                                            mapOf(
                                                "modelId"                to progress.modelId,
                                                "modelFileName"          to progress.modelFileName,
                                                "bytesForModel"          to progress.bytesForModel,
                                                "totalBytesForModel"     to progress.totalBytesForModel,
                                                "overallBytesDownloaded" to progress.overallBytesDownloaded,
                                                "overallTotalBytes"      to progress.overallTotalBytes,
                                                "done"                   to progress.done
                                            )
                                        )
                                    }
                                }
                                runOnUiThread { result.success(modelManager.areModelsReady()) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("DOWNLOAD_FAILED", e.message, null)
                                }
                            }
                        }
                    }
                }

                "cancelModelDownload" -> {
                    modelManager.cancelDownload()
                    result.success(true)
                }

                "deleteModels" -> {
                    modelManager.deleteModels()
                    result.success(true)
                }

                "getEmbeddingCount" -> {
                    result.success(embeddingEngine.getStoredCount())
                }

                "getEmbeddingCountForFolder" -> {
                    val folderId = call.argument<String>("folderId")
                    if (folderId == null) {
                        result.error("NO_FOLDERID", "folderId missing", null)
                        return@setMethodCallHandler
                    }
                    result.success(embeddingEngine.getStoredCountForFolder(folderId))
                }

                // Backs the Library tab's stat tiles - called on a timer
                // while a scan is running (see NativeController), not just
                // once it finishes, so it goes through searchExecutor like
                // search itself does rather than blocking the platform
                // thread with a readAll() of a potentially large store.
                "getLibraryStats" -> {
                    searchExecutor.execute {
                        val stats = embeddingEngine.getLibraryStats()
                        runOnUiThread {
                            result.success(
                                mapOf(
                                    "totalEmbeddings" to stats.totalEmbeddings,
                                    "images" to stats.images,
                                    "videos" to stats.videos,
                                    "sizeBytes" to stats.sizeBytes
                                )
                            )
                        }
                    }
                }

                "clearEmbeddings" -> {
                    embeddingEngine.clearAll()
                    result.success(true)
                }

                "encodeText" -> {
                    val tokens = call.argument<List<Int>>("tokens")
                    if (tokens == null || tokens.size != 77) {
                        result.error("INVALID_TOKENS", "Expected 77 tokens", null)
                        return@setMethodCallHandler
                    }
                    // Off the platform thread: the first call also loads both
                    // CLIP models from disk (hundreds of MB), and collections
                    // call this dozens of times in a row - on the main thread
                    // that froze the UI badly enough to get the app killed.
                    searchExecutor.execute {
                        try {
                            val embedding = embeddingEngine.encodeText(tokens.toIntArray())
                            runOnUiThread { result.success(embedding.toList()) }
                        } catch (e: ModelsNotReadyException) {
                            runOnUiThread { result.error("MODELS_NOT_READY", e.message, null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ENCODE_FAILED", e.message, null) }
                        }
                    }
                }

                "searchByText" -> {
                    val tokens = call.argument<List<Int>>("tokens")
                    val topK   = call.argument<Int>("topK") ?: 20
                    val contentMode = call.argument<String>("contentMode") ?: "both"

                    if (tokens == null || tokens.size != 77) {
                        result.error("INVALID_TOKENS", "Expected 77 tokens", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val textEmbedding = embeddingEngine.encodeText(tokens.toIntArray())
                            val results = embeddingEngine.searchByText(textEmbedding, topK, contentMode)

                            val mapped = results.map {
                                mapOf(
                                    "path"        to it.imagePath,
                                    "score"       to it.score,
                                    "isVideo"     to (it.videoUri != null),
                                    "videoUri"    to (it.videoUri ?: ""),
                                    "timestampMs" to it.timestampMs
                                )
                            }

                            runOnUiThread { result.success(mapped) }
                        } catch (e: ModelsNotReadyException) {
                            runOnUiThread { result.error("MODELS_NOT_READY", e.message, null) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("SEARCH_FAILED", e.message, null)
                            }
                        }
                    }
                }

                "searchByImage" -> {
                    val uriString = call.argument<String>("uri")
                    val topK      = call.argument<Int>("topK") ?: 20
                    val contentMode = call.argument<String>("contentMode") ?: "both"

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val embedding = embeddingEngine.encodeImageFromUri(uriString)
                            val results   = embeddingEngine.searchByImageEmbedding(embedding, topK, contentMode)

                            val mapped = results.map {
                                mapOf(
                                    "path"        to it.imagePath,
                                    "score"       to it.score,
                                    "isVideo"     to (it.videoUri != null),
                                    "videoUri"    to (it.videoUri ?: ""),
                                    "timestampMs" to it.timestampMs
                                )
                            }

                            runOnUiThread { result.success(mapped) }
                        } catch (e: ModelsNotReadyException) {
                            runOnUiThread { result.error("MODELS_NOT_READY", e.message, null) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("SEARCH_FAILED", e.message, null)
                            }
                        }
                    }
                }

                // Collections - see EmbeddingEngine's "Collections" section for
                // how membership is decided. Both go through searchExecutor
                // (a full read of the store, like search itself).
                "scoreCollections" -> {
                    val specs = parseCollectionSpecs(call)
                    if (specs == null) {
                        result.error("INVALID_ARGS", "collections missing", null)
                        return@setMethodCallHandler
                    }
                    searchExecutor.execute {
                        try {
                            val scores = embeddingEngine.scoreCollections(specs).map { s ->
                                mapOf(
                                    "id" to s.id,
                                    "count" to s.count,
                                    "covers" to s.covers.map {
                                        mapOf(
                                            "path" to it.imagePath,
                                            "isVideo" to (it.videoUri != null),
                                            "timestampMs" to it.timestampMs
                                        )
                                    }
                                )
                            }
                            runOnUiThread { result.success(scores) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("COLLECTIONS_FAILED", e.message, null) }
                        }
                    }
                }

                "collectionMembers" -> {
                    val spec = parseCollectionSpecs(call)?.firstOrNull()
                    val limit = call.argument<Int>("limit") ?: 200
                    if (spec == null) {
                        result.error("INVALID_ARGS", "collection missing", null)
                        return@setMethodCallHandler
                    }
                    searchExecutor.execute {
                        try {
                            val mapped = embeddingEngine.collectionMembers(spec, limit).map {
                                mapOf(
                                    "path"        to it.imagePath,
                                    "score"       to it.score,
                                    "isVideo"     to (it.videoUri != null),
                                    "videoUri"    to (it.videoUri ?: ""),
                                    "timestampMs" to it.timestampMs
                                )
                            }
                            runOnUiThread { result.success(mapped) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("COLLECTIONS_FAILED", e.message, null) }
                        }
                    }
                }

                // The raw embedding of a photo, or of one frame of a video
                // when a timestamp is given - what a photo-seeded collection
                // stores as its "query" (see CollectionsController).
                "encodeImage" -> {
                    val uriString = call.argument<String>("uri")
                    val timestampMs = (call.argument<Number>("timestampMs"))?.toLong()

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val embedding = if (timestampMs == null) {
                                embeddingEngine.encodeImageFromUri(uriString)
                            } else {
                                val uri = android.net.Uri.parse(uriString)
                                synchronized(VideoFrameExtractor.decodeLock) {
                                    val retriever = MediaMetadataRetriever()
                                    try {
                                        retriever.setDataSource(this, uri)
                                        val frame = retriever.getFrameAtTime(
                                            timestampMs * 1000L,
                                            MediaMetadataRetriever.OPTION_CLOSEST
                                        ) ?: throw Exception("Frame extraction failed")
                                        try {
                                            embeddingEngine.encodeBitmap(frame)
                                        } finally {
                                            frame.recycle()
                                        }
                                    } finally {
                                        try { retriever.release() } catch (_: Exception) {}
                                    }
                                }
                            }
                            runOnUiThread { result.success(embedding.toList()) }
                        } catch (e: ModelsNotReadyException) {
                            runOnUiThread { result.error("MODELS_NOT_READY", e.message, null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ENCODE_FAILED", e.message, null) }
                        }
                    }
                }

                // Image search seeded by one moment of a video (the frame
                // paused on in the video viewer) instead of a picked photo.
                // OPTION_CLOSEST (not the CLOSEST_SYNC the thumbnail loader
                // uses) - a thumbnail can settle for the nearest keyframe,
                // but a search should embed the frame actually on screen.
                "searchByVideoFrame" -> {
                    val uriString = call.argument<String>("uri")
                    val timestampMs = (call.argument<Number>("timestampMs") ?: 0).toLong()
                    val topK = call.argument<Int>("topK") ?: 20
                    val contentMode = call.argument<String>("contentMode") ?: "both"

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)

                            // Same decode lock as the thumbnail loader/scan
                            // frame extraction - see loadVideoThumbnail.
                            val embedding = synchronized(VideoFrameExtractor.decodeLock) {
                                val retriever = MediaMetadataRetriever()
                                try {
                                    retriever.setDataSource(this, uri)
                                    val frame = retriever.getFrameAtTime(
                                        timestampMs * 1000L,
                                        MediaMetadataRetriever.OPTION_CLOSEST
                                    ) ?: throw Exception("Frame extraction failed")
                                    try {
                                        embeddingEngine.encodeBitmap(frame)
                                    } finally {
                                        frame.recycle()
                                    }
                                } finally {
                                    try { retriever.release() } catch (_: Exception) {}
                                }
                            }

                            val results = embeddingEngine.searchByImageEmbedding(embedding, topK, contentMode)
                            val mapped = results.map {
                                mapOf(
                                    "path"        to it.imagePath,
                                    "score"       to it.score,
                                    "isVideo"     to (it.videoUri != null),
                                    "videoUri"    to (it.videoUri ?: ""),
                                    "timestampMs" to it.timestampMs
                                )
                            }
                            runOnUiThread { result.success(mapped) }
                        } catch (e: ModelsNotReadyException) {
                            runOnUiThread { result.error("MODELS_NOT_READY", e.message, null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SEARCH_FAILED", e.message, null) }
                        }
                    }
                }

                // "Why this matched" for one result - see EmbeddingEngine.
                // scoreWordsAgainstItem's doc for what this is (and isn't).
                // Called lazily when a result is actually opened, not for
                // every result a search returns.
                "explainMatch" -> {
                    val path = call.argument<String>("path")
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    val timestampMs = (call.argument<Number>("timestampMs") ?: 0).toLong()
                    @Suppress("UNCHECKED_CAST")
                    val wordsArg = call.argument<List<Map<String, Any>>>("words")

                    if (path == null || wordsArg == null) {
                        result.error("INVALID_ARGS", "path/words missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val itemEmbedding = embeddingEngine.findEmbedding(
                                imagePath = path,
                                videoUri = if (isVideo) path else null,
                                timestampMs = timestampMs
                            )
                            if (itemEmbedding == null) {
                                runOnUiThread { result.success(emptyList<Map<String, Any>>()) }
                                return@execute
                            }

                            val words = wordsArg.mapNotNull { entry ->
                                val word = entry["word"] as? String ?: return@mapNotNull null
                                @Suppress("UNCHECKED_CAST")
                                val tokens = (entry["tokens"] as? List<Int>)?.toIntArray()
                                    ?: return@mapNotNull null
                                if (tokens.size != 77) return@mapNotNull null
                                word to tokens
                            }

                            val scored = embeddingEngine.scoreWordsAgainstItem(itemEmbedding, words)
                            val mapped = scored.map { (word, score) ->
                                mapOf("word" to word, "score" to score)
                            }

                            runOnUiThread { result.success(mapped) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("EXPLAIN_FAILED", e.message, null) }
                        }
                    }
                }

                "loadImageBytes" -> {
                    val uriString    = call.argument<String>("uri")
                    val shouldCompress = call.argument<Boolean>("compress") ?: true

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)

                            val bitmap = if (shouldCompress) {
                                decodeSampledBitmap(uri, MAX_COMPRESSED_DIMENSION)
                            } else {
                                contentResolver.openInputStream(uri)?.use {
                                    BitmapFactory.decodeStream(it)
                                }
                            } ?: throw Exception("Cannot decode image")

                            val output = ByteArrayOutputStream()
                            if (shouldCompress) {
                                bitmap.compress(
                                    android.graphics.Bitmap.CompressFormat.JPEG, 85, output
                                )
                            } else {
                                bitmap.compress(
                                    android.graphics.Bitmap.CompressFormat.PNG, 100, output
                                )
                            }
                            bitmap.recycle()

                            runOnUiThread { result.success(output.toByteArray()) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("LOAD_FAILED", e.message, null)
                            }
                        }
                    }
                }

                // Grid-sized thumbnail (a few hundred px, not the 1600px a
                // full-screen view gets): decoding + re-encoding a huge bitmap
                // per tile was the slow part of a collection filling in. Runs
                // on a small pool so several decode at once.
                // ---- Faces ----
                // Everything below runs on faceExecutor (crops on the
                // thumbnail pool) so it never waits behind search or a scan.

                // Starts the automatic face scan (a no-op if it is already
                // running - unique work). Called on launch, when the Faces
                // tab opens, and after indexing finishes.
                "startFaceScan" -> faceTask(result) {
                    // Not while indexing runs (they'd compete; indexing starts
                    // it when it finishes) and only when there is something to do.
                    if (ScanForegroundService.isScanActive) false
                    else FaceScanWorker.enqueueIfNeeded(applicationContext)
                }

                "faceStatus" -> faceTask(result) {
                    val (photos, faceCount, people) = faces.store.stats()
                    val hub = FaceScanHub.last
                    mapOf(
                        "photos" to photos,
                        "faces" to faceCount,
                        "people" to people,
                        "running" to FaceScanHub.running,
                        "paused" to (hub?.get("paused") == true && FaceScanHub.running),
                        "userPaused" to FaceSettings.paused(applicationContext),
                        "processed" to photos,
                        "total" to ScanEngineHolder.embeddingEngine(applicationContext).indexedImages().size,
                        "failed" to (hub?.get("failed") ?: 0),
                        "runProcessed" to (hub?.get("runProcessed") ?: 0),
                        "elapsedMs" to (hub?.get("elapsedMs") ?: 0L),
                        "error" to hub?.get("error"),
                        "ready" to faces.engine.isReady(),
                        "thorough" to FaceSettings.thorough(applicationContext),
                        "refine" to FaceSettings.refine(applicationContext),
                        "deferredPhotos" to faces.store.deferredPhotoCount(),
                        "tuning" to FaceTuner.summary(applicationContext, faces.engine.store),
                        "strictness" to faces.clusterer.strictness(),
                        "modelsDir" to faces.engine.store.modelsDir.absolutePath,
                    )
                }

                // The user's own stop / go for the scan. Stopping is remembered, so
                // the automatic start leaves it alone until they resume.
                "pauseFaceScan" -> faceTask(result) {
                    FaceSettings.setPaused(applicationContext, true)
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(FaceScanWorker.UNIQUE_WORK_NAME)
                    true
                }

                "resumeFaceScan" -> faceTask(result) {
                    FaceSettings.setPaused(applicationContext, false)
                    FaceScanWorker.enqueueIfNeeded(applicationContext)
                }

                // Run the one-off speed test for this phone again.
                "retuneFaces" -> faceTask(result) {
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(FaceScanWorker.UNIQUE_WORK_NAME)
                    FaceTuner.reset(applicationContext)
                    FaceScanWorker.enqueueIfNeeded(applicationContext)
                }

                "listPeople" -> faceTask(result) {
                    val hidden = call.argument<Boolean>("hidden") ?: false
                    faces.store.listPeople(hidden).map { p ->
                        mapOf(
                            "id" to p.id,
                            "name" to p.name,
                            "hidden" to p.hidden,
                            "faceCount" to p.faceCount,
                            "photoCount" to p.photoCount,
                            "coverFaceId" to p.coverFaceId,
                        )
                    }
                }

                "personSummary" -> faceTask(result) {
                    val id = (call.argument<Number>("personId") ?: 0).toLong()
                    faces.store.personSummary(id)?.let { p ->
                        mapOf(
                            "id" to p.id,
                            "name" to p.name,
                            "hidden" to p.hidden,
                            "faceCount" to p.faceCount,
                            "photoCount" to p.photoCount,
                            "coverFaceId" to p.coverFaceId,
                        )
                    }
                }

                // Photos in the shape the search results grid already reads.
                "personPhotos" -> faceTask(result) {
                    val id = (call.argument<Number>("personId") ?: 0).toLong()
                    faces.store.personPhotos(id).map { (uri, _) ->
                        mapOf(
                            "path" to uri,
                            "score" to 1.0,
                            "isVideo" to false,
                            "videoUri" to "",
                            "timestampMs" to 0L,
                        )
                    }
                }

                "personFaces" -> faceTask(result) {
                    val id = (call.argument<Number>("personId") ?: 0).toLong()
                    faces.store.personFaces(id).map { f ->
                        mapOf("faceId" to f.faceId, "good" to f.good, "photoUri" to f.photoUri)
                    }
                }

                "faceCrop" -> {
                    val faceId = (call.argument<Number>("faceId") ?: 0).toLong()
                    val size = (call.argument<Number>("size") ?: 256).toInt()
                    faceCropExecutor.execute {
                        try {
                            val bytes = faces.crops.crop(faceId, size)
                            runOnUiThread {
                                if (bytes == null) result.error("NO_CROP", "Face not found", null)
                                else result.success(bytes)
                            }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("CROP_FAILED", e.message ?: e.toString(), null) }
                        }
                    }
                }

                "renamePerson" -> faceTask(result) {
                    faces.clusterer.rename(
                        (call.argument<Number>("personId") ?: 0).toLong(),
                        call.argument<String>("name"),
                    )
                    true
                }

                "hidePerson" -> faceTask(result) {
                    faces.clusterer.setHidden(
                        (call.argument<Number>("personId") ?: 0).toLong(),
                        call.argument<Boolean>("hidden") ?: true,
                    )
                    true
                }

                "mergePeople" -> faceTask(result) {
                    faces.clusterer.merge(
                        (call.argument<Number>("keepId") ?: 0).toLong(),
                        (call.argument<Number>("otherId") ?: 0).toLong(),
                    )
                    true
                }

                // Pairs of people who may be the same person, most likely first.
                "suggestMerges" -> faceTask(result) {
                    val limit = (call.argument<Number>("limit") ?: 20).toInt()
                    faces.clusterer.suggestMerges(limit).map {
                        mapOf("a" to it.aId, "b" to it.bId, "score" to it.score.toDouble())
                    }
                }

                "rejectMerge" -> faceTask(result) {
                    faces.clusterer.rejectMerge(
                        (call.argument<Number>("a") ?: 0).toLong(),
                        (call.argument<Number>("b") ?: 0).toLong(),
                    )
                    true
                }

                "removeFace" -> faceTask(result) {
                    faces.clusterer.removeFace((call.argument<Number>("faceId") ?: 0).toLong())
                    true
                }

                // Rebuild the automatic groups with the current strictness.
                "regroupFaces" -> faceTask(result) {
                    faces.clusterer.regroup()
                    true
                }

                // Forget every face and person (including names) and search all photos again.
                "resetFaces" -> faceTask(result) {
                    // Stop a running scan first so it doesn't write into the fresh start.
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(FaceScanWorker.UNIQUE_WORK_NAME)
                    // Asking to start over is asking for it to run.
                    FaceSettings.setPaused(applicationContext, false)
                    faces.store.wipeAll()
                    faces.clusterer.invalidate()
                    true
                }

                "setFaceSettings" -> faceTask(result) {
                    call.argument<Boolean>("thorough")?.let { FaceSettings.setThorough(applicationContext, it) }
                    call.argument<Boolean>("refine")?.let {
                        FaceSettings.setRefine(applicationContext, it)
                        // Turning it on has work to do right away.
                        if (it) FaceScanWorker.enqueueIfNeeded(applicationContext)
                    }
                    call.argument<String>("strictness")?.let {
                        if (it in listOf(FaceClusterConfig.STRICT, FaceClusterConfig.BALANCED, FaceClusterConfig.LOOSE)) {
                            faces.clusterer.setStrictness(it)
                        }
                    }
                    true
                }

                // The face models found on the device and which are in use.
                "faceModels" -> faceTask(result) {
                    val store = faces.engine.store
                    val models = FaceModelKind.values().flatMap { kind ->
                        val chosen = store.selected(kind)?.spec?.id
                        store.available(kind).map { m ->
                            mapOf(
                                "kind" to kind.name.lowercase(),
                                "id" to m.spec.id,
                                "name" to m.spec.displayName,
                                "sizeBytes" to m.sizeBytes,
                                "source" to m.source,
                                "selected" to (m.spec.id == chosen),
                            )
                        }
                    }
                    mapOf("dir" to store.modelsDir.absolutePath, "models" to models)
                }

                "selectFaceModel" -> faceTask(result) {
                    val kind = call.argument<String>("kind") ?: throw IllegalArgumentException("kind required")
                    val id = call.argument<String>("id") ?: throw IllegalArgumentException("id required")
                    // A running scan must not carry on with the other model.
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(FaceScanWorker.UNIQUE_WORK_NAME)
                    FaceSettings.setPaused(applicationContext, false)
                    faces.engine.store.select(FaceModelKind.valueOf(kind.uppercase()), id)
                    true
                }

                "loadThumbnail" -> {
                    val uriString   = call.argument<String>("uri")
                    val isVideo     = call.argument<Boolean>("isVideo") ?: false
                    val timestampMs = (call.argument<Number>("timestampMs") ?: 0).toLong()
                    val size        = (call.argument<Number>("size") ?: 400).toInt()

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    thumbnailExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)
                            val bitmap: android.graphics.Bitmap = if (isVideo) {
                                synchronized(VideoFrameExtractor.decodeLock) {
                                    val retriever = MediaMetadataRetriever()
                                    try {
                                        retriever.setDataSource(this, uri)
                                        val maybeFrame: android.graphics.Bitmap? = if (android.os.Build.VERSION.SDK_INT >= 27) {
                                            // The target size is given per axis, so work
                                            // it out from the video's own shape (after
                                            // rotation) to keep the frame undistorted.
                                            fun meta(key: Int) = retriever.extractMetadata(key)?.toIntOrNull() ?: 0
                                            var vw = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                                            var vh = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                                            val rotation = meta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                                            if (rotation == 90 || rotation == 270) { val t = vw; vw = vh; vh = t }
                                            val longest = maxOf(vw, vh)
                                            if (longest > size) {
                                                val k = size.toFloat() / longest
                                                retriever.getScaledFrameAtTime(
                                                    timestampMs * 1000L,
                                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                                    (vw * k).toInt().coerceAtLeast(1),
                                                    (vh * k).toInt().coerceAtLeast(1)
                                                )
                                            } else {
                                                retriever.getFrameAtTime(
                                                    timestampMs * 1000L,
                                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                                )
                                            }
                                        } else {
                                            retriever.getFrameAtTime(
                                                timestampMs * 1000L,
                                                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                            )
                                        }
                                        val frame = maybeFrame ?: throw Exception("Frame extraction failed")
                                        val scaled = capBitmapDimension(frame, size)
                                        if (scaled !== frame) frame.recycle()
                                        scaled
                                    } finally {
                                        try { retriever.release() } catch (_: Exception) {}
                                    }
                                }
                            } else {
                                decodeSampledBitmap(uri, size)
                                    ?: throw Exception("Cannot decode image")
                            }

                            val scaled = capBitmapDimension(bitmap, size)
                            val output = ByteArrayOutputStream()
                            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, output)
                            if (scaled !== bitmap) bitmap.recycle()
                            scaled.recycle()

                            runOnUiThread { result.success(output.toByteArray()) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("LOAD_FAILED", e.message, null) }
                        }
                    }
                }

                "loadVideoThumbnail" -> {
                    val uriString   = call.argument<String>("uri")
                    val timestampMs = (call.argument<Number>("timestampMs") ?: 0).toLong()

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)

                            // Same lock VideoFrameExtractor uses for a scan's
                            // own frame extraction - this can otherwise run
                            // at the same time as a scan decoding a *different*
                            // video (this is the "recently scanned" strip
                            // fetching a thumbnail for one it just embedded),
                            // and a device only has a handful of concurrent
                            // hardware video-decoder sessions. Without this,
                            // one or both silently fail under that
                            // contention - a missing thumbnail here, or that
                            // video getting silently skipped by the scan.
                            val bytes = synchronized(VideoFrameExtractor.decodeLock) {
                                val retriever = MediaMetadataRetriever()
                                try {
                                    retriever.setDataSource(this, uri)

                                    val bitmap = retriever.getFrameAtTime(
                                        timestampMs * 1000L,
                                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                    ) ?: throw Exception("Frame extraction failed")
                                    // A frame comes out at the video's own
                                    // resolution (often 1080p+) - capped for
                                    // the same reason loadImageBytes caps a
                                    // photo, just post-decode instead of
                                    // pre-decode (MediaMetadataRetriever
                                    // doesn't offer a sampling hint the way
                                    // BitmapFactory does).
                                    val scaled = capBitmapDimension(bitmap, MAX_COMPRESSED_DIMENSION)

                                    val output = ByteArrayOutputStream()
                                    scaled.compress(
                                        android.graphics.Bitmap.CompressFormat.JPEG, 85, output
                                    )
                                    if (scaled !== bitmap) bitmap.recycle()
                                    scaled.recycle()
                                    output.toByteArray()
                                } finally {
                                    try { retriever.release() } catch (_: Exception) {}
                                }
                            }

                            runOnUiThread { result.success(bytes) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("THUMBNAIL_FAILED", e.message, null)
                            }
                        }
                    }
                }

                "loadMetadataByUri" -> {
                    val uriString = call.argument<String>("uri")
                    val isVideo = call.argument<Boolean>("isVideo") ?: false

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)

                            var fileName = ""
                            var fileSize = 0L

                            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                                if (cursor.moveToFirst()) {
                                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                                    if (nameIndex >= 0) fileName = cursor.getString(nameIndex) ?: ""
                                    if (sizeIndex >= 0) fileSize = cursor.getLong(sizeIndex)
                                }
                            }

                            val mimeType = contentResolver.getType(uri) ?: ""

                            val metadata = if (isVideo) {
                                loadVideoMetadata(uri, fileName, fileSize, mimeType)
                            } else {
                                loadImageMetadata(uri, fileName, fileSize, mimeType)
                            }
                            // Both keys point at the same string - "uri" is
                            // what identifies the file to other native calls
                            // (share/save/wallpaper), "imagePath" is what
                            // ImageMetadata.fromMap actually reads for the
                            // sheet's "File path" row. This used to only set
                            // "uri", so that row always showed "Unknown."
                            metadata["uri"] = uriString
                            metadata["imagePath"] = uriString

                            runOnUiThread { result.success(metadata) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("LOAD_METADATA_FAILED", e.message ?: "Invalid URI", null)
                            }
                        }
                    }
                }

                "shareFile" -> {
                    val uriString = call.argument<String>("uri")
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = android.net.Uri.parse(uriString)
                        val mimeType = contentResolver.getType(uri) ?: if (isVideo) "video/*" else "image/*"
                        val shareIntent = Intent(Intent.ACTION_SEND).apply {
                            type = mimeType
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(Intent.createChooser(shareIntent, null).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        })
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                }

                "saveCopyToGallery" -> {
                    val uriString = call.argument<String>("uri")
                    val isVideo = call.argument<Boolean>("isVideo") ?: false
                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }
                    searchExecutor.execute {
                        try {
                            saveCopyToGallery(android.net.Uri.parse(uriString), isVideo)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE_FAILED", e.message, null) }
                        }
                    }
                }

                "setAsWallpaper" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }
                    searchExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)
                            contentResolver.openInputStream(uri)?.use { input ->
                                android.app.WallpaperManager.getInstance(applicationContext)
                                    .setStream(input)
                            } ?: throw Exception("Cannot open image")
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("WALLPAPER_FAILED", e.message, null) }
                        }
                    }
                }

                "copyImageToClipboard" -> {
                    val uriString = call.argument<String>("uri")
                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = android.net.Uri.parse(uriString)
                        val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
                        clipboard.setPrimaryClip(
                            android.content.ClipData.newUri(contentResolver, "Image", uri)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CLIPBOARD_FAILED", e.message, null)
                    }
                }

                "deleteEmbeddingsByFolderId" -> {
                    val folderId = call.argument<String>("folderId")

                    if (folderId == null) {
                        result.error("NO_FOLDERID", "folderId missing", null)
                        return@setMethodCallHandler
                    }

                    executor.execute {
                        try {
                            embeddingEngine.deleteEmbeddingsForFolder(folderId)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("DELETION_FAILED", e.message, null)
                            }
                        }
                    }
                }

                "cancelEmbedding" -> {
                    embeddingEngine.cancelEmbedding()
                    result.success(true)
                }

                // Asked by a freshly (re)created Dart layer on init - e.g.
                // after the app was removed from Recents and reopened,
                // which recreates the Activity/Flutter engine without
                // killing a scan already running (see ScanForegroundService's
                // progressSink doc). Null if nothing is currently scanning.
                //
                // No "retryBackgroundScan" handler anymore - that existed
                // to promote the old Service to foreground after the user
                // granted notification permission mid-scan, since it was
                // only ever started once. ScanWorker calls setForeground()
                // unconditionally as soon as a scan starts, regardless of
                // notification permission state, so there's nothing to
                // retry: the next notify() call after permission is
                // granted just starts succeeding on its own.
                //
                // No battery-optimization-exemption handlers anymore
                // either - Play policy only allows requesting that for a
                // short list of core-function use cases (real-time fitness/
                // navigation/VoIP/IoT) that this app doesn't fit, and
                // WorkManager's own retry-after-interruption is the
                // replacement: instead of asking to not be killed, the
                // scan now survives being killed.
                "getActiveScanProgress" -> {
                    result.success(ScanForegroundService.activeProgress())
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROGRESS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                ScanForegroundService.setProgressSink(events)
            }
            override fun onCancel(arguments: Any?) {
                ScanForegroundService.setProgressSink(null)
            }
        })

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FACE_PROGRESS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                FaceScanHub.sink = events
            }
            override fun onCancel(arguments: Any?) {
                FaceScanHub.sink = null
            }
        })

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MODEL_DOWNLOAD_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                modelDownloadSink = events
            }
            override fun onCancel(arguments: Any?) {
                modelDownloadSink = null
            }
        })
    }

    private fun parseCollectionSpecs(
        call: io.flutter.plugin.common.MethodCall
    ): List<EmbeddingEngine.CollectionSpec>? {
        val raw = call.argument<List<Map<String, Any>>>("collections") ?: return null
        return raw.mapNotNull { entry ->
            val id = entry["id"] as? String ?: return@mapNotNull null
            val embedding = (entry["embedding"] as? List<*>)
                ?.map { (it as Number).toFloat() }
                ?.toFloatArray() ?: return@mapNotNull null
            EmbeddingEngine.CollectionSpec(
                id = id,
                embedding = embedding,
                contentMode = entry["contentMode"] as? String ?: "both",
                k = (entry["k"] as? Number)?.toDouble() ?: 3.0
            )
        }
    }

    // The bounds+EXIF half of loadMetadataByUri, split out so the handler
    // can pick this or loadVideoMetadata below by isVideo instead of one
    // branchy function trying to do both.
    private fun loadImageMetadata(
        uri: android.net.Uri,
        fileName: String,
        fileSize: Long,
        mimeType: String
    ): HashMap<String, Any?> {
        var width = 0
        var height = 0

        contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFileDescriptor(pfd.fileDescriptor, null, options)
            width = options.outWidth
            height = options.outHeight
        }

        val exif = try {
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd -> ExifInterface(pfd.fileDescriptor) }
        } catch (e: Exception) {
            null
        }

        return hashMapOf<String, Any?>(
            "fileName" to fileName,
            "fileSize" to fileSize,
            "mimeType" to mimeType,
            "width" to width,
            "height" to height,
            "durationMs" to 0L,
            "orientation" to (exif?.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            ) ?: 0),
            "dateTime" to (exif?.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
                ?: exif?.getAttribute(ExifInterface.TAG_DATETIME) ?: ""),
            "cameraMake" to (exif?.getAttribute(ExifInterface.TAG_MAKE) ?: ""),
            "cameraModel" to (exif?.getAttribute(ExifInterface.TAG_MODEL) ?: ""),
            "latitude" to exif?.latLong?.getOrNull(0),
            "longitude" to exif?.latLong?.getOrNull(1)
        )
    }

    // Video has no EXIF/BitmapFactory bounds to read - MediaMetadataRetriever
    // is the video-shaped equivalent. No camera/GPS/orientation fields (videos
    // don't carry them the same way) - the metadata sheet already hides those
    // sections when they're empty, so this just leaves them out rather than
    // faking a value.
    private fun loadVideoMetadata(
        uri: android.net.Uri,
        fileName: String,
        fileSize: Long,
        mimeType: String
    ): HashMap<String, Any?> {
        var width = 0
        var height = 0
        var durationMs = 0L

        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(this, uri)
            width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                ?.toIntOrNull() ?: 0
            height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                ?.toIntOrNull() ?: 0
            durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
        } catch (e: Exception) {
            // A corrupt/unusual video shouldn't fail the whole sheet - it
            // just shows zeros, same as any other "unknown" field here.
        } finally {
            try { retriever.release() } catch (e: Exception) {}
        }

        return hashMapOf<String, Any?>(
            "fileName" to fileName,
            "fileSize" to fileSize,
            "mimeType" to mimeType,
            "width" to width,
            "height" to height,
            "durationMs" to durationMs,
            "orientation" to 0,
            "dateTime" to "",
            "cameraMake" to "",
            "cameraModel" to "",
            "latitude" to null,
            "longitude" to null
        )
    }

    // Copies the source content straight into a new MediaStore entry rather
    // than writing to a raw file path - the only way that reliably works
    // across every Android version this app supports without needing
    // WRITE_EXTERNAL_STORAGE on modern (scoped-storage) devices. IS_PENDING
    // brackets the copy on API 29+ so nothing else sees a half-written file
    // in the gallery mid-copy.
    private fun saveCopyToGallery(uri: android.net.Uri, isVideo: Boolean) {
        val mimeType = contentResolver.getType(uri) ?: if (isVideo) "video/mp4" else "image/jpeg"
        val extension = if (isVideo) "mp4" else "jpg"
        val fileName = "Vector_${System.currentTimeMillis()}.$extension"

        val collection = if (isVideo) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val destUri = contentResolver.insert(collection, values)
            ?: throw Exception("Could not create a destination entry in the gallery")

        contentResolver.openInputStream(uri)?.use { input ->
            contentResolver.openOutputStream(destUri)?.use { output ->
                input.copyTo(output)
            } ?: throw Exception("Could not open the destination for writing")
        } ?: throw Exception("Could not open the source file")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            contentResolver.update(
                destUri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null
            )
        }
    }

    // Standard two-pass bitmap loading: read just the dimensions first
    // (inJustDecodeBounds - cheap, doesn't allocate pixel data), work out
    // a power-of-two sample size from that, then do the real decode
    // *at* the reduced size. Costs one extra stream open/close over a
    // plain decodeStream, but never allocates a full-resolution bitmap
    // just to immediately shrink it - the difference that matters for a
    // multi-thousand-pixel photo destined for a small grid tile.
    private fun decodeSampledBitmap(uri: android.net.Uri, maxDimension: Int): android.graphics.Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // Checked by whether the stream itself opened, not by the decode's
        // return value - inJustDecodeBounds always returns a null bitmap by
        // design (that's the whole point of a bounds-only pass), so relying
        // on that null to mean "failed to open" was returning null here for
        // every image unconditionally, valid or not.
        val boundsStream = contentResolver.openInputStream(uri) ?: return null
        boundsStream.use { BitmapFactory.decodeStream(it, null, bounds) }

        var sampleSize = 1
        val longestSide = maxOf(bounds.outWidth, bounds.outHeight)
        if (longestSide > 0) {
            while (longestSide / sampleSize > maxDimension) {
                sampleSize *= 2
            }
        }

        val decodeOptions = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        return contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, decodeOptions)
        }
    }

    // Scales down only if needed - returns the same bitmap untouched
    // otherwise. Used where the decode itself can't be sampled down
    // directly (a video frame from MediaMetadataRetriever), unlike
    // decodeSampledBitmap above which avoids the full-size allocation
    // entirely.
    private fun capBitmapDimension(
        bitmap: android.graphics.Bitmap,
        maxDimension: Int
    ): android.graphics.Bitmap {
        val longestSide = maxOf(bitmap.width, bitmap.height)
        if (longestSide <= maxDimension) return bitmap
        val scale = maxDimension.toFloat() / longestSide
        val targetWidth = (bitmap.width * scale).toInt().coerceAtLeast(1)
        val targetHeight = (bitmap.height * scale).toInt().coerceAtLeast(1)
        return android.graphics.Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
    }

    private fun launchSafPicker(mode: String) {
        val intent = Intent(this, SafPickerActivity::class.java).apply {
            putExtra(SafPickerActivity.EXTRA_MODE, mode)
        }
        startActivityForResult(intent, PICK_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != PICK_REQUEST) return

        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return

        if (resultCode != RESULT_OK || data == null) {
            result.error("CANCELLED", "Picking cancelled", null)
            return
        }

        val uri = data.getStringExtra(SafPickerActivity.EXTRA_URI)
        if (uri == null) {
            result.error("NO_URI", "No URI returned", null)
            return
        }

        result.success(uri)
    }
}