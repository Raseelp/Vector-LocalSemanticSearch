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
    val group: String = ModelGroup.SEARCH,
    // A sub-folder of the app's private files to keep it in (null = the top level).
    val folder: String? = null
)

object ModelGroup {
    /** The CLIP models: needed for searching and indexing. */
    const val SEARCH = "search"

    /** The face recognition model: only needed for the Faces tab. */
    const val FACES = "faces"
}

object ModelCatalog {

    val MODELS: List<RemoteModel> = listOf(
        RemoteModel(
            id = "vision",
            fileName = "clip_vision_ts.pt",
            url = "${BuildConfig.MODEL_BASE_URL}/clip_vision_ts.pt",
            sha256 = "2aa36306b7da2e6bb866a61863b1aa96a79f1dc6d22285f2098ac77c2be12178",
            sizeBytes = 351463461L
        ),
        RemoteModel(
            id = "text",
            fileName = "clip_text_ts.pt",
            url = "${BuildConfig.MODEL_BASE_URL}/clip_text_ts.pt",
            sha256 = "7d06dd86e914be7910063a1a9613e4591a1cf0d8fbfb5f6648d1bef4bb04b09b",
            sizeBytes = 253829539L
        )
    )

    // The face recognition model (ArcFace ResNet50, InsightFace w600k_r50). Kept
    // apart from MODELS on purpose: search and indexing must keep working for
    // anyone who never downloads it. It goes in "face_models", the folder the
    // face pipeline already looks in, so nothing else needs to know where it is.
    val FACE_MODELS: List<RemoteModel> = listOf(
        RemoteModel(
            id = "face_recognition",
            fileName = "w600k_r50.onnx",
            url = "${BuildConfig.MODEL_BASE_URL}/w600k_r50.onnx",
            sha256 = "4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43",
            sizeBytes = 174383860L,
            group = ModelGroup.FACES,
            folder = "face_models"
        )
    )

    val ALL: List<RemoteModel> = MODELS + FACE_MODELS

    fun forGroups(groups: Collection<String>): List<RemoteModel> = ALL.filter { it.group in groups }

    val totalBytes: Long get() = MODELS.sumOf { it.sizeBytes }
}
