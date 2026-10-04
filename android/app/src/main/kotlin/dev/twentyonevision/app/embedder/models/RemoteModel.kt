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

    /**
     * The optional fast face recognition model. Never part of setup: it is downloaded
     * from the Face options, and sits next to the accurate one rather than replacing it.
     */
    const val FACES_FAST = "faces_fast"
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

    // The small, fast face recognition model (MobileFaceNet, InsightFace w600k_mbf, taken
    // from the buffalo_s pack; its output shape is declared with a flexible batch size so
    // several faces can be recognised in one run). Optional and kept apart from
    // FACE_MODELS on purpose: setup downloads only the accurate model, and the two can
    // be on the device together - the Face options choose which one runs. Same folder,
    // so the face pipeline finds it with the other.
    val FACE_MODELS_FAST: List<RemoteModel> = listOf(
        RemoteModel(
            id = "face_recognition_fast",
            fileName = "w600k_mbf.onnx",
            url = "${BuildConfig.MODEL_BASE_URL}/w600k_mbf.onnx",
            sha256 = "81ffd4b788d5c2cb5d9bf25056b7e793bf64322d7796eceff9db6c0272a0e998",
            sizeBytes = 13613018L,
            group = ModelGroup.FACES_FAST,
            folder = "face_models"
        )
    )

    val ALL: List<RemoteModel> = MODELS + FACE_MODELS + FACE_MODELS_FAST

    fun forGroups(groups: Collection<String>): List<RemoteModel> = ALL.filter { it.group in groups }

    val totalBytes: Long get() = MODELS.sumOf { it.sizeBytes }
}
