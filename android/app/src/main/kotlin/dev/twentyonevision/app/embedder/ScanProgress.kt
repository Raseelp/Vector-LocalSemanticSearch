package dev.twentyonevision.app.embedder

// One file that just finished embedding - purely cosmetic, feeds the
// "recently indexed" strip in the UI.
data class RecentEmbeddedItem(
    val uri: String,
    val isVideo: Boolean,
    val timestampMs: Long
)

data class ScanProgress(
    val total: Int,
    val processed: Int,
    val embedded: Int,
    val skipped: Int,
    val elapsedMs: Long,
    // elapsedMs without the time spent waiting for the face scan to work through a
    // batch of photos just indexed (see ScanHandoff) - what indexing's own speed is
    // measured over; elapsedMs (the real time) is what the time left is worked out from.
    val activeMs: Long = elapsedMs,
    val done: Boolean,
    val path: String,
    val recentItems: List<RecentEmbeddedItem> = emptyList(),
    // The subset of skipped that wasn't "already indexed" - files that
    // couldn't be decoded/embedded at all (corrupt, unsupported format, a
    // video with no readable frames). They're retried on every rescan,
    // which is why a finished library can still show a few "new" files.
    val failed: Int = 0
)
