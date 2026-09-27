package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.util.Log
import dev.twentyonevision.app.embedder.IndexedVideo
import dev.twentyonevision.app.embedder.ScanEngineHolder
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Finds and recognises the people in videos.
 *
 * A video is treated as a set of sampled frames. Every frame is searched for faces (the
 * cheap step); faces in neighbouring frames are then linked into tracks (one person moving
 * through the video), and only the best one or two faces of each track are recognised (the
 * expensive step). The rest of a track's kept faces are simply given the same person. So a
 * ten-second clip costs a handful of recognitions, not hundreds.
 *
 * Faces in video are held to a higher standard than in photos (motion blur), the picture of
 * each kept face is saved when it is found (a video frame can't be cut out again cheaply),
 * and a video counts as ONE item however many frames a person is in.
 */
class VideoFaceScanner(private val context: Context, private val services: FaceServices) {

    /** A face found in one frame, waiting to be tracked and (maybe) recognised. */
    private class Det(
        val frame: Int,
        val tsMs: Long,
        val box: DetectedFace,
        val frameW: Int,
        val frameH: Int,
        val sizePx: Int,
        val yaw: Float,
        val sharpness: Float,
        val rank: Float,
        var aligned: Bitmap?,
        val crop: ByteArray?,
    ) {
        var track = -1
        var embedding: FloatArray? = null
        var recognised = false
        var faceId = 0L
        val cx get() = (box.left + box.right) / 2f
        val cy get() = (box.top + box.bottom) / 2f
        val size get() = max(box.width, box.height)
    }

    /**
     * Scans one video and stores what was found. Returns how many faces were kept,
     * [FAILED] if the video could not be opened or read (it is tried again on a later run),
     * or [STOPPED] if [shouldStop] said to give up.
     * [gate] is asked before each frame (it waits while the indexing scan runs; false = stop).
     */
    fun scan(
        video: IndexedVideo,
        shouldStop: () -> Boolean,
        gate: () -> Boolean,
        background: Boolean = true,
        relax: Int = -1,
    ): Int {
        // One scan of a video at a time: the background scan and the viewer must never both
        // place the same frames' faces (the second would find the first's people "taken").
        if (!active.add(video.hash)) return BUSY
        val progress = PhotoScanProgress().also { it.video = true }
        val key = "video:${video.uri}"
        services.scanner.photoProgress[key] = progress
        try {
            return scanInner(video, shouldStop, gate, progress, background, if (relax >= 0) relax else relaxOf(video.hash))
        } finally {
            services.scanner.photoProgress.remove(key)
            active.remove(video.hash)
        }
    }

    /** Blocks until nobody is scanning [hash] (or [maxMs] passes). */
    fun waitUntilFree(hash: Long, maxMs: Long) {
        var waited = 0L
        while (hash in active && waited < maxMs) {
            Thread.sleep(300)
            waited += 300
        }
    }

    /**
     * How loose the search for faces is for one video (0 standard, 1 looser, 2 loosest). It is
     * remembered per video - a video where the standard search found nothing keeps needing the
     * looser one - and never changes the app-wide settings or any other video.
     */
    fun relaxOf(hash: Long): Int = (services.store.getMeta("video_relax_$hash")?.toIntOrNull() ?: 0).coerceIn(0, MAX_RELAX)

    // What each search level accepts. Looser: smaller and blurrier faces, turned heads, less
    // certain detections, bigger frames and more of them.
    private class Relax(val level: Int) {
        val minSize = when (level) { 0 -> FaceQuality.VIDEO_MIN_SIZE_PX; 1 -> 36; else -> 28 }
        val minScore = when (level) { 0 -> FaceQuality.VIDEO_MIN_SCORE; 1 -> 0.4f; else -> 0.3f }
        val maxYaw = when (level) { 0 -> FaceQuality.VIDEO_MAX_YAW; 1 -> 0.85f; else -> 1.5f }
        val minSharpness = when (level) { 0 -> FaceQuality.VIDEO_MIN_SHARPNESS; 1 -> 6f; else -> 0f }
        val detectScore = when (level) { 0 -> FaceDetector.DEFAULT_SCORE_THRESHOLD; 1 -> 0.35f; else -> 0.25f }
        val maxSide = when (level) { 0 -> VideoFrameReader.MAX_SIDE; 1 -> 1920; else -> 2560 }

        fun good(sizePx: Int, score: Float, sharpness: Float, yaw: Float) =
            sizePx >= minSize && score >= minScore && yaw <= maxYaw && sharpness >= minSharpness
    }

    private fun scanInner(
        video: IndexedVideo,
        shouldStop: () -> Boolean,
        gate: () -> Boolean,
        progress: PhotoScanProgress,
        background: Boolean,
        level: Int,
    ): Int {
        val relax = Relax(level)
        progress.relax = level
        val reader = VideoFrameReader.open(context, Uri.parse(video.uri), relax.maxSide) ?: return FAILED
        // Asked for by the user (the button): look harder - small faces in a group too, and
        // at least the balanced number of frames. The background scan follows the settings.
        val tiled = !background || FaceSettings.thorough(context)
        val dets = ArrayList<Det>()
        val frameDims = HashMap<Int, Pair<Int, Int>>()
        var decoded = 0

        try {
            val times = sampleTimes(reader.durationMs, atLeastBalanced = !background, level = level)
            progress.steps = times.size
            var lastSignature = Long.MIN_VALUE
            for ((index, ts) in times.withIndex()) {
                if (shouldStop() || !gate()) {
                    free(dets)
                    return STOPPED
                }
                progress.step = index + 1
                progress.faces = dets.size
                progress.stage = "detecting"
                // The exact frame at that time (not the nearest keyframe): it is the picture the player
                // shows there, so the face positions stored line up with it.
                val frame = reader.frameAt(ts, exact = true) ?: continue
                try {
                    decoded++
                    // The same picture twice (a sparse-keyframe video): once is enough.
                    val signature = signatureOf(frame)
                    if (signature == lastSignature) continue
                    lastSignature = signature

                    frameDims[index] = frame.width to frame.height
                    findFaces(frame, index, ts, dets, tiled, relax)
                    trim(dets)
                } finally {
                    frame.recycle()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "video ${video.uri}: reading frames failed: ${e.message}")
            free(dets)
            return FAILED
        } finally {
            reader.close()
        }

        // No frame could be read from a video that opened. That may just be the decoder being
        // busy (a video playing in the viewer takes it): try again later, and only give up on
        // the video - as one with nothing to find - after the background scan has failed on it
        // a few times.
        if (decoded == 0 && dets.isEmpty()) {
            if (!background) return FAILED
            val key = "video_fail_${video.hash}"
            val failures = (services.store.getMeta(key)?.toIntOrNull() ?: 0) + 1
            if (failures < MAX_READ_FAILURES) {
                services.store.setMeta(key, failures.toString())
                return FAILED
            }
            services.store.insertVideo(video.hash, video.uri, emptyList())
            return 0
        }

        return try {
            finish(video, dets, frameDims, progress).also { kept ->
                // This video keeps the level it was scanned at - its next scan starts there.
                if (!background && kept >= 0) services.store.setMeta("video_relax_${video.hash}", level.toString())
            }
        } catch (e: Exception) {
            Log.w(TAG, "video ${video.uri}: recognising failed: ${e.message}", e)
            FAILED
        } finally {
            free(dets)
        }
    }

    // ---------------- finding faces in a frame ----------------

    private fun findFaces(frame: Bitmap, index: Int, tsMs: Long, out: MutableList<Det>, tiled: Boolean, relax: Relax) {
        val engine = services.engine
        val found = engine.detect(frame, tiled, relax.detectScore)
        val kept = ArrayList<Det>()
        for (box in found) {
            val size = min(box.width, box.height).toInt()
            if (size < relax.minSize) continue
            val aligned = engine.align(frame, box.landmarks)
            val yaw = FaceQuality.yaw(box.landmarks)
            if (!relax.good(size, box.score, aligned.sharpness, yaw)) {
                aligned.bitmap.recycle()
                continue
            }
            val crop = services.crops.render(
                frame,
                (box.left / frame.width).coerceIn(0f, 1f), (box.top / frame.height).coerceIn(0f, 1f),
                (box.right / frame.width).coerceIn(0f, 1f), (box.bottom / frame.height).coerceIn(0f, 1f),
            )
            kept += Det(
                index, tsMs, box, frame.width, frame.height, size, yaw, aligned.sharpness,
                FaceQuality.rank(size, box.score, yaw), aligned.bitmap, crop,
            )
        }
        // A crowd: the clearest few of a frame are plenty.
        kept.sortByDescending { it.rank }
        for ((i, d) in kept.withIndex()) {
            if (i < MAX_FACES_PER_FRAME) out += d else {
                d.aligned?.recycle()
                d.aligned = null
            }
        }
    }

    // A cheap fingerprint of a frame (a few dozen pixels), to notice identical frames.
    private fun signatureOf(frame: Bitmap): Long {
        var h = 1125899906842597L
        val w = frame.width
        val ht = frame.height
        for (yi in 1..6) {
            for (xi in 1..6) {
                h = 31 * h + frame.getPixel(w * xi / 7, ht * yi / 7)
            }
        }
        return h
    }

    // ---------------- tracks, recognition, storing ----------------

    private fun finish(video: IndexedVideo, dets: List<Det>, frameDims: Map<Int, Pair<Int, Int>>, progress: PhotoScanProgress): Int {
        val engine = services.engine
        val store = services.store
        val clusterer = services.clusterer

        // Link each face to the closest similar one in the frame before: one person, one track.
        val byFrame = dets.groupBy { it.frame }
        var previous: List<Det> = emptyList()
        var nextTrack = 0
        for (frame in byFrame.keys.sorted()) {
            val current = byFrame.getValue(frame).sortedByDescending { it.rank }
            val used = HashSet<Det>()
            for (d in current) {
                var best: Det? = null
                var bestDistance = Float.MAX_VALUE
                for (p in previous) {
                    if (p in used) continue
                    val distance = hypot(d.cx - p.cx, d.cy - p.cy) / max(d.size, p.size)
                    val ratio = d.size / p.size
                    if (distance < TRACK_DISTANCE && ratio in TRACK_RATIO_LOW..TRACK_RATIO_HIGH && distance < bestDistance) {
                        best = p
                        bestDistance = distance
                    }
                }
                if (best != null) {
                    d.track = best.track
                    used += best
                } else {
                    d.track = nextTrack++
                }
            }
            previous = current
        }

        // Recognise each track's best face, and a second from another moment if there is one.
        val tracks = dets.groupBy { it.track }
        val toRecognise = ArrayList<Det>()
        val extras = HashMap<Int, List<Det>>()
        for ((track, list) in tracks) {
            val sorted = list.sortedByDescending { it.rank }
            val first = sorted[0]
            toRecognise += first
            val second = sorted.drop(1).firstOrNull { abs(it.frame - first.frame) >= 2 } ?: sorted.getOrNull(1)
            if (second != null) toRecognise += second
            // Up to two more, spread through the track, keep the person visible at other moments.
            val rest = sorted.filter { it !== first && it !== second }
            extras[track] = when {
                rest.size <= 2 -> rest
                else -> listOf(rest.first(), rest.last())
            }
        }
        val limited = toRecognise.sortedByDescending { it.rank }.take(MAX_RECOGNISED_PER_VIDEO)
        progress.faces = dets.size
        // How many faces (people moving through the video) are being identified - not the sightings.
        progress.total = tracks.size
        progress.stage = if (limited.isEmpty()) "placing" else "recognising"
        if (limited.isNotEmpty()) {
            val vectors = engine.embedAligned(limited.map { it.aligned!! })
            limited.forEachIndexed { i, d ->
                d.embedding = vectors[i]
                d.recognised = true
            }
        }

        // The extras carry the track's best face's fingerprint (they were not recognised themselves).
        val stored = ArrayList<Det>()
        for ((track, list) in tracks) {
            val best = list.filter { it.recognised }.maxByOrNull { it.rank } ?: continue
            for (d in list) {
                if (d.recognised) {
                    stored += d
                } else if (d in (extras[track] ?: emptyList())) {
                    d.embedding = best.embedding
                    stored += d
                }
            }
        }
        if (stored.isEmpty()) {
            // Scanned before with faces: a second look that finds none must not wipe what the first found.
            val before = store.videoFaceCount(video.hash)
            if (before != null && before > 0) return before
            if (store.videoHasFrames(video.hash)) {
                // Frames looked at by hand are kept: the video just counts as scanned now.
                store.markVideoScanned(video.hash, video.uri)
            } else {
                store.insertVideo(video.hash, video.uri, emptyList())
            }
            return 0
        }

        progress.stage = "placing"

        // One stored frame per sampled moment that has a kept face.
        val frames = stored.groupBy { it.frame }.toSortedMap().map { (frame, list) ->
            val (w, h) = frameDims[frame] ?: (list[0].frameW to list[0].frameH)
            list to FaceStore.FrameFaces(
                list[0].tsMs, w, h,
                list.map { d ->
                    FaceRow(
                        boxL = d.box.left / w, boxT = d.box.top / h, boxR = d.box.right / w, boxB = d.box.bottom / h,
                        landmarks = FloatArray(10) { k -> d.box.landmarks[k] / (if (k % 2 == 0) w else h) },
                        score = d.box.score, sizePx = d.sizePx, sharpness = d.sharpness, yaw = d.yaw,
                        good = d.recognised, rank = d.rank, embedding = d.embedding!!,
                    )
                },
            )
        }
        // Scanned before (the user asked again): its old faces are replaced, so the in-memory
        // bookkeeping (who is in which frame) must be rebuilt without them.
        val hadBefore = store.videoHasFrames(video.hash) // an earlier scan, or frames looked at by hand
        val ids = store.insertVideo(video.hash, video.uri, frames.map { it.second })
        if (hadBefore) clusterer.invalidate()
        frames.forEachIndexed { fi, (list, _) ->
            list.forEachIndexed { k, d ->
                d.faceId = ids[fi][k]
                d.crop?.let { store.saveCropBytes(d.faceId, it) }
            }
        }

        // Place them among the people: recognised faces first (best first), then the rest of each track.
        val trackPerson = HashMap<Int, Long>()
        for (d in stored.filter { it.recognised }.sortedByDescending { it.rank }) {
            val person = clusterer.assignVideoFace(
                d.faceId, store.frameHash(video.hash, d.tsMs), video.hash, d.embedding!!, good = true, rank = d.rank,
            )
            if (person != null && d.track !in trackPerson) trackPerson[d.track] = person
        }
        for (d in stored.filter { !it.recognised }) {
            val person = trackPerson[d.track] ?: continue
            clusterer.attachTracked(d.faceId, store.frameHash(video.hash, d.tsMs), video.hash, person)
        }
        // People who were only in the faces that were replaced are gone.
        if (hadBefore) store.pruneEmptyPeople()
        return stored.size
    }

    // A long, crowded video could keep a thousand faces (each with a small picture): keep the
    // clearest few hundred, so memory stays modest.
    private fun trim(dets: MutableList<Det>) {
        if (dets.size <= MAX_KEPT_FACES) return
        dets.sortByDescending { it.rank }
        while (dets.size > MAX_KEPT_FACES) {
            val worst = dets.removeAt(dets.size - 1)
            worst.aligned?.recycle()
            worst.aligned = null
        }
    }

    private fun free(dets: List<Det>) {
        for (d in dets) {
            d.aligned?.recycle()
            d.aligned = null
        }
    }

    private fun sampleTimes(durationMs: Long, atLeastBalanced: Boolean, level: Int): List<Long> {
        var mode = FaceSettings.videoDensity(context)
        if (atLeastBalanced && mode == FaceSettings.DENSITY_FAST) mode = FaceSettings.DENSITY_BALANCED
        var (step, cap) = when (mode) {
            FaceSettings.DENSITY_FAST -> 3000L to 12
            FaceSettings.DENSITY_THOROUGH -> 1000L to 60
            else -> 2000L to 30
        }
        // A looser search also looks at more moments.
        if (level >= 1) {
            step = 1000L
            cap = if (level >= 2) 90 else 60
        }
        val count = (durationMs / step).toInt().coerceIn(3, cap)
        return (0 until count).map { i -> durationMs * (2 * i + 1) / (2 * count) }
    }

    // ---------------- the video viewer: who is in this frame? ----------------

    /** A face in one frame and who it is (0..1 fractions of the upright frame). */
    class FrameIdentity(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
        val frameW: Int,
        val frameH: Int,
        val personId: Long,
        // What is needed to store this face as part of the video (see [storeLooked]).
        val landmarks: FloatArray,
        val score: Float,
        val sizePx: Int,
        val sharpness: Float,
        val yaw: Float,
        val rank: Float,
        val embedding: FloatArray,
        val crop: ByteArray?,
    )

    /**
     * Who is in the frame of [uri] at [positionMs], looked up on the spot. Nothing is stored
     * and nobody's fingerprint changes: it only names faces that match people already known.
     * Null if the frame could not be read.
     */
    fun identifyFrame(uri: String, positionMs: Long, progress: PhotoScanProgress): List<FrameIdentity>? {
        val engine = services.engine
        if (!engine.isReady()) return null
        // The level this video needed (a video the standard search missed faces in).
        val hash = ScanEngineHolder.embeddingEngine(context).indexedVideos().firstOrNull { it.uri == uri }?.hash
        val relax = Relax(if (hash != null) relaxOf(hash) else 0)
        val reader = VideoFrameReader.open(context, Uri.parse(uri), relax.maxSide) ?: return null
        val frame = try {
            reader.frameAt(positionMs, exact = true)
        } finally {
            reader.close()
        } ?: return null

        val aligned = ArrayList<Pair<DetectedFace, AlignedFace>>()
        try {
            progress.stage = "detecting"
            val w = frame.width
            val h = frame.height
            val found = engine.detect(frame, true, relax.detectScore)
            for (box in found) {
                val size = min(box.width, box.height).toInt()
                if (size < min(FaceQuality.MIN_EMBED_PX, relax.minSize)) continue
                aligned += box to engine.align(frame, box.landmarks)
            }
            // The clearest first, so a crowd is recognised best-first.
            aligned.sortByDescending { (box, a) ->
                FaceQuality.rank(min(box.width, box.height).toInt(), box.score, FaceQuality.yaw(box.landmarks)) + a.sharpness * 0.001f
            }
            progress.faces = aligned.size
            progress.total = aligned.size
            progress.stage = if (aligned.isEmpty()) "placing" else "recognising"
            if (aligned.isEmpty()) return emptyList()

            val vectors = engine.embedAligned(aligned.map { it.second.bitmap })
            progress.stage = "placing"
            val taken = HashSet<Long>()
            val out = ArrayList<FrameIdentity>()
            aligned.forEachIndexed { i, (box, a) ->
                val person = services.clusterer.identify(vectors[i], taken) ?: return@forEachIndexed
                taken += person
                val l = (box.left / w).coerceIn(0f, 1f)
                val t = (box.top / h).coerceIn(0f, 1f)
                val r = (box.right / w).coerceIn(0f, 1f)
                val b = (box.bottom / h).coerceIn(0f, 1f)
                val size = min(box.width, box.height).toInt()
                val yaw = FaceQuality.yaw(box.landmarks)
                out += FrameIdentity(
                    l, t, r, b, w, h, person,
                    landmarks = FloatArray(10) { k -> box.landmarks[k] / (if (k % 2 == 0) w else h) },
                    score = box.score, sizePx = size, sharpness = a.sharpness, yaw = yaw,
                    rank = FaceQuality.rank(size, box.score, yaw), embedding = vectors[i],
                    crop = services.crops.render(frame, l, t, r, b),
                )
            }
            return out
        } finally {
            aligned.forEach { it.second.bitmap.recycle() }
            frame.recycle()
        }
    }

    /**
     * Keeps what a look at one frame found: the faces that matched people are stored as that
     * frame of the video (with their pictures) and put with those people, exactly as a scan would -
     * so a person found this way has a real position for that moment. They don't shape anyone
     * (like the weaker faces of a scan). Skipped if a scan of the video is running (it stores
     * its own), or that moment is already stored.
     */
    fun storeLooked(uri: String, positionMs: Long, identities: List<FrameIdentity>) {
        if (identities.isEmpty()) return
        val hash = ScanEngineHolder.embeddingEngine(context).indexedVideos().firstOrNull { it.uri == uri }?.hash ?: return
        if (hash in active) return
        val store = services.store
        if (store.hasFrame(hash, positionMs)) return

        val rows = identities.map { f ->
            FaceRow(
                boxL = f.left, boxT = f.top, boxR = f.right, boxB = f.bottom,
                landmarks = f.landmarks, score = f.score, sizePx = f.sizePx, sharpness = f.sharpness, yaw = f.yaw,
                good = false, rank = f.rank, embedding = f.embedding,
            )
        }
        val first = identities[0]
        val ids = store.storeLookedFrame(hash, uri, positionMs, first.frameW, first.frameH, rows)
        val frame = store.frameHash(hash, positionMs)
        identities.forEachIndexed { i, f ->
            f.crop?.let { store.saveCropBytes(ids[i], it) }
            services.clusterer.attachTracked(ids[i], frame, hash, f.personId)
        }
    }

    companion object {
        private const val TAG = "VideoFaceScanner"
        const val FAILED = -1
        const val STOPPED = -2
        const val BUSY = -3 // someone else is scanning this video right now

        /** The loosest search level (0 standard, 1 looser, 2 loosest). */
        const val MAX_RELAX = 2

        // Videos being scanned right now (by the background scan or a viewer), by hash.
        private val active: MutableSet<Long> = java.util.concurrent.ConcurrentHashMap.newKeySet()

        // Frames sampled: 3 to this many, about one per step (see FaceSettings.videoDensity).
        private const val MAX_FACES_PER_FRAME = 12
        private const val MAX_RECOGNISED_PER_VIDEO = 60

        // Faces held in memory while one video is scanned.
        private const val MAX_KEPT_FACES = 300

        // Background runs that find no readable frame before a video is given up on.
        private const val MAX_READ_FAILURES = 3

        // Same person from one sampled frame to the next: how far it may move (in face sizes) and change size.
        private const val TRACK_DISTANCE = 1.0f
        private const val TRACK_RATIO_LOW = 0.55f
        private const val TRACK_RATIO_HIGH = 1.8f
    }
}
