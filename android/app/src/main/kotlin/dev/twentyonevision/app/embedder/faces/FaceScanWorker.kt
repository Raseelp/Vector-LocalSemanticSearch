package dev.twentyonevision.app.embedder.faces

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import dev.twentyonevision.app.MainActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Runs [FaceScanner] as WorkManager work - the same reasoning as the indexing
 * scan: it is resumable (finished photos are skipped), so if the system stops
 * this process the work simply starts again and carries on.
 */
class FaceScanWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        FaceScanHub.running = true
        createChannelIfNeeded()

        try {
            setForeground(foregroundInfo(buildNotification(0, 0, paused = false)))
        } catch (e: Exception) {
            // Losing the keep-alive isn't worth failing the work over.
            Log.w(TAG, "setForeground failed, continuing anyway: ${e.message}")
        }

        return try {
            val services = FaceServices.get(applicationContext)
            var lastNotified = 0L
            withContext(Dispatchers.IO) {
                services.scanner.run(shouldStop = { isStopped }) { status ->
                    val now = System.currentTimeMillis()
                    if (now - lastNotified < NOTIFY_INTERVAL_MS && status["done"] != true) return@run
                    lastNotified = now
                    val processed = (status["processed"] as? Int) ?: 0
                    val total = (status["total"] as? Int) ?: 0
                    val paused = status["paused"] == true
                    val phase = status["phase"] as? String ?: "scan"
                    try {
                        NotificationManagerCompat.from(applicationContext)
                            .notify(NOTIFICATION_ID, buildNotification(processed, total, paused, phase))
                    } catch (_: Exception) {
                        // Notification permission revoked - fine.
                    }
                }
            }
            Result.success()
        } catch (e: CancellationException) {
            // Stopped on purpose (the user paused, or the model changed) - not an error.
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "face scan failed: ${e.message}", e)
            FaceScanHub.publish(
                mapOf(
                    "running" to false, "paused" to false, "done" to true,
                    "processed" to 0, "total" to 0, "faces" to 0, "people" to 0,
                    "failed" to 0, "runProcessed" to 0, "elapsedMs" to 0L,
                    "error" to (e.message ?: "failed"),
                )
            )
            Result.failure()
        } finally {
            FaceScanHub.running = false
        }
    }

    private fun foregroundInfo(notification: Notification): ForegroundInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }

    private fun buildNotification(processed: Int, total: Int, paused: Boolean, phase: String = "scan"): Notification {
        val percent = if (total > 0) processed * 100 / total else 0
        val title = when {
            paused -> "Face grouping is waiting for indexing to finish"
            phase == "tune" -> "Optimising face search for your phone (one time)"
            total <= 0 -> "Preparing to find faces..."
            phase == "refine" -> "Refining small faces  •  $percent%  •  $processed/$total"
            else -> "Finding faces  •  $percent%  •  $processed/$total"
        }
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            applicationContext, 1, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText("Grouping the people in your photos, on this device only.")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setColor(Color.parseColor("#165E59"))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, percent, total <= 0)
            .setContentIntent(pending)
            .build()
    }

    private fun createChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = applicationContext.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Face grouping", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows progress while Vector finds and groups the people in your photos."
                setShowBadge(false)
            }
        )
    }

    companion object {
        private const val TAG = "FaceScanWorker"
        const val CHANNEL_ID = "face_progress"
        const val NOTIFICATION_ID = 4202
        const val UNIQUE_WORK_NAME = "face_scan"
        private const val NOTIFY_INTERVAL_MS = 2000L

        /**
         * Starts the face scan if there is something for it to do and it isn't
         * already running (unique work, so calling this often is harmless).
         * Returns whether work was started or is already running.
         */
        fun enqueueIfNeeded(context: Context): Boolean {
            return try {
                val app = context.applicationContext
                if (!FaceScanHub.running && !FaceServices.get(app).scanner.hasWork()) return false
                WorkManager.getInstance(app).enqueueUniqueWork(
                    UNIQUE_WORK_NAME,
                    ExistingWorkPolicy.KEEP,
                    OneTimeWorkRequestBuilder<FaceScanWorker>().build(),
                )
                true
            } catch (e: Exception) {
                Log.w(TAG, "could not start the face scan: ${e.message}")
                false
            }
        }
    }
}
