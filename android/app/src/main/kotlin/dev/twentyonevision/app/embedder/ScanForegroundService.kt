package dev.twentyonevision.app.embedder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

// Doesn't do any scanning itself - EmbeddingEngine/MainActivity's own
// executor thread still does that (see MainActivity's "scanImagesAndOrVideos"
// handler). This service exists purely so the OS (and battery-happy OEM
// task killers) see an active foreground service with an ongoing
// notification and think twice before killing the whole process while a
// scan that can run for an hour+ is in progress. A safety net, not the
// main way we keep people around - that's the concurrent search and the
// "recently indexed" strip.
class ScanForegroundService : Service() {

    companion object {
        private const val TAG = "ScanForegroundService"
        private const val CHANNEL_ID = "scan_progress"
        private const val NOTIFICATION_ID = 4201

        @Volatile
        private var instance: ScanForegroundService? = null

        fun start(context: Context) {
            val intent = Intent(context, ScanForegroundService::class.java)
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                // Background-start restrictions, a killed process racing
                // this call, etc. The scan runs regardless of this service -
                // losing the notification/keep-alive isn't worth crashing over.
                Log.w(TAG, "start: could not start foreground service: ${e.message}")
            }
        }

        fun stop(context: Context) {
            val running = instance
            if (running != null) {
                // The int-flag overload (STOP_FOREGROUND_REMOVE) needs API 24 -
                // minSdk here is 21, so use the boolean one instead. Deprecated,
                // still fully functional on every version we ship to.
                @Suppress("DEPRECATION")
                running.stopForeground(true)
                running.stopSelf()
            } else {
                // Not running (already stopped, or start() failed) - stopService
                // on a not-running service is a harmless no-op.
                context.stopService(Intent(context, ScanForegroundService::class.java))
            }
        }

        // Best-effort, called on every progress tick - never throws, never
        // blocks the scan if the service isn't up (yet, or anymore).
        fun updateProgress(processed: Int, total: Int, embedded: Int) {
            instance?.postProgress(processed, total, embedded)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannelIfNeeded()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(0, 0, 0),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification(0, 0, 0))
            }
        } catch (e: Exception) {
            Log.w(TAG, "onStartCommand: startForeground failed, stepping down: ${e.message}")
            stopSelf()
        }
        // Nothing meaningful to restart from a null intent - the scan itself
        // lives outside this service, so a system-triggered restart would
        // just show a notification for a scan that no longer exists.
        return START_NOT_STICKY
    }

    private fun postProgress(processed: Int, total: Int, embedded: Int) {
        try {
            NotificationManagerCompat.from(this)
                .notify(NOTIFICATION_ID, buildNotification(processed, total, embedded))
        } catch (e: Exception) {
            // Most likely a revoked POST_NOTIFICATIONS permission - the
            // notification just won't be visible, which is fine.
        }
    }

    private fun buildNotification(processed: Int, total: Int, embedded: Int): Notification {
        val percent = if (total > 0) (processed * 100 / total) else 0
        val text = if (total > 0) {
            "$percent% done - $embedded indexed so far"
        } else {
            "Preparing..."
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Indexing your media")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setColor(Color.parseColor("#165E59"))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, percent, total <= 0)
            .build()
    }

    private fun createChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Scan progress",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows progress while Vector is indexing your photos and videos."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    // API 34+: the system telling us this service's foreground-service time
    // budget for its type is up. The scan keeps running either way (it
    // doesn't live in this service) - we just lose the keep-alive
    // protection and the notification, which beats crashing.
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "onTimeout: foreground service time limit reached, stepping down")
        @Suppress("DEPRECATION")
        stopForeground(true)
        stopSelf()
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
