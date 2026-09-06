package dev.twentyonevision.app.embedder.models

import android.content.Context
import android.os.StatFs
import java.io.File
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

    fun areModelsReady(): Boolean = ModelCatalog.MODELS.all { isModelVerified(it) }

    fun getModelStatuses(): List<ModelStatus> = ModelCatalog.MODELS.map { m ->
        val f = localFile(m)
        ModelStatus(
            id = m.id,
            fileName = m.fileName,
            sizeBytes = m.sizeBytes,
            downloaded = f.exists() && f.length() == m.sizeBytes,
            verified = isModelVerified(m)
        )
    }

    fun bytesNeededToDownload(): Long =
        ModelCatalog.MODELS.filterNot { isModelVerified(it) }.sumOf { it.sizeBytes }

    fun hasEnoughFreeSpace(): Boolean {
        val stat = StatFs(context.filesDir.path)
        val free = stat.availableBytes
        val needed = bytesNeededToDownload()
        if (needed == 0L) return true
        return free > (needed * FREE_SPACE_MULTIPLIER).toLong()
    }

    fun cancelDownload() {
        isCancelled = true
    }

    fun deleteModels() {
        for (m in ModelCatalog.MODELS) {
            localFile(m).delete()
            partFile(m).delete()
            prefs.edit().remove(verifiedKey(m)).apply()
        }
    }

    // Downloads every not-yet-verified model in order. Safe to call again
    // after a cancel or failure - already-verified models are skipped and
    // partial downloads resume.
    fun downloadAll(onProgress: (ModelDownloadProgress) -> Unit) {
        isCancelled = false

        val pending = ModelCatalog.MODELS.filterNot { isModelVerified(it) }
        val overallTotal = ModelCatalog.totalBytes
        var overallDoneBeforeThisModel =
            ModelCatalog.MODELS.filter { isModelVerified(it) }.sumOf { it.sizeBytes }

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
