package dev.twentyonevision.app.embedder

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters

// Runs the scan as WorkManager work, not a plain executor thread inside a
// Service this app manages itself. The actual embedding logic
// (EmbeddingEngine.embedImages) doesn't change at all - it's already
// idempotent (already-embedded files are skipped by hash), which is
// exactly the property that makes WorkManager's "guaranteed execution"
// meaningful here: if the OS kills this process mid-scan, WorkManager
// reschedules this same work to run again later, and re-entering
// embedImages() from the top just fast-skips everything already done
// instead of duplicating it. That's the actual fix for the "background
// scan stops after ~10 minutes and never resumes on its own" problem -
// not preventing the kill (nothing can promise that on every OEM), but
// making a kill a non-event instead of a dead end.
class ScanWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val mode = inputData.getString(KEY_MODE) ?: "folder"
        val uri = inputData.getString(KEY_URI)
        val folderId = inputData.getString(KEY_FOLDER_ID) ?: "default"
        val contentMode = inputData.getString(KEY_CONTENT_MODE) ?: "both"

        ScanForegroundService.onScanStarting(applicationContext)

        try {
            setForeground(createForegroundInfo())
        } catch (e: Exception) {
            // Background-start restrictions, etc. The scan still runs
            // regardless of this - losing the notification/keep-alive
            // protection isn't worth failing the whole scan over.
            Log.w(TAG, "doWork: setForeground failed, continuing anyway: ${e.message}")
        }

        return try {
            val embeddingEngine = ScanEngineHolder.embeddingEngine(applicationContext)
            embeddingEngine.embedImages(mode, uri, folderId, contentMode) { progress ->
                val map = mapOf(
                    "id" to folderId,
                    "total" to progress.total,
                    "processed" to progress.processed,
                    "embedded" to progress.embedded,
                    "elapsedMs" to progress.elapsedMs,
                    "skipped" to progress.skipped,
                    "failed" to progress.failed,
                    "done" to progress.done,
                    "path" to progress.path,
                    "recentItems" to progress.recentItems.map {
                        mapOf(
                            "uri" to it.uri,
                            "isVideo" to it.isVideo,
                            "timestampMs" to it.timestampMs
                        )
                    }
                )
                ScanForegroundService.pushProgress(map)

                val notification = ScanForegroundService.updateProgress(
                    applicationContext,
                    progress.processed,
                    progress.total,
                    progress.embedded,
                    progress.elapsedMs
                )
                try {
                    NotificationManagerCompat.from(applicationContext)
                        .notify(ScanForegroundService.NOTIFICATION_ID, notification)
                } catch (e: Exception) {
                    // Most likely a revoked POST_NOTIFICATIONS permission -
                    // the notification just won't be visible, which is fine.
                }
            }
            // The photos just indexed are ready for face grouping.
            dev.twentyonevision.app.embedder.faces.FaceScanWorker.enqueueIfNeeded(applicationContext)
            Result.success()
        } catch (e: Exception) {
            // embedImages already catches per-file problems internally
            // (a bad photo, a failed embed) as a skip, not an exception -
            // reaching here means something genuinely unexpected happened.
            // Emits a synthetic "done" tick with whatever was reached so
            // far, so the Dart side's existing done-handling still fires
            // and isScanning doesn't get stuck true forever - unlike the
            // old architecture, there's no synchronous RPC failure to fall
            // back on anymore now that scanImagesAndOrVideos returns as
            // soon as the work is enqueued, not when it finishes.
            Log.e(TAG, "doWork: embedImages failed: ${e.message}", e)
            ScanForegroundService.pushProgress(
                mapOf(
                    "id" to folderId,
                    "total" to 0,
                    "processed" to 0,
                    "embedded" to 0,
                    "elapsedMs" to 0L,
                    "skipped" to 0,
                    "done" to true,
                    "path" to "",
                    "recentItems" to emptyList<Map<String, Any>>()
                )
            )
            // Not retry() - a genuinely unexpected failure (as opposed to
            // this process simply being killed, which WorkManager already
            // retries on its own regardless of the Result returned here)
            // retrying automatically could just repeat the same failure
            // indefinitely for no benefit. The user's own "scan again"
            // action is the right way to try again for this case.
            Result.failure()
        } finally {
            ScanForegroundService.onScanEnded()
        }
    }

    private fun createForegroundInfo(): ForegroundInfo {
        val notification = ScanForegroundService.initialNotification(applicationContext)
        // specialUse, not mediaProcessing - see the manifest's comment on
        // this same service for why: mediaProcessing gets rejected by the
        // OS at start time on at least one real Android 15 device/build
        // this app has been tested on (InvalidForegroundServiceTypeException,
        // uncaught by WorkManager itself, crashing the whole process).
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(
                ScanForegroundService.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            ForegroundInfo(ScanForegroundService.NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val TAG = "ScanWorker"
        const val KEY_MODE = "mode"
        const val KEY_URI = "uri"
        const val KEY_FOLDER_ID = "folderId"
        const val KEY_CONTENT_MODE = "contentMode"
        const val UNIQUE_WORK_NAME = "scan"
    }
}
