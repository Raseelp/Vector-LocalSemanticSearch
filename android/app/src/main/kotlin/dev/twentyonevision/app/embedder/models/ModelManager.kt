package dev.twentyonevision.app.embedder.models

import android.content.Context
import android.os.StatFs
import android.util.Log
import dev.twentyonevision.app.BuildConfig
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

// Downloads, verifies, and deletes the on-device CLIP model files.
// Files live in context.filesDir - private, no permission needed, cleaned
// up on uninstall.
class ModelManager(private val context: Context) {

    @Volatile
    private var isCancelled = false

    private val prefs = context.getSharedPreferences("model_manager", Context.MODE_PRIVATE)

    init {
        cleanupLegacyPyTorchModels()
        cleanupLegacyFaceModels()
    }

    // The face recognition model is bundled in the app now (see FaceModelStore), not
    // downloaded: remove what earlier versions downloaded - the accurate model (170 MB) and
    // the downloaded copy of the small one - and forget that they were verified. (A model
    // someone put in the external folder by hand is theirs: only the old accurate model's
    // files are removed from there.)
    private fun cleanupLegacyFaceModels() {
        val old = listOf("w600k_r50.onnx", "w600k_r50.onnx.part", "w600k_r50.json")
        val downloadedCopyOfBundled = listOf("w600k_mbf.onnx", "w600k_mbf.onnx.part")
        File(context.filesDir, "face_models").let { dir -> (old + downloadedCopyOfBundled).forEach { File(dir, it).delete() } }
        context.getExternalFilesDir("face_models")?.let { dir -> old.forEach { File(dir, it).delete() } }
        val stale = prefs.all.keys.filter { it.startsWith("verified_face_recognition") }
        if (stale.isNotEmpty()) prefs.edit().apply { stale.forEach { remove(it) } }.apply()
    }

    // One-time migration cleanup: the CLIP models moved from TorchScript
    // (.pt, loaded by PyTorch Mobile) to ONNX under new file names, so
    // RemoteModel's catalog no longer points at these - without this they'd
    // sit in context.filesDir forever, orphaned, on every device that had
    // already downloaded them. Harmless to run on every launch: once gone,
    // File.delete() is a silent no-op.
    private fun cleanupLegacyPyTorchModels() {
        for (name in listOf("clip_vision_ts.pt", "clip_text_ts.pt")) {
            File(context.filesDir, name).delete()
            File(context.filesDir, "$name.part").delete()
        }
    }

    companion object {
        private const val PROGRESS_INTERVAL_MS = 250L
        private const val MAX_ATTEMPTS = 5
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val BUFFER_SIZE = 64 * 1024
        private const val FREE_SPACE_MULTIPLIER = 1.3
    }

    fun localFile(model: RemoteModel): File = File(context.filesDir, model.fileName)

    private fun partFile(model: RemoteModel): File = File(context.filesDir, "${model.fileName}.part")

    private fun verifiedKey(model: RemoteModel) = "verified_${model.id}_${model.sha256}"

    fun isModelVerified(model: RemoteModel): Boolean {
        seedFromDebugAssetsIfPresent(model)

        val file = localFile(model)
        if (!file.exists() || file.length() != model.sizeBytes) return false

        if (prefs.getBoolean(verifiedKey(model), false)) return true

        // Right size but not flagged verified - e.g. the file was copied
        // into place directly (local testing) instead of coming through
        // downloadOne(). Hash it once to confirm, and cache the result so
        // this only costs anything the first time. Callers on the UI
        // thread must not call this before a download has ever run without
        // going through a background thread first - this can be slow.
        val matches = sha256Of(file).equals(model.sha256, ignoreCase = true)
        if (matches) {
            prefs.edit().putBoolean(verifiedKey(model), true).apply()
        }
        return matches
    }

    // Search and indexing need only the CLIP models - the face model is optional
    // and never holds those back.
    fun areModelsReady(): Boolean = ModelCatalog.MODELS.all { isModelVerified(it) }

    fun getModelStatuses(): List<ModelStatus> = ModelCatalog.ALL.map { m ->
        val f = localFile(m)
        ModelStatus(
            id = m.id,
            fileName = m.fileName,
            sizeBytes = m.sizeBytes,
            downloaded = f.exists() && f.length() == m.sizeBytes,
            verified = isModelVerified(m),
            group = m.group
        )
    }

    fun bytesNeededToDownload(models: List<RemoteModel> = ModelCatalog.MODELS): Long =
        models.filterNot { isModelVerified(it) }.sumOf { it.sizeBytes }

    fun hasEnoughFreeSpace(models: List<RemoteModel> = ModelCatalog.MODELS): Boolean {
        val stat = StatFs(context.filesDir.path)
        val free = stat.availableBytes
        val needed = bytesNeededToDownload(models)
        if (needed == 0L) return true
        return free > (needed * FREE_SPACE_MULTIPLIER).toLong()
    }

    fun cancelDownload() {
        isCancelled = true
    }

    /** Deletes the CLIP models (search and indexing stop until they are downloaded again). */
    fun deleteModels() = delete(ModelCatalog.MODELS)

    private fun delete(models: List<RemoteModel>) {
        for (m in models) {
            localFile(m).delete()
            partFile(m).delete()
            prefs.edit().remove(verifiedKey(m)).apply()
        }
    }

