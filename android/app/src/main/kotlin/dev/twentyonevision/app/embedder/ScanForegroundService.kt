package dev.twentyonevision.app.embedder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import dev.twentyonevision.app.MainActivity
import io.flutter.plugin.common.EventChannel
import kotlin.math.roundToInt
import kotlin.math.roundToLong

// Process-wide hub for everything about a scan that isn't the actual
// embedding work: the notification, the latest progress tick (for both
// the notification and a freshly (re)created Dart layer to resync from -
// see activeProgress()), the Dart-facing progress EventChannel sink, and
// the wake lock that keeps the CPU awake during the scan.
//
// No longer an Android Service - the foreground-service lifecycle itself
// now belongs to WorkManager (see ScanWorker, which calls setForeground()
// and drives onScanStarting/updateProgress/onScanEnded below). This keeps
// every one of the pieces that don't actually need a Service instance:
// they were already process-wide/static before, for the same underlying
// reason WorkManager solves more thoroughly now - a scan can outlive
// whatever component started it (an Activity recreated by Recents, or
// previously a Service instance recreated the same way).
object ScanForegroundService {

    private const val TAG = "ScanForegroundService"
    const val CHANNEL_ID = "scan_progress"
    const val NOTIFICATION_ID = 4201

    // Safety-net ceiling for the wake lock, renewed on every progress tick
    // (updateProgress) - a stalled/orphaned scan can't hold it forever,
    // but a genuinely long one never actually hits this since ticks keep
    // pushing it back out.
    private const val WAKE_LOCK_TIMEOUT_MS = 3 * 60 * 60 * 1000L // 3 hours

    // The notification's second line - fixed, not rotating. Also true:
    // it's all on-device, nothing leaves the phone.
    private const val REASSURING_PHRASE =
        "Indexing your photos on-device — private, offline, and ready for instant search."

    private data class Snapshot(
        val processed: Int,
        val total: Int,
        val embedded: Int,
        val elapsedMs: Long
    )

    @Volatile
    private var lastSnapshot: Snapshot? = null
    @Volatile
    private var previousSnapshot: Snapshot? = null

    // The Dart-facing progress EventChannel's sink, and the full raw
    // payload last sent through it. Removing the app from Recents doesn't
    // kill this process (that's the whole point of the foreground work),
    // but it does recreate the Activity/Flutter engine - the scan itself
    // keeps running on its original ScanWorker coroutine. Routing through
    // a static sink means that orphaned scan's ticks still reach whichever
    // MainActivity/engine is current when they fire, and a freshly
    // (re)created Dart layer can ask activeProgress() for the last one it
    // missed instead of showing "nothing is scanning".
    @Volatile
    private var progressSink: EventChannel.EventSink? = null
    @Volatile
    private var lastProgressMap: Map<String, Any?>? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // A foreground service/Worker only keeps this process from being
    // killed - it does *not* keep the CPU awake. Once the screen turns
    // off, Android lets the CPU suspend unless something holds a wake
    // lock, which would freeze the scan mid-work even though it's still
    // technically "running" in the foreground. Same PARTIAL_WAKE_LOCK
    // pattern music/download/backup apps use to keep working with the
    // screen off. Bounded with a timeout (renewed on every progress tick)
    // rather than acquired indefinitely, so a missed release() can't leak
    // it and drain the battery forever.
    @Volatile
    private var wakeLock: PowerManager.WakeLock? = null

    fun setProgressSink(sink: EventChannel.EventSink?) {
        progressSink = sink
    }

    fun pushProgress(map: Map<String, Any?>) {
        lastProgressMap = map
        mainHandler.post { progressSink?.success(map) }
    }

    // What a freshly (re)created Dart layer asks for on init to resync
    // with a scan that's still running from before it existed. Null once
    // onScanEnded() has run - see there.
    fun activeProgress(): Map<String, Any?>? = lastProgressMap

    // Called once, right as a scan begins (from ScanWorker.doWork(),
    // before the embedding loop starts) - clears anything left over from
    // a previous run so it can't leak into this one's first notification,
    // and acquires the wake lock.
    fun onScanStarting(context: Context) {
        lastSnapshot = null
        previousSnapshot = null
        lastProgressMap = null
        createChannelIfNeeded(context)
        acquireWakeLock(context)
    }

    // Called once the scan loop returns, however it ended (finished,
    // cancelled, or threw) - always releases the wake lock and clears the
    // cache, so activeProgress() correctly reports "nothing running" and
    // the next scan's first notification doesn't inherit stale numbers.
    fun onScanEnded() {
        releaseWakeLock()
        lastSnapshot = null
        previousSnapshot = null
        lastProgressMap = null
    }

