package dev.twentyonevision.app.embedder.faces

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.graphics.Bitmap
import java.nio.FloatBuffer
import kotlin.math.sqrt

/**
 * Turns an aligned face into an identity vector, using whichever embedder model
 * [FaceModelStore] currently selects. Nothing here is specific to one network:
 * the input size, normalisation and channel order come from its spec, and the
 * vector length is whatever the model outputs. Vectors are scaled to length 1,
 * so a plain dot product between two is their cosine similarity.
 *
 * Swapping the model at runtime is picked up automatically on the next call
 * (see [modelId]); vectors from different models are not comparable, so
 * anything stored must be tagged with the id it came from.
 */
class FaceEmbedder(private val store: FaceModelStore) : AutoCloseable {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val lock = Any()

    private var session: OrtSession? = null
    private var loaded: FaceModelSpec? = null
    private var input: FloatBuffer? = null
    private var pixels = IntArray(0)

    /** Id of the model in use, or null if no embedder model is installed. */
    val modelId: String? get() = store.selected(FaceModelKind.EMBEDDER)?.spec?.id

    /** Input side length the current model wants (for the aligner). */
    val inputSize: Int get() = store.selected(FaceModelKind.EMBEDDER)?.spec?.inputSize ?: 112

    fun isAvailable() = store.selected(FaceModelKind.EMBEDDER) != null

    /**
     * Embeds several aligned faces, a few per model run - one run over a batch
     * is noticeably faster per face than separate runs. A model that only
     * accepts one face at a time is detected on first use and handled one by one.
     */
    fun embedBatch(aligned: List<Bitmap>): List<FloatArray> = synchronized(lock) {
        if (aligned.isEmpty()) return@synchronized emptyList<FloatArray>()
        val out = ArrayList<FloatArray>(aligned.size)
        var index = 0
        while (index < aligned.size) {
            val chunk = aligned.subList(index, minOf(index + MAX_BATCH, aligned.size))
            if (chunk.size > 1 && batchWorks) {
                try {
                    out += runBatch(chunk)
                } catch (e: Exception) {
                    batchWorks = false
                    for (face in chunk) out += runBatch(listOf(face))
                }
            } else {
                for (face in chunk) out += runBatch(listOf(face))
            }
            index += chunk.size
        }
        out
    }

    @Volatile private var batchWorks = true

    private fun runBatch(faces: List<Bitmap>): List<FloatArray> {
        val spec = ensureLoaded()
        val size = spec.inputSize
        val plane = size * size
        val n = faces.size
        val data = FloatArray(n * 3 * plane)
        val first = if (spec.rgb) 16 else 0
        val last = if (spec.rgb) 0 else 16

        for ((k, face) in faces.withIndex()) {
            require(face.width == size && face.height == size) {
                "Aligned face must be ${size}x$size, got ${face.width}x${face.height}"
            }
            face.getPixels(pixels, 0, size, 0, 0, size, size)
            val base = k * 3 * plane
            for (i in 0 until plane) {
                val p = pixels[i]
                data[base + i] = (((p shr first) and 0xFF) - spec.mean) / spec.std
                data[base + plane + i] = (((p shr 8) and 0xFF) - spec.mean) / spec.std
                data[base + 2 * plane + i] = (((p shr last) and 0xFF) - spec.mean) / spec.std
            }
        }

        val session = session!!
        val tensor = OnnxTensor.createTensor(
            env, FloatBuffer.wrap(data), longArrayOf(n.toLong(), 3, size.toLong(), size.toLong())
        )
        return tensor.use {
            session.run(mapOf(session.inputNames.first() to tensor)).use { result ->
                val buffer = (result[0] as OnnxTensor).floatBuffer
                val all = FloatArray(buffer.remaining())
                buffer.get(all)
                require(all.size % n == 0) { "Unexpected output size ${all.size} for $n faces" }
                val dim = all.size / n
                List(n) { k -> normalise(all.copyOfRange(k * dim, (k + 1) * dim)) }
            }
        }
    }

    /** @param aligned a square face already at [inputSize] (see [FaceAligner]). */
    fun embed(aligned: Bitmap): FloatArray = synchronized(lock) {
        val spec = ensureLoaded()
        val size = spec.inputSize
        require(aligned.width == size && aligned.height == size) {
            "Aligned face must be ${size}x$size, got ${aligned.width}x${aligned.height}"
        }

        val plane = size * size
        aligned.getPixels(pixels, 0, size, 0, 0, size, size)
        val data = input!!.array()
        // Channel planes in the order the model wants (RGB, or BGR).
        val first = if (spec.rgb) 16 else 0
        val last = if (spec.rgb) 0 else 16
        for (i in 0 until plane) {
            val p = pixels[i]
            data[i] = (((p shr first) and 0xFF) - spec.mean) / spec.std
            data[plane + i] = (((p shr 8) and 0xFF) - spec.mean) / spec.std
            data[2 * plane + i] = (((p shr last) and 0xFF) - spec.mean) / spec.std
        }
        input!!.rewind()

        val session = session!!
        val tensor = OnnxTensor.createTensor(
            env, input!!, longArrayOf(1, 3, size.toLong(), size.toLong())
        )
        tensor.use {
            session.run(mapOf(session.inputNames.first() to tensor)).use { result ->
                val buffer = (result[0] as OnnxTensor).floatBuffer
                val vector = FloatArray(buffer.remaining())
                buffer.get(vector)
                normalise(vector)
            }
        }
    }

    // Reloads when the selected model changed since the last call.
    private fun ensureLoaded(): FaceModelSpec {
        val model = store.selected(FaceModelKind.EMBEDDER)
            ?: throw IllegalStateException("No face recognition model installed")
        if (loaded?.id != model.spec.id || loaded != model.spec || session == null) {
            session?.close()
            session = store.openSession(model)
            loaded = model.spec
            input = FloatBuffer.allocate(3 * model.spec.inputSize * model.spec.inputSize)
            pixels = IntArray(model.spec.inputSize * model.spec.inputSize)
        }
        return model.spec
    }

    private fun normalise(v: FloatArray): FloatArray {
        var sum = 0.0
        for (x in v) sum += x * x
        val norm = sqrt(sum).toFloat()
        if (norm > 0f) for (i in v.indices) v[i] /= norm
        return v
    }

    override fun close() {
        synchronized(lock) {
            session?.close()
            session = null
            loaded = null
        }
    }

    companion object {
        // Faces per model run: big enough to amortise the cost, small enough to
        // keep memory modest.
        private const val MAX_BATCH = 8
    }
}
