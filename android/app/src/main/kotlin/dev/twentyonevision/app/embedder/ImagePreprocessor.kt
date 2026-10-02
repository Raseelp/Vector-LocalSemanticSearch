package dev.twentyonevision.app.embedder

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import kotlin.math.ceil

object ImagePreprocessor {

    private const val IMAGE_SIZE = 224

    private val MEAN = floatArrayOf(
        0.48145466f,
        0.4578275f,
        0.40821073f
    )

    private val STD = floatArrayOf(
        0.26862954f,
        0.26130258f,
        0.27577711f
    )

    fun loadAsFloatArray(
        context: Context,
        uri: Uri
    ): FloatArray? {
        return try {
            val bitmap = loadAndResizeBitmap(context, uri) ?: return null
            val data = bitmapToFloatArray(bitmap)
            bitmap.recycle()
            data
        } catch (e: Exception) {
            null
        }
    }

    // CHW, RGB, each channel's 0..255 pixel value scaled to 0..1 then
    // (v - mean) / std - exactly what org.pytorch.torchvision's
    // TensorImageUtils.bitmapToFloat32Tensor used to produce with this same
    // MEAN/STD, just as a plain FloatArray instead of a PyTorch Tensor now
    // that inference goes through ONNX Runtime. getPixels always returns
    // standard 32-bit ARGB regardless of the Bitmap's own Config (RGB_565
    // included), so this doesn't care how the bitmap was decoded.
    fun bitmapToFloatArray(bitmap: Bitmap): FloatArray {
        val cropped = resizeAndCenterCrop(bitmap)
        val size = IMAGE_SIZE
        val plane = size * size
        val pixels = IntArray(plane)
        cropped.getPixels(pixels, 0, size, 0, 0, size, size)

        val data = FloatArray(3 * plane)
        for (i in 0 until plane) {
            val p = pixels[i]
            data[i] = ((p shr 16 and 0xFF) / 255f - MEAN[0]) / STD[0]
            data[plane + i] = ((p shr 8 and 0xFF) / 255f - MEAN[1]) / STD[1]
            data[2 * plane + i] = ((p and 0xFF) / 255f - MEAN[2]) / STD[2]
        }

        // Only recycle the cropped copy, never the original passed in
        if (cropped !== bitmap) {
            cropped.recycle()
        }

        return data
    }

    // CLIP's own preprocessing resizes the shorter side to 224 and center-
    // crops the rest, so a photo keeps its real proportions - only the
    // excess on the long side gets trimmed. Stretching straight to a
    // 224x224 square (what this used to do) warps every non-square photo,
    // which is most of them.
    private fun resizeAndCenterCrop(bitmap: Bitmap): Bitmap {
        val width = bitmap.width
        val height = bitmap.height

        if (width == IMAGE_SIZE && height == IMAGE_SIZE) return bitmap

        val shorterSide = minOf(width, height)
        val scale = IMAGE_SIZE.toFloat() / shorterSide
        val scaledWidth = ceil(width * scale).toInt().coerceAtLeast(IMAGE_SIZE)
        val scaledHeight = ceil(height * scale).toInt().coerceAtLeast(IMAGE_SIZE)

        val resized = Bitmap.createScaledBitmap(bitmap, scaledWidth, scaledHeight, true)

        val cropLeft = ((scaledWidth - IMAGE_SIZE) / 2).coerceAtLeast(0)
        val cropTop = ((scaledHeight - IMAGE_SIZE) / 2).coerceAtLeast(0)
        val cropped = Bitmap.createBitmap(resized, cropLeft, cropTop, IMAGE_SIZE, IMAGE_SIZE)

        if (resized !== cropped) {
            resized.recycle()
        }

        return cropped
    }

    private fun loadAndResizeBitmap(
        context: Context,
        uri: Uri
    ): Bitmap? {
        return context.contentResolver.openInputStream(uri)?.use { stream ->

            val boundsOptions = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeStream(stream, null, boundsOptions)
            stream.close()

            val sampleSize = calculateInSampleSize(
                boundsOptions.outWidth,
                boundsOptions.outHeight,
                IMAGE_SIZE
            )

            context.contentResolver.openInputStream(uri)?.use { stream2 ->
                val decodeOptions = BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.RGB_565
                    inSampleSize = sampleSize
                    inMutable = false
                }

                val sampledBitmap = BitmapFactory.decodeStream(stream2, null, decodeOptions)
                    ?: return null

                val finalBitmap = resizeAndCenterCrop(sampledBitmap)

                if (finalBitmap !== sampledBitmap) {
                    sampledBitmap.recycle()
                }

                finalBitmap
            }
        }
    }

    private fun calculateInSampleSize(
        width: Int,
        height: Int,
        targetSize: Int
    ): Int {
        var inSampleSize = 1

        while (width / (inSampleSize * 2) >= targetSize &&
            height / (inSampleSize * 2) >= targetSize
        ) {
            inSampleSize *= 2
        }

        return inSampleSize
    }
}
