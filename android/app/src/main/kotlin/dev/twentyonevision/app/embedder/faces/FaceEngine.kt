package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.graphics.Bitmap

/** A face cut out and straightened for recognition, with how sharp it is. */
class AlignedFace(val bitmap: Bitmap, val sharpness: Float)

/**
 * The whole face pipeline behind one object: detect -> align -> embed. It knows
 * nothing about specific networks - [FaceModelStore] supplies whichever
 * detector and embedder are selected - so scanning and anything later use this
 * and stay unchanged when a model is swapped.
 */
class FaceEngine(context: Context) : AutoCloseable {

    val store = FaceModelStore(context.applicationContext)
    private val detector = FaceDetector(store)
    private val embedder = FaceEmbedder(store)

    /** True when both a detector and a recognition model are installed. */
    fun isReady(): Boolean =
        store.selected(FaceModelKind.DETECTOR) != null && embedder.isAvailable()

    /**
     * Identifies the detector + recognition pair. Stored vectors are only
     * comparable with ones made by the same pair, so a change means
     * everything is redone.
     */
    fun modelKey(): String? {
        val det = detector.modelId ?: return null
        val emb = embedder.modelId ?: return null
        return "$det|$emb"
    }

    /** Every face in [bitmap] (an upright photo). The model is read fresh each call, so a swap needs no restart. */
    fun detect(bitmap: Bitmap, thorough: Boolean): List<DetectedFace> =
        detector.detect(bitmap, tiled = thorough)

    /**
     * Cuts and straightens one face (landmarks are 10 numbers in [bitmap]'s
     * pixels). Cheap, and it tells how sharp the face is - so the caller can
     * decide whether it is worth the far more expensive [embedAligned].
     */
    fun align(bitmap: Bitmap, landmarks: FloatArray): AlignedFace {
        val aligned = FaceAligner.align(bitmap, landmarks, embedder.inputSize)
        return AlignedFace(aligned, FaceQuality.sharpness(aligned))
    }

    /** Recognises aligned faces, several per model run. The caller still owns the bitmaps. */
    fun embedAligned(faces: List<Bitmap>): List<FloatArray> = embedder.embedBatch(faces)

    /** Drops the loaded models; they reopen (with fresh tuning) on next use. */
    fun reloadSessions() {
        detector.close()
        embedder.close()
    }

    override fun close() {
        detector.close()
        embedder.close()
    }
}
