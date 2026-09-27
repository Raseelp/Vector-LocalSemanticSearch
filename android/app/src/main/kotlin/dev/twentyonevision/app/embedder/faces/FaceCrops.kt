package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max

/**
 * Square face pictures for avatars and the review grid, cut from the photo on
 * demand and cached on disk (the cache can be cleared by the system; it just
 * gets remade).
 */
class FaceCrops(private val context: Context, private val store: FaceStore) {

    private val dir: File get() = File(context.cacheDir, "face_crops").also { it.mkdirs() }

    fun crop(faceId: Long, size: Int = DEFAULT_SIZE): ByteArray? {
        val cached = File(dir, "${faceId}_$size.jpg")
        if (cached.exists()) return cached.readBytes()

        val location = store.faceLocation(faceId) ?: return null

        // A face found in a video: its picture was kept when it was found (a video frame
        // can't be cut out again cheaply).
        if (location.isVideo) {
            val kept = store.cropFile(faceId)
            return if (kept.exists()) kept.readBytes() else null
        }

        val photo = FaceImageLoader.load(context, Uri.parse(location.photoUri), decodeSideFor(location, size))
            ?: return null
        try {
            val bytes = render(photo, location.boxL, location.boxT, location.boxR, location.boxB, size) ?: return null
            try { cached.writeBytes(bytes) } catch (_: Exception) {}
            return bytes
        } finally {
            photo.recycle()
        }
    }

    /**
     * The square picture of a face from [photo] (box as 0..1 fractions of it): the face plus
     * a little around it, as JPEG. Does not recycle [photo].
     */
    fun render(photo: Bitmap, boxL: Float, boxT: Float, boxR: Float, boxB: Float, size: Int = DEFAULT_SIZE): ByteArray? {
        val w = photo.width.toFloat()
        val h = photo.height.toFloat()
        val cx = (boxL + boxR) / 2f * w
        // A little above centre so hair and forehead are in frame.
        val cy = (boxT + boxB) / 2f * h - (boxB - boxT) * h * 0.04f
        val side = max((boxR - boxL) * w, (boxB - boxT) * h) * MARGIN

        // The square around the face may hang over the photo's edge: draw
        // only the part that exists, in the matching part of the output.
        val left = cx - side / 2f
        val top = cy - side / 2f
        val src = Rect(
            max(0f, left).toInt(), max(0f, top).toInt(),
            minOf(w, left + side).toInt(), minOf(h, top + side).toInt(),
        )
        if (src.width() <= 0 || src.height() <= 0) return null
        val scale = size / side
        val dst = Rect(
            ((src.left - left) * scale).toInt(), ((src.top - top) * scale).toInt(),
            ((src.right - left) * scale).toInt(), ((src.bottom - top) * scale).toInt(),
        )

        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(Color.rgb(228, 230, 227))
        canvas.drawBitmap(photo, src, dst, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))

        val bytes = ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, 86, it) }.toByteArray()
        out.recycle()
        return bytes
    }

    // A face is usually a small part of the photo, so the whole photo is decoded
    // only as large as needed for the crop to come out at [size]: a face a sixth of
    // the way across needs a fraction of the pixels a full decode would make, and
    // JPEG decoding at a quarter size is several times quicker.
    private fun decodeSideFor(location: FaceLocation, size: Int): Int {
        if (location.photoW <= 0 || location.photoH <= 0) return FALLBACK_SIDE
        val cropRef = max(
            (location.boxR - location.boxL) * location.photoW,
            (location.boxB - location.boxT) * location.photoH,
        ) * MARGIN
        val refLong = max(location.photoW, location.photoH)
        val needed = (size * refLong / max(cropRef, 1f)).toInt()
        return needed.coerceIn(MIN_SIDE, MAX_SIDE)
    }

    companion object {
        const val DEFAULT_SIZE = 256
        private const val FALLBACK_SIDE = 1600
        private const val MIN_SIDE = 640
        private const val MAX_SIDE = 2560
        // Box side * this = crop side (the face plus some surroundings).
        private const val MARGIN = 1.7f
    }
}
