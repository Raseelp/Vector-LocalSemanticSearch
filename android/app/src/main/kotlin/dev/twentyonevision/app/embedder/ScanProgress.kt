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
    val done: Boolean,
    val path: String,
    val recentItems: List<RecentEmbeddedItem> = emptyList(),
    // The subset of skipped that wasn't "already indexed" - files that
    // couldn't be decoded/embedded at all (corrupt, unsupported format, a
    // video with no readable frames). They're retried on every rescan,
    // which is why a finished library can still show a few "new" files.
    val failed: Int = 0
)
