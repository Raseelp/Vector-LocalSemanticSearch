package dev.twentyonevision.app.embedder.faces

import android.graphics.Bitmap
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt

/**
 * How trustworthy a face is for deciding who someone is. A weak face (tiny,
 * blurry, or turned far to the side) is still kept and shown, but it can't
 * start or reshape a person - only join one that better faces already made.
 * That is what stops a blurry background face dragging two people together.
 */
object FaceQuality {

    // Starting values - tuned by looking at real results, so kept together.
    // Faces smaller than MIN_EMBED_PX are not worth even storing; between that and
    // MIN_SIZE_PX they are kept but count as weak.
    const val MIN_EMBED_PX = 44
    const val MIN_SIZE_PX = 48
    const val MIN_SCORE = 0.6f
    const val MAX_YAW = 0.55f
    const val MIN_SHARPNESS = 20f

    /**
     * How far the nose sits off the line between the eyes, as a fraction of
     * the eye distance: ~0 facing the camera, ~0.3 at 45 degrees, 0.6+ in profile.
     */
    fun yaw(landmarks: FloatArray): Float {
        val dx = landmarks[2] - landmarks[0]
        val dy = landmarks[3] - landmarks[1]
        val eyeDist = sqrt(dx * dx + dy * dy)
        if (eyeDist <= 0f) return 1f
        val ux = dx / eyeDist
        val uy = dy / eyeDist
        val midX = (landmarks[0] + landmarks[2]) / 2f
        val midY = (landmarks[1] + landmarks[3]) / 2f
        val offset = (landmarks[4] - midX) * ux + (landmarks[5] - midY) * uy
        return abs(offset) / eyeDist
    }

    /** Variance of the Laplacian of the aligned face: low means blurry. */
    fun sharpness(aligned: Bitmap): Float {
        val w = aligned.width
        val h = aligned.height
        val pixels = IntArray(w * h)
        aligned.getPixels(pixels, 0, w, 0, 0, w, h)
        val gray = FloatArray(w * h) {
            val p = pixels[it]
            0.299f * ((p shr 16) and 0xFF) + 0.587f * ((p shr 8) and 0xFF) + 0.114f * (p and 0xFF)
        }
        var sum = 0.0
        var sumSq = 0.0
        var n = 0
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                val i = y * w + x
                val lap = 4f * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - w] - gray[i + w]
                sum += lap
                sumSq += lap * lap
                n++
            }
        }
        if (n == 0) return 0f
        val mean = sum / n
        return (sumSq / n - mean * mean).toFloat()
    }

    fun isGood(sizePx: Int, score: Float, sharpness: Float, yaw: Float): Boolean =
        sizePx >= MIN_SIZE_PX && score >= MIN_SCORE && yaw <= MAX_YAW && sharpness >= MIN_SHARPNESS

    /** Higher is a better example of the person (used to pick the cover face). */
    fun rank(sizePx: Int, score: Float, yaw: Float): Float =
        score * min(sizePx, 200) * (1f - 0.5f * min(yaw, 1f))
}
