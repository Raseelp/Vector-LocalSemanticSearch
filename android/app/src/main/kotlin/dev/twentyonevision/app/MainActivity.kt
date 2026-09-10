package dev.twentyonevision.app

import android.content.Intent
import android.os.Bundle
import android.graphics.BitmapFactory
import android.provider.OpenableColumns
import android.media.MediaMetadataRetriever
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

import androidx.exifinterface.media.ExifInterface

import dev.twentyonevision.app.embedder.EmbeddingEngine
import dev.twentyonevision.app.embedder.ScanForegroundService
import dev.twentyonevision.app.embedder.ScanProgress
import dev.twentyonevision.app.embedder.ScanResult
import dev.twentyonevision.app.embedder.models.ModelManager
import dev.twentyonevision.app.embedder.models.ModelsNotReadyException

class MainActivity : FlutterActivity() {

    private val CHANNEL = "twentyonevision/native"
    private val PROGRESS_CHANNEL = "twentyonevision/progress"
    private val MODEL_DOWNLOAD_CHANNEL = "twentyonevision/modelDownload"
    private val PICK_REQUEST = 2001

    private var pendingPickResult: MethodChannel.Result? = null
    private lateinit var embeddingEngine: EmbeddingEngine
    private lateinit var modelManager: ModelManager
    private var progressSink: EventChannel.EventSink? = null
    private var modelDownloadSink: EventChannel.EventSink? = null
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        modelManager = ModelManager(this)
        embeddingEngine = EmbeddingEngine(this, modelManager)
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

                    executor.execute {
                        ScanForegroundService.start(applicationContext)
                        try {
                            embeddingEngine.embedImages(mode, uri, folderId, contentMode) { progress ->
                                runOnUiThread {
                                    progressSink?.success(
                                        mapOf(
                                            "total"     to progress.total,
                                            "processed" to progress.processed,
                                            "embedded"  to progress.embedded,
                                            "elapsedMs" to progress.elapsedMs,
                                            "skipped"   to progress.skipped,
                                            "done"      to progress.done,
                                            "path"      to progress.path,
                                            "recentItems" to progress.recentItems.map {
                                                mapOf(
                                                    "uri" to it.uri,
                                                    "isVideo" to it.isVideo,
                                                    "timestampMs" to it.timestampMs
                                                )
                                            }
                                        )
                                    )
                                }
                                ScanForegroundService.updateProgress(
                                    progress.processed, progress.total, progress.embedded
                                )
                            }
                            runOnUiThread { result.success(true) }
                        } catch (e: ModelsNotReadyException) {
                            runOnUiThread { result.error("MODELS_NOT_READY", e.message, null) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("SCAN_FAILED", e.message, null)
                            }
                        } finally {
                            // Covers every exit path uniformly: a normal finish
                            // and a cancellation both end with embedImages()
                            // returning after its own done=true emission, and a
                            // hard failure hits this without ever emitting one -
                            // either way the notification must not outlive the scan.
                            ScanForegroundService.stop(applicationContext)
                        }
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
                    try {
                        val embedding = embeddingEngine.encodeText(tokens.toIntArray())
                        result.success(embedding.toList())
                    } catch (e: ModelsNotReadyException) {
                        result.error("MODELS_NOT_READY", e.message, null)
                    }
                }

                "searchByText" -> {
                    val tokens = call.argument<List<Int>>("tokens")
                    val topK   = call.argument<Int>("topK") ?: 20

                    if (tokens == null || tokens.size != 77) {
                        result.error("INVALID_TOKENS", "Expected 77 tokens", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val textEmbedding = embeddingEngine.encodeText(tokens.toIntArray())
                            val results = embeddingEngine.searchByText(textEmbedding, topK)

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

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val embedding = embeddingEngine.encodeImageFromUri(uriString)
                            val results   = embeddingEngine.searchByImageEmbedding(embedding, topK)

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

                "loadImageBytes" -> {
                    val uriString    = call.argument<String>("uri")
                    val shouldCompress = call.argument<Boolean>("compress") ?: true

                    if (uriString == null) {
                        result.error("NO_URI", "URI missing", null)
                        return@setMethodCallHandler
                    }

                    searchExecutor.execute {
                        try {
                            val uri         = android.net.Uri.parse(uriString)
                            val inputStream = contentResolver.openInputStream(uri)
                                ?: throw Exception("Cannot open URI")

                            val bitmap = BitmapFactory.decodeStream(inputStream)
                            inputStream.close()

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

                            runOnUiThread { result.success(output.toByteArray()) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("LOAD_FAILED", e.message, null)
                            }
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
                            val uri       = android.net.Uri.parse(uriString)
                            val retriever = MediaMetadataRetriever()

                            val bytes = try {
                                retriever.setDataSource(this, uri)

                                val bitmap = retriever.getFrameAtTime(
                                    timestampMs * 1000L,
                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                ) ?: throw Exception("Frame extraction failed")

                                val output = ByteArrayOutputStream()
                                bitmap.compress(
                                    android.graphics.Bitmap.CompressFormat.JPEG, 85, output
                                )
                                bitmap.recycle()
                                output.toByteArray()
                            } finally {
                                try { retriever.release() } catch (_: Exception) {}
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

                            var width  = 0
                            var height = 0

                            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                                val options = BitmapFactory.Options().apply {
                                    inJustDecodeBounds = true
                                }
                                BitmapFactory.decodeFileDescriptor(
                                    pfd.fileDescriptor, null, options
                                )
                                width  = options.outWidth
                                height = options.outHeight
                            }

                            val exif = try {
                                contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                                    ExifInterface(pfd.fileDescriptor)
                                }
                            } catch (e: Exception) {
                                null
                            }

                            val metadata = hashMapOf<String, Any?>(
                                "fileName"    to fileName,
                                "fileSize"    to fileSize,
                                "mimeType"    to mimeType,
                                "width"       to width,
                                "height"      to height,
                                "orientation" to (exif?.getAttributeInt(
                                    ExifInterface.TAG_ORIENTATION,
                                    ExifInterface.ORIENTATION_NORMAL
                                ) ?: 0),
                                "dateTime"    to (exif?.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
                                    ?: exif?.getAttribute(ExifInterface.TAG_DATETIME) ?: ""),
                                "cameraMake"  to (exif?.getAttribute(ExifInterface.TAG_MAKE) ?: ""),
                                "cameraModel" to (exif?.getAttribute(ExifInterface.TAG_MODEL) ?: ""),
                                "latitude"    to exif?.latLong?.getOrNull(0),
                                "longitude"   to exif?.latLong?.getOrNull(1),
                                "uri"         to uriString
                            )

                            runOnUiThread { result.success(metadata) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("LOAD_METADATA_FAILED", e.message ?: "Invalid URI", null)
                            }
                        }
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

                // Called right after the user grants notification permission
                // mid-scan - start() was only ever fired once, at scan start,
                // so without this the service (and its notification) never
                // appears until the *next* scan.
                "retryBackgroundScan" -> {
                    ScanForegroundService.start(applicationContext)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROGRESS_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                progressSink = events
            }
            override fun onCancel(arguments: Any?) {
                progressSink = null
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