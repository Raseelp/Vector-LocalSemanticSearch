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
    val recentItems: List<RecentEmbeddedItem> = emptyList()
)
