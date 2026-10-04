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
import dev.twentyonevision.app.embedder.BenchLog
import dev.twentyonevision.app.embedder.faces.FaceClusterConfig
import dev.twentyonevision.app.embedder.faces.FaceFollower
import dev.twentyonevision.app.embedder.faces.FaceModelKind
import dev.twentyonevision.app.embedder.faces.FaceScanHub
import dev.twentyonevision.app.embedder.faces.FaceScanWorker
import dev.twentyonevision.app.embedder.faces.FaceServices
import dev.twentyonevision.app.embedder.faces.PhotoScanProgress
import dev.twentyonevision.app.embedder.faces.FaceTuner
import dev.twentyonevision.app.embedder.faces.FaceSettings
import dev.twentyonevision.app.embedder.models.ModelCatalog
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
    // the longest side well above a normal grid tile's size, so it's still
    // sharp, while avoiding the memory a full-resolution decode would cost
    // for no visible benefit. This is the default for every tile; a bento
    // tile bigger than normal asks for one of the three caps below instead
    // (via the optional "maxDimension" argument both calls accept) rather
    // than this cap being raised for every tile just to satisfy a handful
    // of them.
    private val MAX_COMPRESSED_DIMENSION = 1600

    // For the bento grid's 2-cell wide/tall filler tiles (next to a hero or
    // showcase) - a little bigger than a normal 1-cell tile, so only a
    // small bump over MAX_COMPRESSED_DIMENSION is needed.
    private val MAX_COMPRESSED_DIMENSION_WIDE = 1900

    // For the bento grid's 2x2 hero tile - noticeably bigger than a normal
    // tile, but nowhere near as big as an 8/16-slot showcase, so it only
    // needs a modest bump over MAX_COMPRESSED_DIMENSION, not the showcase
    // cap below.
    private val MAX_COMPRESSED_DIMENSION_HERO = 2200

    // For the bento grid's 8-slot/16-slot showcase tiles specifically
    // (search_results.dart decides which indices qualify), so raising this
    // doesn't cost anything for the normal case - typically only a handful
    // of these decode per screen, unlike MAX_COMPRESSED_DIMENSION above
    // which every single grid thumbnail shares.
    private val MAX_COMPRESSED_DIMENSION_SHOWCASE = 3200

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
    // A photo opened in the viewer that the face scan hasn't reached yet is analysed on
    // its own thread, so it doesn't queue behind the other face calls.
    private val photoFacesExecutor = Executors.newSingleThreadExecutor()
    // A whole video is scanned on its own thread too: it can take a while, and must not hold up
    // the quick look-ups (a photo's faces, the paused frame of a video).
    private val videoScanExecutor = Executors.newSingleThreadExecutor()
    // Viewers that were closed before their photo's turn came (one photo is scanned at a time),
    // by the token each viewer sent: those requests are skipped instead of scanned for nobody.
    private val cancelledPhotoScans: MutableSet<Long> = java.util.concurrent.ConcurrentHashMap.newKeySet()
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
                                "verified"   to it.verified,
                                "group"      to it.group
                            )
                        }
                        runOnUiThread { result.success(statuses) }
                    }
                }

                "downloadModels" -> {
                    // The search (CLIP) models - the only ones downloaded; the face models
                    // are bundled in the app.
                    val requested = ModelCatalog.MODELS
                    executor.execute {
                        if (requested.all { modelManager.isModelVerified(it) }) {
                            runOnUiThread { result.success(true) }
                            return@execute
                        }
                        if (!modelManager.hasEnoughFreeSpace(requested)) {
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
                                modelManager.download(requested) { progress ->
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
                                runOnUiThread {
                                    result.success(requested.all { modelManager.isModelVerified(it) })
                                }
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

                // Deletes the downloaded (search) models. People already found and the
                // search index are kept; search and indexing wait until the models are
                // downloaded again. The face models are part of the app and stay.
                "deleteModels" -> faceTask(result) {
                    modelManager.deleteModels()
                    true
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

                // The performance logs (adb logcat -s VectorBench), on unless turned off.
                "getBenchLogs" -> result.success(BenchLog.enabled(applicationContext))

                "setBenchLogs" -> {
                    BenchLog.setEnabled(applicationContext, call.argument<Boolean>("enabled") ?: true)
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
                    // "@name"s (or plain recognised names) in the search box: the person half
                    // of the query, resolved here to their shared photos/videos via FaceStore -
                    // "together" mode, same as peoplePhotos' own default reading of several
                    // names side by side - and handed to EmbeddingEngine as a plain path
                    // restriction, not anything it needs to know is about people at all.
                    //
                    // mapNotNull + safe cast, not a direct List<Number> cast + .map{it.toLong()}:
                    // the latter throws (ClassCastException/NPE) on any malformed element instead
                    // of just dropping it, same defensive parsing parseCollectionSpecs uses below.
                    val personIds = (call.argument<List<*>>("personIds"))
                        ?.mapNotNull { (it as? Number)?.toLong() }
                        ?: emptyList()

                    if (tokens == null || tokens.size != 77) {
                        result.error("INVALID_TOKENS", "Expected 77 tokens", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val pathFilter = if (personIds.isEmpty()) null else
                                faces.store.peopleMedia(personIds, "together").map { it.uri }.toSet()
                            val textEmbedding = embeddingEngine.encodeText(tokens.toIntArray())
                            val results = embeddingEngine.searchByText(textEmbedding, topK, contentMode, pathFilter)

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
                            val scores = embeddingEngine.scoreCollections(resolvePathFilters(specs)).map { s ->
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
                            val resolvedSpec = resolvePathFilters(listOf(spec)).first()
                            val mapped = embeddingEngine.collectionMembers(resolvedSpec, limit).map {
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
                    val maxDimension = ((call.argument<Number>("maxDimension"))?.toInt()
                        ?: MAX_COMPRESSED_DIMENSION).coerceAtLeast(1)

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val uri = android.net.Uri.parse(uriString)

                            val bitmap = if (shouldCompress) {
                                decodeSampledBitmap(uri, maxDimension)
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
                    // While indexing runs, faces are found in step with it (set up when it
                    // starts; this covers it not being set up, e.g. after the model was
                    // downloaded mid-scan). Otherwise the face worker, and only when there
                    // is something to do.
                    if (ScanForegroundService.isScanActive) FaceFollower.start(applicationContext)
                    else FaceScanWorker.enqueueIfNeeded(applicationContext)
                }

                "faceStatus" -> faceTask(result) {
                    val (photos, faceCount, people) = faces.store.stats()
                    val hub = FaceScanHub.last
                    mapOf(
                        "photos" to photos,
                        "faces" to faceCount,
                        "people" to people,
                        // Finding faces in step with an indexing scan counts as running
                        // even between the batches it works through.
                        "running" to (FaceScanHub.running || FaceFollower.isArmed()),
                        "paused" to (hub?.get("paused") == true && FaceScanHub.running),
                        "following" to FaceFollower.isArmed(),
                        "batch" to (hub?.get("batch") == true && FaceScanHub.running),
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
                        "scanVideos" to FaceSettings.scanVideos(applicationContext),
                        "videoDensity" to FaceSettings.videoDensity(applicationContext),
                        "videos" to faces.store.videoCount(),
                        "videosTotal" to ScanEngineHolder.embeddingEngine(applicationContext).indexedVideos().size,
                        "tuning" to FaceTuner.summary(applicationContext, faces.engine.store),
                        "strictness" to faces.clusterer.strictness(),
                        "modelsDir" to faces.engine.store.modelsDir.absolutePath,
                    )
                }

                // The user's own stop / go for the scan. Stopping is remembered, so
                // the automatic start leaves it alone until they resume.
                "pauseFaceScan" -> faceTask(result) {
                    FaceSettings.setPaused(applicationContext, true)
                    FaceFollower.stop()
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(FaceScanWorker.UNIQUE_WORK_NAME)
                    true
                }

                "resumeFaceScan" -> faceTask(result) {
                    FaceSettings.setPaused(applicationContext, false)
                    if (ScanForegroundService.isScanActive) FaceFollower.start(applicationContext)
                    else FaceScanWorker.enqueueIfNeeded(applicationContext)
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

                // Photos and videos in the shape the search results grid already reads.
                "personPhotos" -> faceTask(result) {
                    val id = (call.argument<Number>("personId") ?: 0).toLong()
                    faces.store.personMedia(id).map { m ->
                        mapOf(
                            "path" to m.uri,
                            "score" to 1.0,
                            "isVideo" to m.isVideo,
                            "videoUri" to (if (m.isVideo) m.uri else ""),
                            "timestampMs" to m.tsMs,
                        )
                    }
                }

                // Photos by several people at once. [mode]: any / together / only
                // (see FaceStore.peoplePhotos). Same shape as personPhotos.
                "peoplePhotos" -> faceTask(result) {
                    val ids = (call.argument<List<Number>>("personIds") ?: emptyList()).map { it.toLong() }
                    val mode = call.argument<String>("mode") ?: "together"
                    faces.store.peopleMedia(ids, mode).map { m ->
                        mapOf(
                            "path" to m.uri,
                            "score" to 1.0,
                            "isVideo" to m.isVideo,
                            "videoUri" to (if (m.isVideo) m.uri else ""),
                            "timestampMs" to m.tsMs,
                        )
                    }
                }

                "peopleCounts" -> faceTask(result) {
                    val ids = (call.argument<List<Number>>("personIds") ?: emptyList()).map { it.toLong() }
                    faces.store.peopleCounts(ids)
                }

                "personFaces" -> faceTask(result) {
                    val id = (call.argument<Number>("personId") ?: 0).toLong()
                    faces.store.personFaces(id).map { f ->
                        mapOf("faceId" to f.faceId, "good" to f.good, "photoUri" to f.photoUri, "isVideo" to f.isVideo)
                    }
                }

                // The people in one photo, for tapping their faces in the viewer (hidden people stay out).
                // Who is in the frame at [positionMs] of a video (looked up now). The faces that match people
                // are stored as that frame of the video, so tapping them later is instant.
                "videoFaces" -> photoFacesExecutor.execute {
                    try {
                        val uri = call.argument<String>("uri") ?: ""
                        val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                        val token = call.argument<Number>("token")?.toLong()
                        if (token != null && cancelledPhotoScans.remove(token)) {
                            runOnUiThread { result.success(emptyList<Any>()) }
                            return@execute
                        }
                        val key = "$uri#$positionMs"
                        val progress = PhotoScanProgress()
                        faces.scanner.photoProgress[key] = progress
                        val identities = try {
                            faces.videoScanner.identifyFrame(uri, positionMs, progress)
                        } finally {
                            faces.scanner.photoProgress.remove(key)
                        } ?: emptyList()
                        // Named in this video now: they join its list of people, and their faces are stored.
                        try {
                            faces.store.recordVideoSeen(uri, positionMs, identities.map { it.personId }.toSet())
                            // And kept as real faces of that frame, so tapping them later is instant.
                            faces.videoScanner.storeLooked(uri, positionMs, identities)
                        } catch (_: Throwable) {
                        }
                        val out = identities.mapIndexedNotNull { i, f ->
                            val p = faces.store.personSummary(f.personId)
                            if (p == null || p.hidden) {
                                null
                            } else {
                                mapOf(
                                    // Not a stored face: a made-up id, just to tell them apart on screen.
                                    "faceId" to -(i + 1).toLong(),
                                    "left" to f.left, "top" to f.top, "right" to f.right, "bottom" to f.bottom,
                                    "photoW" to f.frameW, "photoH" to f.frameH,
                                    "person" to mapOf(
                                        "id" to p.id,
                                        "name" to p.name,
                                        "hidden" to p.hidden,
                                        "faceCount" to p.faceCount,
                                        "photoCount" to p.photoCount,
                                        "coverFaceId" to p.coverFaceId,
                                    ),
                                )
                            }
                        }
                        runOnUiThread { result.success(out) }
                    } catch (e: Throwable) {
                        runOnUiThread { result.error("VIDEO_FACES_FAILED", e.message ?: e.toString(), null) }
                    }
                }

                // The faces the scan stored for the frame at exactly [tsMs]: they can be shown at once
                // (no new look) when [exact] says the scan read exact frames.
                "videoFrameFaces" -> faceTask(result) {
                    val uri = call.argument<String>("uri") ?: ""
                    val tsMs = (call.argument<Number>("tsMs") ?: 0).toLong()
                    val (exact, stored) = faces.store.videoFrameFaces(uri, tsMs)
                    val summaries = HashMap<Long, dev.twentyonevision.app.embedder.faces.PersonSummary?>()
                    val list = stored.mapNotNull { f ->
                        val p = summaries.getOrPut(f.personId) { faces.store.personSummary(f.personId) }
                        if (p == null || p.hidden) {
                            null
                        } else {
                            mapOf(
                                "faceId" to f.faceId,
                                "left" to f.boxL, "top" to f.boxT, "right" to f.boxR, "bottom" to f.boxB,
                                "photoW" to f.photoW, "photoH" to f.photoH,
                                "person" to mapOf(
                                    "id" to p.id,
                                    "name" to p.name,
                                    "hidden" to p.hidden,
                                    "faceCount" to p.faceCount,
                                    "photoCount" to p.photoCount,
                                    "coverFaceId" to p.coverFaceId,
                                ),
                            )
                        }
                    }
                    mapOf("exact" to exact, "faces" to list)
                }

                // The people seen in a video (found by a scan) and when: for the strip and the markers
                // under the video. Unhidden people known elsewhere, or seen at 2+ moments of this video.
                "videoPeople" -> faceTask(result) {
                    val uri = call.argument<String>("uri") ?: ""
                    val times = LinkedHashMap<Long, MutableList<Long>>()
                    // The moments where a face of theirs is stored (a position to point at).
                    val stored = HashMap<Long, MutableList<Long>>()
                    for ((personId, ts) in faces.store.videoSightings(uri)) {
                        times.getOrPut(personId) { ArrayList() }.add(ts)
                        stored.getOrPut(personId) { ArrayList() }.add(ts)
                    }
                    // Also the people found by looking at single frames: they were named on purpose,
                    // so they count without needing two moments.
                    val looked = HashSet<Long>()
                    for ((personId, ts) in faces.store.videoSeen(uri)) {
                        times.getOrPut(personId) { ArrayList() }.add(ts)
                        looked += personId
                    }
                    times.mapNotNull { (personId, list) ->
                        val p = faces.store.personSummary(personId)
                        // Someone known elsewhere, or seen in at least two moments of this video (one
                        // stray frame is more likely a bystander).
                        val enough = p != null &&
                            (p.photoCount >= dev.twentyonevision.app.embedder.faces.FaceStore.MIN_PHOTOS_TO_SHOW ||
                                list.distinct().size >= 2 || personId in looked)
                        if (p == null || p.hidden || !enough) {
                            null
                        } else {
                            mapOf(
                                "person" to mapOf(
                                    "id" to p.id,
                                    "name" to p.name,
                                    "hidden" to p.hidden,
                                    "faceCount" to p.faceCount,
                                    "photoCount" to p.photoCount,
                                    "coverFaceId" to p.coverFaceId,
                                ),
                                "times" to list.distinct().sorted(),
                                "stored" to (stored[personId] ?: emptyList<Long>()).distinct().sorted(),
                            )
                        }
                    }
                }

                // Whether a video can be scanned and has been: "needs", "done" or "unavailable"
                // (not in the search index, or the face models aren't ready).
                // Also which search level a tap would use (looser when the last look found nothing) and
                // how many faces the last look kept.
                "videoScanState" -> faceTask(result) {
                    val plan = faces.scanner.videoScanPlan(call.argument<String>("uri") ?: "")
                    mapOf("state" to plan.state, "level" to plan.level, "lastFaces" to plan.lastFaces)
                }

                // A video the user asked to scan: scan it now if it hasn't been (see FaceScanner.scanVideoNow).
                // Progress is readable meanwhile with photoScanStatus("video:<uri>").
                "scanVideoFaces" -> videoScanExecutor.execute {
                    try {
                        val uri = call.argument<String>("uri") ?: ""
                        val token = call.argument<Number>("token")?.toLong()
                        if (token != null && cancelledPhotoScans.remove(token)) {
                            runOnUiThread { result.success(mapOf("scanned" to false, "level" to 0, "faces" to 0)) }
                            return@execute
                        }
                        val scanned = try {
                            faces.scanner.scanVideoNow(uri)
                        } catch (e: Throwable) {
                            android.util.Log.w("MainActivity", "scanning video $uri failed: ${e.message}")
                            dev.twentyonevision.app.embedder.faces.FaceScanner.VideoScanResult(false, 0, 0)
                        }
                        runOnUiThread {
                            result.success(mapOf("scanned" to scanned.scanned, "level" to scanned.level, "faces" to scanned.faces))
                        }
                    } catch (e: Throwable) {
                        runOnUiThread { result.error("SCAN_VIDEO_FAILED", e.message ?: e.toString(), null) }
                    }
                }

                "cancelPhotoFaces" -> {
                    (call.argument<Number>("token"))?.let {
                        if (cancelledPhotoScans.size > 200) cancelledPhotoScans.clear()
                        cancelledPhotoScans.add(it.toLong())
                    }
                    result.success(true)
                }

                "photoFaces" -> photoFacesExecutor.execute {
                    try {
                        val uri = call.argument<String>("uri") ?: ""
                        val token = call.argument<Number>("token")?.toLong()
                        if (token != null && cancelledPhotoScans.remove(token)) {
                            runOnUiThread { result.success(emptyList<Any>()) }
                            return@execute
                        }
                        // Not scanned yet: scan it. Scanned, but with faces still unrecognised: finish them.
                        // If that goes wrong, whatever faces are already stored are still returned.
                        try {
                            faces.scanner.scanOne(uri)
                        } catch (e: Throwable) {
                            android.util.Log.w("MainActivity", "scanning $uri failed: ${e.message}")
                        }
                        val summaries = HashMap<Long, dev.twentyonevision.app.embedder.faces.PersonSummary?>()
                        val found = faces.store.photoFaces(uri).mapNotNull { f ->
                            val p = summaries.getOrPut(f.personId) { faces.store.personSummary(f.personId) }
                            if (p == null || p.hidden) {
                                null
                            } else {
                                mapOf(
                                    "faceId" to f.faceId,
                                    "left" to f.boxL, "top" to f.boxT, "right" to f.boxR, "bottom" to f.boxB,
                                    "photoW" to f.photoW, "photoH" to f.photoH,
                                    "person" to mapOf(
                                        "id" to p.id,
                                        "name" to p.name,
                                        "hidden" to p.hidden,
                                        "faceCount" to p.faceCount,
                                        "photoCount" to p.photoCount,
                                        "coverFaceId" to p.coverFaceId,
                                    ),
                                )
                            }
                        }
                        runOnUiThread { result.success(found) }
                    } catch (e: Throwable) {
                        runOnUiThread { result.error("PHOTO_FACES_FAILED", e.message ?: e.toString(), null) }
                    }
                }

                // How far the scan of a photo opened in the viewer has got (null when none is running).
                "photoScanStatus" -> faceTask(result) {
                    faces.scanner.photoProgress[call.argument<String>("uri") ?: ""]?.let { p ->
                        mapOf(
                            "stage" to p.stage, "faces" to p.faces, "total" to p.total, "more" to p.more,
                            "video" to p.video, "step" to p.step, "steps" to p.steps, "relax" to p.relax,
                        )
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

                // Returns the merge's history id (for "Undo"), 0 if nothing was merged.
                "mergePeople" -> faceTask(result) {
                    faces.clusterer.merge(
                        (call.argument<Number>("keepId") ?: 0).toLong(),
                        (call.argument<Number>("otherId") ?: 0).toLong(),
                    )
                }

                // Past merges that can still be undone, newest first.
                "mergeHistory" -> faceTask(result) {
                    faces.store.mergeHistory().map { r ->
                        mapOf(
                            "id" to r.id,
                            "keptId" to r.keptId,
                            "keptName" to r.keptName,
                            "keptCover" to r.keptCover,
                            "removedName" to r.removedName,
                            "removedCover" to r.removedCover,
                            "faceCount" to r.faceIds.size,
                            "createdAt" to r.createdAt,
                        )
                    }
                }

                // The two groups a person's faces fall into (null if too few clear faces).
                "previewSplit" -> faceTask(result) {
                    faces.clusterer.previewSplit((call.argument<Number>("personId") ?: 0).toLong())?.let { p ->
                        mapOf(
                            "first" to p.first,
                            "second" to p.second,
                            "firstCovers" to p.firstCovers,
                            "secondCovers" to p.secondCovers,
                        )
                    }
                }

                "splitPerson" -> faceTask(result) {
                    val ids = (call.argument<List<Number>>("faceIds") ?: emptyList()).map { it.toLong() }
                    faces.clusterer.splitPerson((call.argument<Number>("personId") ?: 0).toLong(), ids)
                }

                "undoMerge" -> faceTask(result) {
                    faces.clusterer.undoMerge((call.argument<Number>("id") ?: 0).toLong())
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
                    FaceFollower.stop()
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
                        // Only a setting: the face scan never starts by itself (see FaceScanWorker).
                        FaceSettings.setRefine(applicationContext, it)
                    }
                    call.argument<String>("strictness")?.let {
                        if (it in listOf(FaceClusterConfig.STRICT, FaceClusterConfig.BALANCED, FaceClusterConfig.LOOSE)) {
                            faces.clusterer.setStrictness(it)
                        }
                    }
                    call.argument<String>("videoDensity")?.let { FaceSettings.setVideoDensity(applicationContext, it) }
                    call.argument<Boolean>("scanVideos")?.let {
                        FaceSettings.setScanVideos(applicationContext, it)
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
                    FaceFollower.stop()
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
                    val maxDimension = ((call.argument<Number>("maxDimension"))?.toInt()
                        ?: MAX_COMPRESSED_DIMENSION).coerceAtLeast(1)

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
                                    val scaled = capBitmapDimension(bitmap, maxDimension)

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
                    // A scan that is running but has not reported yet (WorkManager starts one again
                    // by itself after the app was killed): say it is starting, so the app shows it
                    // instead of offering to start another.
                    result.success(
                        ScanForegroundService.activeProgress()
                            ?: if (ScanForegroundService.isScanActive) mapOf(
                                "id" to "",
                                "total" to 0,
                                "processed" to 0,
                                "embedded" to 0,
                                "elapsedMs" to 0L,
                                "skipped" to 0,
                                "done" to false,
                                "path" to "",
                                "recentItems" to emptyList<Map<String, Any>>(),
                            ) else null
                    )
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
            val personIds = (entry["personIds"] as? List<*>)
                ?.mapNotNull { (it as? Number)?.toLong() }
                ?: emptyList()
            EmbeddingEngine.CollectionSpec(
                id = id,
                embedding = embedding,
                contentMode = entry["contentMode"] as? String ?: "both",
                k = (entry["k"] as? Number)?.toDouble() ?: 3.0,
                personIds = personIds
            )
        }
    }

    // Resolves each spec's personIds (from an "@name" search) to an actual
    // pathFilter via FaceStore - same "together" reading of several people
    // searchByText's own personIds uses. Called from inside a
    // searchExecutor.execute{} block, never before dispatching to one:
    // peopleMedia is a real SQLite read, and parseCollectionSpecs above
    // runs synchronously on whichever thread the channel call arrives on.
    private fun resolvePathFilters(
        specs: List<EmbeddingEngine.CollectionSpec>
    ): List<EmbeddingEngine.CollectionSpec> = specs.map { spec ->
        if (spec.personIds.isEmpty()) spec else spec.copy(
            pathFilter = faces.store.peopleMedia(spec.personIds, "together").map { it.uri }.toSet()
        )
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