    // The notification to pass to setForeground() right as a scan starts -
    // reads whatever's already cached (a restart mid-scan may have ticks
    // from before this call) instead of always showing a bare "Preparing...".
    fun initialNotification(context: Context): Notification {
        return buildNotification(context, lastSnapshot ?: Snapshot(0, 0, 0, 0))
    }

    // Called on every progress tick - never throws, never blocks the scan.
    // Returns the notification to show for it; the caller is responsible
    // for actually posting it (ScanWorker, via NotificationManagerCompat),
    // since only it knows whether it's already past the initial
    // setForeground() call.
    fun updateProgress(
        context: Context,
        processed: Int,
        total: Int,
        embedded: Int,
        elapsedMs: Long
    ): Notification {
        previousSnapshot = lastSnapshot
        val snapshot = Snapshot(processed, total, embedded, elapsedMs)
        lastSnapshot = snapshot
        // Extends the wake lock's timeout rather than letting a long scan
        // outlast it - see the field's doc.
        acquireWakeLock(context)
        return buildNotification(context, snapshot)
    }

    private fun acquireWakeLock(context: Context) {
        try {
            val pm = context.applicationContext
                .getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val lock = wakeLock ?: pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$TAG:scan"
            ).apply { setReferenceCounted(false) }
            lock.acquire(WAKE_LOCK_TIMEOUT_MS)
            wakeLock = lock
        } catch (e: Exception) {
            Log.w(TAG, "acquireWakeLock: failed: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            // Nothing to do - worst case it releases itself at its timeout.
        }
        wakeLock = null
    }

    private fun buildNotification(context: Context, snapshot: Snapshot): Notification {
        val (processed, total) = snapshot
        val percent = if (total > 0) (processed * 100 / total) else 0

        // The title is always what's on screen, collapsed or not - the
        // concrete numbers go there so they never depend on the user
        // expanding the notification. The second line is nice to have,
        // not load-bearing, so it's fine if an OEM shade only shows it
        // on expand.
        val title = if (total <= 0) {
            "Preparing to index..."
        } else {
            val parts = mutableListOf("$percent%", "$processed/$total")
            speedLabel(snapshot)?.let { parts.add(it) }
            etaLabel(snapshot)?.let { parts.add("$it left") }
            parts.joinToString("  •  ")
        }

        return NotificationCompat.Builder(context.applicationContext, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(REASSURING_PHRASE)
            .setStyle(NotificationCompat.BigTextStyle().bigText(REASSURING_PHRASE))
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setColor(Color.parseColor("#165E59"))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, percent, total <= 0)
            .setContentIntent(contentIntent(context))
            .build()
    }

    // Tapping the notification brings the app to the front instead of
    // doing nothing.
    private fun contentIntent(context: Context): PendingIntent {
        val intent = Intent(context.applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        return PendingIntent.getActivity(context.applicationContext, 0, intent, flags)
    }

    // Recent/instantaneous rate, from the last two ticks - mirrors the
    // in-app bar's recentEmbeddingsPerSecond.
    private fun speedLabel(snapshot: Snapshot): String? {
        val prev = previousSnapshot ?: return null
        val msDelta = snapshot.elapsedMs - prev.elapsedMs
        if (msDelta <= 200) return null
        val perSecond = (snapshot.embedded - prev.embedded) / (msDelta / 1000.0)
        if (perSecond <= 0) return null
        return if (perSecond >= 1) {
            "%.1f/sec".format(perSecond)
        } else {
            "${(1000 / perSecond).roundToInt()}ms/item"
        }
    }

    // Whole-scan average, same formula as the in-app bar's scanEtaText -
    // steadier than the instantaneous rate for an ETA.
    private fun etaLabel(snapshot: Snapshot): String? {
        val (processed, total, _, elapsedMs) = snapshot
        if (total <= 0 || processed <= 0 || processed >= total) return null
        val msPerItem = elapsedMs.toDouble() / processed
        val remainingMs = (msPerItem * (total - processed)).roundToLong()
        return formatDuration(remainingMs)
    }

    private fun formatDuration(ms: Long): String {
        if (ms <= 0) return "0s"
        val totalSeconds = ms / 1000
        val h = totalSeconds / 3600
        val m = (totalSeconds % 3600) / 60
        val s = totalSeconds % 60
        return when {
            h > 0 -> "${h}h ${m}m"
            m > 0 -> "${m}m ${s}s"
            else -> "${s}s"
        }
    }

    private fun createChannelIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.applicationContext
            .getSystemService(NotificationManager::class.java) ?: return
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
}
