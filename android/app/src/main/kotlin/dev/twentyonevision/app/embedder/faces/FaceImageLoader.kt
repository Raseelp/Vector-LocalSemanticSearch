package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface

/**
 * Loads a photo for face detection: downsampled to a working size, and turned
 * upright using its EXIF orientation. The upright part matters - a phone photo
 * is often stored sideways with a "rotate me" tag, and the detector finds
 * nothing in a sideways face.
 */
object FaceImageLoader {

    // Long side of the working bitmap. Big enough that tiles of a group photo
    // still have real detail, small enough to stay around 16MB in memory.
    const val WORKING_SIDE = 2048

    /** A decoded photo plus the size the original has once upright (before any shrinking). */
    class LoadedPhoto(val bitmap: Bitmap, val originalWidth: Int, val originalHeight: Int)

    fun load(context: Context, uri: Uri, maxSide: Int = WORKING_SIDE): Bitmap? =
        loadWithInfo(context, uri, maxSide)?.bitmap

    /**
     * @param allowSlightlySmaller accept a decode up to ~10% under [maxSide] if that
     *   lets the decoder skip pixels (a 4000px photo comes out at 2000 instead of
     *   being fully decoded and shrunk to 2048): roughly twice as fast, and
     *   nobody can tell the difference for finding faces.
     */
    fun loadWithInfo(
        context: Context,
        uri: Uri,
        maxSide: Int = WORKING_SIDE,
        allowSlightlySmaller: Boolean = false,
    ): LoadedPhoto? {
        val resolver = context.contentResolver

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // Whether the stream opened is what's checked - a bounds-only decode
        // always returns a null bitmap by design, so its result says nothing.
        val boundsStream = resolver.openInputStream(uri) ?: return null
        boundsStream.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sample = 1
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        if (longest > 0) {
            val floor = if (allowSlightlySmaller) maxSide * 0.9f else maxSide.toFloat()
            while (longest / (sample * 2) >= floor) sample *= 2
        }

        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null

        var bitmap = decoded
        // Sampling only goes in powers of two - trim the rest with a scale.
        val decodedLongest = maxOf(bitmap.width, bitmap.height)
        if (decodedLongest > maxSide) {
            val k = maxSide.toFloat() / decodedLongest
            val scaled = Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * k).toInt().coerceAtLeast(1),
                (bitmap.height * k).toInt().coerceAtLeast(1),
                true,
            )
            if (scaled !== bitmap) bitmap.recycle()
            bitmap = scaled
        }

        val orientation = try {
            resolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            } ?: ExifInterface.ORIENTATION_NORMAL
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val turned = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
            orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
            orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
            orientation == ExifInterface.ORIENTATION_TRANSVERSE
        return LoadedPhoto(
            bitmap = upright(bitmap, orientation),
            originalWidth = if (turned) bounds.outHeight else bounds.outWidth,
            originalHeight = if (turned) bounds.outWidth else bounds.outHeight,
        )
    }

    fun upright(bitmap: Bitmap, orientation: Int): Bitmap {
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> m.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> m.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.postRotate(90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.postRotate(270f); m.postScale(-1f, 1f) }
            else -> return bitmap
        }
        val out = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        if (out !== bitmap) bitmap.recycle()
        return out
    }
}
