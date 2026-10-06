package dev.twentyonevision.app.embedder

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import dev.twentyonevision.app.embedder.faces.FaceFollower
import dev.twentyonevision.app.embedder.faces.FaceScanWorker
import dev.twentyonevision.app.embedder.faces.FaceSettings

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
        // One scan at a time. A second one starting (the user stopped and started again, or
        // WorkManager replaced this work) used to run alongside the first, because
        // WorkManager's cancel does not stop a scan: two scans, each reporting its own
        // progress, which flickered between their two counts. So the one still running is
        // asked to stop, and this one waits until it has - everything it keeps in step
        // (the notification, the face scan, the wake lock) is then never shared.
        //
        // From this moment the scan still winding down is no longer the current one: whatever
        // it reports on its way out (above all its final "done" tick, which the app takes to
        // mean the scan the user just started has finished) is dropped.
        val thisRun = latestRun.incrementAndGet()
        ScanEngineHolder.embeddingEngine(applicationContext).cancelEmbedding()
        return scanMutex.withLock { runScan(thisRun) }
    }

    private suspend fun runScan(thisRun: Int): Result {
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

        // Faces are found in step with this scan: every so many photos it indexes, it
        // waits while their faces are found, then carries on (see FaceFollower). The
        // progress of both shows in this scan's one notification. A videos-only scan
        // has no photos to find faces in.
        return try {
            // Starting an indexing scan is asking for the faces to be found along with it: a
            // "stop face search" left over from earlier (it is remembered across launches, and
            // nothing on screen shows it) must not quietly keep them out.
            FaceSettings.setPaused(applicationContext, false)
            FaceFollower.openForScan()
            if (contentMode != "videos") FaceFollower.start(applicationContext)

            val embeddingEngine = ScanEngineHolder.embeddingEngine(applicationContext)
            embeddingEngine.embedImages(mode, uri, folderId, contentMode) { progress ->
                // WorkManager stopped this work (replaced, or stopped by the system): stop the
                // scan too - it is resumable, so a restart carries on from where it got to.
                if (isStopped) embeddingEngine.cancelEmbedding()
                // A newer scan was asked for: this one is only on its way out.
                if (thisRun != latestRun.get()) {
                    embeddingEngine.cancelEmbedding()
                    return@embedImages
                }
                val queue = FaceFollower.queueInfo()
                val map = mapOf(
                    "id" to folderId,
                    "total" to progress.total,
                    "processed" to progress.processed,
                    "embedded" to progress.embedded,
                    "elapsedMs" to progress.elapsedMs,
                    "activeMs" to progress.activeMs,
                    // The photos waiting for the next face batch (null when faces do not follow
                    // this scan), and the batch rule they fill towards.
                    "faceQueue" to queue?.first,
                    "faceQueueMs" to queue?.second,
                    "faceBatchPhotos" to FaceFollower.BATCH_PHOTOS,
                    "faceBatchMs" to FaceFollower.BATCH_MS,
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
                    progress.elapsedMs,
                    progress.activeMs
                )
                ScanForegroundService.postIfActive(applicationContext, notification)
            }
            // Indexing is over: hand what is left (the photos after the last batch, the
            // refining pass, videos) to the face worker.
            FaceFollower.closeForScan()
            FaceFollower.finish()
            // Only when indexing ran to its end: a scan the user stopped stops the faces with it.
            if (!embeddingEngine.wasCancelled()) FaceScanWorker.enqueueIfNeeded(applicationContext)
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
            if (thisRun == latestRun.get()) ScanForegroundService.pushProgress(
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
            // Whatever ended the scan, the face scan stops with it.
            FaceFollower.closeForScan()
            FaceFollower.finish()
            ScanForegroundService.onScanEnded(applicationContext)
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

        // Held for the whole of a scan (see doWork).
        private val scanMutex = Mutex()

        // Counts the scans asked for; only the latest one reports progress.
        private val latestRun = java.util.concurrent.atomic.AtomicInteger(0)
    }
}