    // Downloads every not-yet-verified model of [models] in order (put the ones
    // that matter most first - a failure later on doesn't lose what is done).
    // Safe to call again after a cancel or failure - already-verified models are
    // skipped and partial downloads resume.
    fun download(models: List<RemoteModel>, onProgress: (ModelDownloadProgress) -> Unit) {
        isCancelled = false

        val pending = models.filterNot { isModelVerified(it) }
        val overallTotal = models.sumOf { it.sizeBytes }
        var overallDoneBeforeThisModel =
            models.filter { isModelVerified(it) }.sumOf { it.sizeBytes }

        for (model in pending) {
            if (isCancelled) return
            downloadOne(model, overallDoneBeforeThisModel, overallTotal, onProgress)
            overallDoneBeforeThisModel += model.sizeBytes
        }
    }

    private fun downloadOne(
        model: RemoteModel,
        overallDoneBeforeThisModel: Long,
        overallTotal: Long,
        onProgress: (ModelDownloadProgress) -> Unit
    ) {
        val target = localFile(model)
        val part = partFile(model)

        // Stale complete-looking file that doesn't match the current manifest
        // (e.g. model was updated) - discard and start clean.
        if (target.exists() && target.length() != model.sizeBytes) target.delete()

        var existingLength = if (part.exists()) part.length() else 0L
        if (existingLength > model.sizeBytes) {
            part.delete()
            existingLength = 0L
        }

        var attempt = 0
        var lastEmit = 0L

        while (true) {
            try {
                val connection = URL(model.url).openConnection() as HttpURLConnection
                connection.connectTimeout = CONNECT_TIMEOUT_MS
                connection.readTimeout = READ_TIMEOUT_MS
                if (existingLength > 0) {
                    connection.setRequestProperty("Range", "bytes=$existingLength-")
                }
                connection.connect()

                val serverHonoredResume = connection.responseCode == HttpURLConnection.HTTP_PARTIAL
                if (existingLength > 0 && !serverHonoredResume) {
                    // Server ignored the Range request - fall back to a full re-download.
                    existingLength = 0L
                    part.delete()
                }

                if (connection.responseCode !in 200..299) {
                    val code = connection.responseCode
                    connection.disconnect()
                    throw IOException("HTTP $code for ${model.url}")
                }

                RandomAccessFile(part, "rw").use { raf ->
                    raf.seek(existingLength)
                    connection.inputStream.use { input ->
                        val buffer = ByteArray(BUFFER_SIZE)
                        var readBytes: Int
                        var written = existingLength
                        while (input.read(buffer).also { readBytes = it } != -1) {
                            if (isCancelled) return
                            raf.write(buffer, 0, readBytes)
                            written += readBytes

                            val now = System.currentTimeMillis()
                            if (now - lastEmit > PROGRESS_INTERVAL_MS) {
                                onProgress(
                                    ModelDownloadProgress(
                                        modelId = model.id,
                                        modelFileName = model.fileName,
                                        bytesForModel = written,
                                        totalBytesForModel = model.sizeBytes,
                                        overallBytesDownloaded = overallDoneBeforeThisModel + written,
                                        overallTotalBytes = overallTotal,
                                        done = false
                                    )
                                )
                                lastEmit = now
                            }
                        }
                    }
                }
                connection.disconnect()
                break
            } catch (e: Exception) {
                if (isCancelled) return
                attempt++
                existingLength = if (part.exists()) part.length() else 0L
                if (attempt >= MAX_ATTEMPTS) throw e
                Thread.sleep(1000L * attempt)
            }
        }

        if (isCancelled) return

        // Every byte is here; what follows (size and checksum) takes a few
        // seconds on a big file. Say so - the app shows "checking", not a bar
        // frozen just short of the end.
        onProgress(
            ModelDownloadProgress(
                modelId = model.id,
                modelFileName = model.fileName,
                bytesForModel = model.sizeBytes,
                totalBytesForModel = model.sizeBytes,
                overallBytesDownloaded = overallDoneBeforeThisModel + model.sizeBytes,
                overallTotalBytes = overallTotal,
                done = false
            )
        )

        if (part.length() != model.sizeBytes) {
            throw IOException(
                "Downloaded size mismatch for ${model.fileName}: " +
                    "expected ${model.sizeBytes}, got ${part.length()}"
            )
        }

        val actualHash = sha256Of(part)
        if (!actualHash.equals(model.sha256, ignoreCase = true)) {
            part.delete()
            throw IOException("Checksum mismatch for ${model.fileName} - download was corrupted")
        }

        if (target.exists()) target.delete()
        if (!part.renameTo(target)) {
            throw IOException("Could not finalize ${model.fileName}")
        }

        prefs.edit().putBoolean(verifiedKey(model), true).apply()

        onProgress(
            ModelDownloadProgress(
                modelId = model.id,
                modelFileName = model.fileName,
                bytesForModel = model.sizeBytes,
                totalBytesForModel = model.sizeBytes,
                overallBytesDownloaded = overallDoneBeforeThisModel + model.sizeBytes,
                overallTotalBytes = overallTotal,
                done = true
            )
        )
    }

    // Debug convenience: if a model file is sitting in
    // android/app/src/debug/assets/ (a debug-only source set - Gradle never
    // includes it in a release build, so this can't bloat a real release
    // APK even by accident), copy it into place so the app skips the
    // download screen entirely. No-ops instantly whenever nothing's there,
    // which is the normal case for everyone who isn't using this.
    private fun seedFromDebugAssetsIfPresent(model: RemoteModel) {
        if (!BuildConfig.DEBUG) return

        val target = localFile(model)
        if (target.exists() && target.length() == model.sizeBytes) return

        try {
            context.assets.open(model.fileName).use { input ->
                FileOutputStream(target).use { output ->
                    input.copyTo(output, BUFFER_SIZE)
                }
            }
            Log.d("ModelManager", "Seeded ${model.fileName} from debug assets")
        } catch (e: IOException) {
            // Not bundled for this build - the normal case, nothing to do.
        }
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(BUFFER_SIZE)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
