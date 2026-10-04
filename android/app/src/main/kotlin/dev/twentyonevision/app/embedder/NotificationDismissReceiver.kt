package dev.twentyonevision.app.embedder

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import dev.twentyonevision.app.embedder.faces.FaceScanWorker

/**
 * Told when the user swipes a scan's notification away. The scan carries on (it is a
 * foreground service; on Android 14+ its notification can be dismissed), but it must not
 * put the notification back with its next progress update - see
 * [ScanForegroundService.notificationDismissed] and [FaceScanWorker.notificationDismissed].
 */
class NotificationDismissReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getStringExtra(EXTRA_WHICH)) {
            WHICH_FACES -> FaceScanWorker.notificationDismissed = true
            else -> ScanForegroundService.notificationDismissed = true
        }
    }

    companion object {
        private const val EXTRA_WHICH = "which"
        const val WHICH_SCAN = "scan"
        const val WHICH_FACES = "faces"

        // One PendingIntent per notification (the extra does not tell two of them apart).
        fun pending(context: Context, which: String): PendingIntent {
            val app = context.applicationContext
            val intent = Intent(app, NotificationDismissReceiver::class.java).putExtra(EXTRA_WHICH, which)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            return PendingIntent.getBroadcast(app, if (which == WHICH_FACES) 21 else 20, intent, flags)
        }
    }
}
