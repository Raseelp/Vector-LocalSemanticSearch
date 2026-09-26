package dev.twentyonevision.app.embedder.faces

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint

/**
 * Straightens a face for the recognition model: finds the rotate + scale +
 * shift that best lands the face's five landmarks on the standard ArcFace
 * positions, and redraws the face through it into a small square. Every
 * ArcFace-family model (ArcFace, AdaFace, MobileFaceNet, SFace...) expects
 * exactly this layout, so it's independent of which one is in use - only the
 * output size changes.
 */
object FaceAligner {

    // ArcFace's reference landmarks on a 112x112 face: left eye, right eye,
    // nose tip, left mouth corner, right mouth corner (left = smaller x).
    private val TEMPLATE_112 = floatArrayOf(
        38.2946f, 51.6963f,
        73.5318f, 51.5014f,
        56.0252f, 71.7366f,
        41.5493f, 92.3655f,
        70.7299f, 92.2041f,
    )

    /** [landmarks] is 10 numbers (x,y for each of the five points) in [src] pixels. */
    fun align(src: Bitmap, landmarks: FloatArray, size: Int): Bitmap {
        val k = size / 112f
        val dst = FloatArray(10) { TEMPLATE_112[it] * k }

        // Least-squares similarity transform (no shear, no flip): with the
        // points centred, x' = a*x - b*y + tx, y' = b*x + a*y + ty.
        var smx = 0f; var smy = 0f; var dmx = 0f; var dmy = 0f
        for (i in 0 until 5) {
            smx += landmarks[i * 2]; smy += landmarks[i * 2 + 1]
            dmx += dst[i * 2]; dmy += dst[i * 2 + 1]
        }
        smx /= 5; smy /= 5; dmx /= 5; dmy /= 5

        var dot = 0f; var cross = 0f; var norm = 0f
        for (i in 0 until 5) {
            val sx = landmarks[i * 2] - smx
            val sy = landmarks[i * 2 + 1] - smy
            val dx = dst[i * 2] - dmx
            val dy = dst[i * 2 + 1] - dmy
            dot += sx * dx + sy * dy
            cross += sx * dy - sy * dx
            norm += sx * sx + sy * sy
        }
        val a = if (norm > 0f) dot / norm else 1f
        val b = if (norm > 0f) cross / norm else 0f
        val tx = dmx - (a * smx - b * smy)
        val ty = dmy - (b * smx + a * smy)

        val matrix = Matrix().apply { setValues(floatArrayOf(a, -b, tx, b, a, ty, 0f, 0f, 1f)) }
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(src, matrix, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        return out
    }
}
