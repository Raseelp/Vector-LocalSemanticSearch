package dev.twentyonevision.app.embedder.models

import dev.twentyonevision.app.BuildConfig

// sha256 must be lowercase hex. Update it (and sizeBytes) if the hosted
// model file ever changes.
data class RemoteModel(
    val id: String,
    val fileName: String,
    val url: String,
    val sha256: String,
    val sizeBytes: Long,
    // What the model is for - see ModelGroup.
    val group: String = ModelGroup.SEARCH
)

object ModelGroup {
    /** The CLIP models: needed for searching and indexing. */
    const val SEARCH = "search"
}

object ModelCatalog {

    val MODELS: List<RemoteModel> = listOf(
        RemoteModel(
            id = "vision",
            fileName = "clip_vision.onnx",
            url = "${BuildConfig.MODEL_BASE_URL}/clip_vision.onnx",
            sha256 = "2d0f282b6182bef9a3493661c6cc4071ab0316db4171ea60481457581b3b04a0",
            sizeBytes = 351777098L
        ),
        RemoteModel(
            id = "text",
            fileName = "clip_text.onnx",
            url = "${BuildConfig.MODEL_BASE_URL}/clip_text.onnx",
            sha256 = "cf2ea6228b51ff5ffcb0f4d2a54a4e94cfeaeca7fa48345e817a33672e2f6d5d",
            sizeBytes = 254340822L
        )
    )

    val ALL: List<RemoteModel> = MODELS

    fun forGroups(groups: Collection<String>): List<RemoteModel> = ALL.filter { it.group in groups }

    val totalBytes: Long get() = MODELS.sumOf { it.sizeBytes }
}
