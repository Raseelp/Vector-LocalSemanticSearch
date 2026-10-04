package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.os.SystemClock
import android.util.Log
import kotlin.math.max
import androidx.work.WorkManager
import dev.twentyonevision.app.embedder.BenchLog
import dev.twentyonevision.app.embedder.IndexedImage
import dev.twentyonevision.app.embedder.ScanForegroundService
import dev.twentyonevision.app.embedder.ScanHandoff

/**
 * Finds faces in step with an indexing scan, in the same notification and without the
 * two ever competing for the CPU: the indexing scan hands over the photos it has
 * written (see ScanHandoff), and once enough have gathered (or enough time has passed)
 * it waits while their faces are found at full speed, then carries on. Nothing here runs on a thread of
 * its own - the work happens on the indexing scan's thread, inside its hand-over.
 *
 * When indexing ends (see [finish]) the normal face worker (FaceScanWorker) takes over
 * for what is left: the photos after the last batch, the refining pass and videos.
 */
object FaceFollower {

    private const val TAG = "FaceFollower"

    // When indexing waits for faces: once this many newly indexed photos have gathered,
    // or this long has passed since the last time - whichever comes first. The first
    // time is early, so people show up within the first half-minute; after that the
    // batches are bigger and further apart, so indexing isn't interrupted constantly.
    private const val FIRST_BATCH_PHOTOS = 40
    private const val FIRST_BATCH_MS = 20_000L
    private const val BATCH_PHOTOS = 150
    private const val BATCH_MS = 60_000L

    private val lock = Any()
    private val waiting = ArrayList<IndexedImage>()

    // Guarded by [lock]: how many batches this scan has had so far, and when the last
    // one ended (or, before the first, when this started).
    private var batches = 0
    private var lastBatchAt = 0L
    @Volatile private var session: FaceScanner.Session? = null
    @Volatile private var armed = false

    // Only an indexing scan in progress can be followed. ScanWorker closes this the
    // moment its scan ends so a late request (from the app, say) can't start another
    // session, or cancel the face worker that is about to take over.
    @Volatile private var open = false

    /** True while faces are being found in step with an indexing scan. */
    fun isArmed(): Boolean = armed

    fun openForScan() {
        open = true
    }

    fun closeForScan() {
        open = false
    }

    /**
     * Starts finding faces in step with the indexing scan in progress, unless it already
     * does, face search is stopped by the user, or no recognition model is installed.
     * True if it is armed now.
     */
    fun start(context: Context): Boolean {
        synchronized(lock) {
            if (armed) return true
            val app = context.applicationContext
            if (!open || !ScanForegroundService.isScanActive) {
                BenchLog.log(app) { "faces not in step with indexing: no indexing scan is open for it (open=$open)" }
                return false
            }
            if (FaceSettings.paused(app)) {
                BenchLog.log(app) { "faces not in step with indexing: face search is stopped (resume it in People)" }
                return false
            }
            val services = FaceServices.get(app)
            if (!services.engine.isReady()) {
                BenchLog.log(app) { "faces not in step with indexing: the face models are not ready" }
                return false
            }

            // A face worker still working through an earlier scan's leftovers would hold
            // the face scan: stop it (it is resumable, and starts again once indexing ends).
            try {
                WorkManager.getInstance(app).cancelUniqueWork(FaceScanWorker.UNIQUE_WORK_NAME)
            } catch (e: Exception) {
                Log.w(TAG, "could not stop the running face worker: ${e.message}")
            }

            waiting.clear()
            batches = 0
            lastBatchAt = SystemClock.elapsedRealtime()
            session = services.scanner.openSession { status -> ScanForegroundService.updateFaceProgress(app, status) }
            ScanHandoff.consumer = ScanHandoff.Consumer { photos, shouldStop -> onIndexed(app, photos, shouldStop) }
            armed = true
            BenchLog.log(app) {
                "faces in step with indexing: first batch after $FIRST_BATCH_PHOTOS photos or " +
                    "${FIRST_BATCH_MS / 1000}s, then every $BATCH_PHOTOS photos or ${BATCH_MS / 1000}s"
            }
            return true
        }
    }

    // Runs on the indexing scan's thread, which waits for it to return.
    private fun onIndexed(app: Context, photos: List<IndexedImage>, shouldStop: () -> Boolean) {
        // Face search stopped by the user: these are left for the pass after indexing
        // (or for when they resume).
        if (FaceSettings.paused(app)) {
            synchronized(lock) { waiting.clear() }
            return
        }

        val batch: List<IndexedImage>
        val current: FaceScanner.Session
        val number: Int
        val ranMs: Long
        val byCount: Boolean
        synchronized(lock) {
            current = session ?: return
            if (!armed) return
            waiting += photos
            val first = batches == 0
            val enough = if (first) FIRST_BATCH_PHOTOS else BATCH_PHOTOS
            val waited = if (first) FIRST_BATCH_MS else BATCH_MS
            val now = SystemClock.elapsedRealtime()
            byCount = waiting.size >= enough
            val due = byCount || now - lastBatchAt >= waited
            if (!due) return
            batch = ArrayList(waiting)
            waiting.clear()
            batches++
            number = batches
            ranMs = now - lastBatchAt
        }

        BenchLog.log(app) {
            "face batch #$number due: ${batch.size} photos (${if (byCount) "photo count" else "time"} reached); " +
                "indexing ran ${ranMs}ms since the last one | ${BenchLog.device(app)}"
        }
        val startedAt = SystemClock.elapsedRealtime()
        FaceScanHub.running = true
        try {
            current.processBatch(batch, shouldStop)
        } finally {
            FaceScanHub.running = false
            val endedAt = SystemClock.elapsedRealtime()
            // The next interval counts from here, not from when this batch began.
            synchronized(lock) { lastBatchAt = endedAt }
            BenchLog.log(app) {
                "face batch #$number done: faces took ${endedAt - startedAt}ms for ${batch.size} photos; " +
                    "indexing had run ${ranMs}ms (indexing:faces = ${"%.2f".format(ranMs / max(endedAt - startedAt, 1L).toDouble())}) | " +
                    BenchLog.device(app)
            }
        }
    }

    /** Stops handing photos over (the user stopped face search), without ending the session. */
    fun stop() {
        synchronized(lock) {
            armed = false
            ScanHandoff.consumer = null
            waiting.clear()
        }
    }

    /** The indexing scan is over: stop, and let the session say so. Safe to call more than once. */
    fun finish() {
        val ended: FaceScanner.Session?
        synchronized(lock) {
            armed = false
            ScanHandoff.consumer = null
            waiting.clear()
            ended = session
            session = null
        }
        ended?.finish()
        ScanForegroundService.clearFaceProgress()
    }
}
