package dev.twentyonevision.app.embedder.faces

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * One face found in an image. Coordinates are in pixels of the bitmap that was
 * given to [FaceDetector.detect]. [landmarks] is 10 numbers: x,y of the left
 * eye, right eye, nose, left mouth corner, right mouth corner (from the
 * subject's point of view is not guaranteed - "left" means smaller x).
 */
class DetectedFace(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
    val landmarks: FloatArray,
    val score: Float,
) {
    val width get() = right - left
    val height get() = bottom - top
}

/**
 * SCRFD-2.5G face detector (InsightFace) running on ONNX Runtime; the model is
 * bundled in the app's assets. Standalone on purpose - it takes a bitmap and
 * returns faces, so a scan pass can call it from anywhere.
 *
 * Pass 1 runs the whole image letterboxed into 640x640. Big images then get a
 * second pass over overlapping tiles, because a face that is only a few pixels
 * wide at 640 becomes findable when its tile is blown up instead - this is what
 * makes group photos work.
 *
 * Not thread-safe by itself (buffers are reused); callers serialise with the
 * lock inside [detect].
 */
class FaceDetector(private val store: FaceModelStore) : AutoCloseable {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private val lock = Any()

    // Sized for the loaded model's input (640 for SCRFD) - rebuilt on a swap.
    private var loaded: FaceModelSpec? = null
    private var inputSize = 640
    private var inputBuffer = FloatBuffer.allocate(0)
    private var pixels = IntArray(0)

    /** Id of the detector model in use, or null if none is installed. */
    val modelId: String? get() = store.selected(FaceModelKind.DETECTOR)?.spec?.id

    // The selected detector's session, reloaded if a different model was
    // chosen (or its settings changed) since the last call.
    private fun session(): OrtSession {
        val model = store.selected(FaceModelKind.DETECTOR)
            ?: throw IllegalStateException("No face detection model installed")
        val current = session
        if (current != null && loaded == model.spec) return current

        current?.close()
        val opened = store.openSession(model)
        session = opened
        loaded = model.spec
        inputSize = model.spec.inputSize
        inputBuffer = FloatBuffer.allocate(3 * inputSize * inputSize)
        pixels = IntArray(inputSize * inputSize)
        return opened
    }

    /**
     * @param tiled also scan overlapping tiles when the image is big enough
     *   for that to help (see class doc).
     */
    fun detect(
        bitmap: Bitmap,
        scoreThreshold: Float = DEFAULT_SCORE_THRESHOLD,
        tiled: Boolean = true,
    ): List<DetectedFace> = synchronized(lock) {
        session()
        val found = ArrayList<DetectedFace>()
        found += detectRegion(bitmap, 0, 0, bitmap.width, bitmap.height, scoreThreshold)

        if (tiled && max(bitmap.width, bitmap.height) >= TILING_MIN_SIDE) {
            found += detectTiles(bitmap, scoreThreshold)
        }
        nms(found, NMS_IOU)
    }

    // A 2x2 grid of tiles that each cover ~60% of the width/height, so
    // neighbours overlap by about 20% and a face on a seam is whole in one
    // of them. (Wide/tall panoramas get more tiles along the long side.)
    private fun detectTiles(bitmap: Bitmap, threshold: Float): List<DetectedFace> {
        val w = bitmap.width
        val h = bitmap.height
        val cols = if (w >= h * 1.8f) 3 else 2
        val rows = if (h >= w * 1.8f) 3 else 2
        val tileW = (w / (cols - (cols - 1) * 0.2f)).roundToInt()
        val tileH = (h / (rows - (rows - 1) * 0.2f)).roundToInt()

        val out = ArrayList<DetectedFace>()
        for (r in 0 until rows) {
            for (c in 0 until cols) {
                val x = if (cols == 1) 0 else ((w - tileW) * c / (cols - 1f)).roundToInt()
                val y = if (rows == 1) 0 else ((h - tileH) * r / (rows - 1f)).roundToInt()
                val faces = detectRegion(bitmap, x, y, tileW, tileH, threshold)
                for (f in faces) {
                    // A face touching a tile edge that isn't the image's
                    // edge is cut off by the crop - its box would be wrong,
                    // and the neighbouring tile has it whole.
                    val cutLeft = x > 0 && f.left <= EDGE_SLACK + x
                    val cutTop = y > 0 && f.top <= EDGE_SLACK + y
                    val cutRight = x + tileW < w && f.right >= x + tileW - EDGE_SLACK
                    val cutBottom = y + tileH < h && f.bottom >= y + tileH - EDGE_SLACK
                    if (!(cutLeft || cutTop || cutRight || cutBottom)) out += f
                }
            }
        }
        return out
    }

    // Detect inside one rectangle of the bitmap; results come back in the
    // whole bitmap's coordinates.
    private fun detectRegion(
        bitmap: Bitmap,
        rx: Int, ry: Int, rw: Int, rh: Int,
        threshold: Float,
    ): List<DetectedFace> {
        val scale = inputSize.toFloat() / max(rw, rh)
        val newW = max(1, (rw * scale).roundToInt())
        val newH = max(1, (rh * scale).roundToInt())

        // Crop + resize in one go, straight into the 640 canvas' top-left
        // corner (how InsightFace letterboxes); the rest stays zero.
        val region = if (rx == 0 && ry == 0 && rw == bitmap.width && rh == bitmap.height) {
            bitmap
        } else {
            Bitmap.createBitmap(bitmap, rx, ry, rw, rh)
        }
        val resized = resize(region, newW, newH)

        java.util.Arrays.fill(pixels, 0)
        val row = IntArray(newW)
        for (y in 0 until newH) {
            resized.getPixels(row, 0, newW, 0, y, newW, 1)
            System.arraycopy(row, 0, pixels, y * inputSize, newW)
        }
        // (createScaledBitmap hands back its input when nothing changes, so
        // check identity before recycling either.)
        if (resized !== bitmap) resized.recycle()
        if (region !== bitmap && region !== resized) region.recycle()

        // Channel-first, (v - mean) / std in the order the model wants (all
        // taken from its spec - SCRFD is RGB, (v - 127.5) / 128).
        val spec = loaded!!
        val plane = inputSize * inputSize
        val data = inputBuffer.array()
        val first = if (spec.rgb) 16 else 0
        val last = if (spec.rgb) 0 else 16
        val pad = -spec.mean / spec.std
        for (i in 0 until plane) {
            val inside = (i / inputSize) < newH && (i % inputSize) < newW
            if (inside) {
                val p = pixels[i]
                data[i] = (((p shr first) and 0xFF) - spec.mean) / spec.std
                data[plane + i] = (((p shr 8) and 0xFF) - spec.mean) / spec.std
                data[2 * plane + i] = (((p shr last) and 0xFF) - spec.mean) / spec.std
            } else {
                data[i] = pad
                data[plane + i] = pad
                data[2 * plane + i] = pad
            }
        }
        inputBuffer.rewind()

        val session = session()
        val inputName = session.inputNames.first()
        val tensor = OnnxTensor.createTensor(
            env, inputBuffer, longArrayOf(1, 3, inputSize.toLong(), inputSize.toLong())
        )

        val faces = ArrayList<DetectedFace>()
        tensor.use {
            session.run(mapOf(inputName to tensor)).use { result ->
                // Outputs: 3 score tensors, 3 box tensors, 3 landmark tensors,
                // each for strides 8, 16, 32 (graph order).
                for ((level, stride) in STRIDES.withIndex()) {
                    val scores = (result[level] as OnnxTensor).floatBuffer
                    val boxes = (result[level + 3] as OnnxTensor).floatBuffer
                    val points = (result[level + 6] as OnnxTensor).floatBuffer
                    val cells = inputSize / stride

                    for (gy in 0 until cells) {
                        for (gx in 0 until cells) {
                            for (a in 0 until ANCHORS_PER_CELL) {
                                val idx = (gy * cells + gx) * ANCHORS_PER_CELL + a
                                val score = scores.get(idx)
                                if (score < threshold) continue

                                val cx = (gx * stride).toFloat()
                                val cy = (gy * stride).toFloat()
                                val x1 = cx - boxes.get(idx * 4) * stride
                                val y1 = cy - boxes.get(idx * 4 + 1) * stride
                                val x2 = cx + boxes.get(idx * 4 + 2) * stride
                                val y2 = cy + boxes.get(idx * 4 + 3) * stride

                                val lm = FloatArray(10)
                                for (k in 0 until 5) {
                                    lm[k * 2] = toRegionX(cx + points.get(idx * 10 + k * 2) * stride, scale, rx, rw)
                                    lm[k * 2 + 1] = toRegionY(cy + points.get(idx * 10 + k * 2 + 1) * stride, scale, ry, rh)
                                }
                                faces += DetectedFace(
                                    toRegionX(x1, scale, rx, rw),
                                    toRegionY(y1, scale, ry, rh),
                                    toRegionX(x2, scale, rx, rw),
                                    toRegionY(y2, scale, ry, rh),
                                    lm,
                                    score,
                                )
                            }
                        }
                    }
                }
            }
        }
        return nms(faces, NMS_IOU)
    }

    // Shrinks in steps of at most half: one big bilinear jump (a 3000px photo
    // to 640) skips pixels and blurs small faces into noise, which costs
    // detections. Returns [src] itself if it already has the size.
    private fun resize(src: Bitmap, w: Int, h: Int): Bitmap {
        var current = src
        while (current.width / 2 >= w && current.height / 2 >= h) {
            val half = Bitmap.createScaledBitmap(current, current.width / 2, current.height / 2, true)
            if (current !== src) current.recycle()
            current = half
        }
        val out = if (current.width == w && current.height == h) current
        else Bitmap.createScaledBitmap(current, w, h, true)
        if (current !== src && current !== out) current.recycle()
        return out
    }

    // Canvas -> region -> bitmap coordinates, clamped to the region.
    private fun toRegionX(v: Float, scale: Float, rx: Int, rw: Int) =
        rx + (v / scale).coerceIn(0f, rw.toFloat())

    private fun toRegionY(v: Float, scale: Float, ry: Int, rh: Int) =
        ry + (v / scale).coerceIn(0f, rh.toFloat())

    private fun nms(faces: List<DetectedFace>, iouLimit: Float): List<DetectedFace> {
        val sorted = faces.sortedByDescending { it.score }
        val kept = ArrayList<DetectedFace>()
        for (f in sorted) {
            if (kept.none { iou(it, f) > iouLimit }) kept += f
        }
        return kept
    }

    private fun iou(a: DetectedFace, b: DetectedFace): Float {
        val ix = max(0f, min(a.right, b.right) - max(a.left, b.left))
        val iy = max(0f, min(a.bottom, b.bottom) - max(a.top, b.top))
        val inter = ix * iy
        val union = a.width * a.height + b.width * b.height - inter
        return if (union <= 0f) 0f else inter / union
    }

    override fun close() {
        synchronized(lock) {
            session?.close()
            session = null
            loaded = null
        }
    }

    companion object {
        private val STRIDES = intArrayOf(8, 16, 32)
        private const val ANCHORS_PER_CELL = 2
        const val DEFAULT_SCORE_THRESHOLD = 0.5f
        private const val NMS_IOU = 0.4f

        // Below this, blowing tiles up gains nothing (the whole image is
        // already at or above the model's input size).
        private const val TILING_MIN_SIDE = 1000
        private const val EDGE_SLACK = 2f
    }
}
