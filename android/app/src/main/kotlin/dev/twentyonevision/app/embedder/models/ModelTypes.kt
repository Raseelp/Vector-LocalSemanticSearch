package dev.twentyonevision.app.embedder.models

/** Thrown by EmbeddingEngine when a search/scan is attempted before models are ready. */
class ModelsNotReadyException(message: String) : Exception(message)

data class ModelDownloadProgress(
    val modelId: String,
    val modelFileName: String,
    val bytesForModel: Long,
    val totalBytesForModel: Long,
    val overallBytesDownloaded: Long,
    val overallTotalBytes: Long,
    val done: Boolean
)

data class ModelStatus(
    val id: String,
    val fileName: String,
    val sizeBytes: Long,
    val downloaded: Boolean,
    val verified: Boolean,
    val group: String = ModelGroup.SEARCH
)
