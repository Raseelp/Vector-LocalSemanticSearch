package dev.twentyonevision.app.embedder.faces

import ai.onnxruntime.OnnxTensor
import android.content.Context
import android.util.Log
import java.io.File
import java.nio.FloatBuffer
import java.util.Random
import kotlin.math.sqrt

/** How a model's session is run: threads, which cores, and which ONNX Runtime backend. */
data class RunConfig(
    val threads: Int,
    /** ONNX Runtime thread-affinity string ("6;7"), or null to let the system place threads. */
    val affinity: String? = null,
    /** "cpu", "xnnpack" or "nnapi". */
    val provider: String = "cpu",
) {
    fun encode() = "$provider|$threads|${affinity ?: ""}"

    fun describe(): String = buildString {
        append(if (provider == "cpu") "CPU" else provider.uppercase())
        append(" x").append(threads)
        if (affinity != null) append(", fast cores")
    }

    companion object {
        fun decode(text: String?): RunConfig? {
            val parts = text?.split("|") ?: return null
            if (parts.size != 3) return null
            val threads = parts[1].toIntOrNull() ?: return null
            return RunConfig(threads, parts[2].ifEmpty { null }, parts[0])
        }
    }
}

/**
 * Finds the fastest way to run the face models on this particular phone, once,
 * and remembers it. Phones differ a lot (a few fast cores plus many slow ones is
 * common, and slow cores can hold back a job split evenly across all of them), so
 * instead of guessing, a short benchmark times the real models under several
 * settings - thread counts, pinning to the fast cores, alternative backends - and
 * keeps the winner. Results are stored per model, so swapping a model retunes.
 *
 * A backend that crashes the process while being tried is remembered and never
 * tried again (see the "trying" marker).
 */
object FaceTuner {

    private const val TAG = "FaceTuner"
    private const val PREFS = "face_tuning"

    // Bump to make every phone retune after this logic changes.
    private const val VERSION = 1

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun defaultThreads(kind: FaceModelKind): Int {
        val cpus = Runtime.getRuntime().availableProcessors()
        return if (kind == FaceModelKind.EMBEDDER) (cpus - 2).coerceIn(2, 4) else (cpus - 3).coerceIn(2, 3)
    }

    /** The settings to run [spec] with: the tuned ones, or sensible defaults before tuning. */
    fun configFor(context: Context, spec: FaceModelSpec): RunConfig =
        RunConfig.decode(saved(context, "cfg_", spec.id)) ?: RunConfig(defaultThreads(spec.kind))

    // Also finds what earlier builds saved under the unpacked copy's name (".bundled_...").
    private fun saved(context: Context, prefix: String, id: String): String? {
        val p = prefs(context)
        return p.getString("$prefix$id", null) ?: p.getString("$prefix.bundled_$id", null)
    }

    fun needsTuning(context: Context, store: FaceModelStore): Boolean {
        val p = prefs(context)
        if (p.getInt("version", 0) != VERSION) return true
        return listOf(FaceModelKind.DETECTOR, FaceModelKind.EMBEDDER).any { kind ->
            val model = store.selected(kind)
            model != null && saved(context, "cfg_", model.spec.id) == null
        }
    }

    /** Forget the tuning; the next scan runs the benchmark again. */
    fun reset(context: Context) {
        prefs(context).edit().clear().apply()
    }

    /** One line about what was chosen, for the options sheet. */
    fun summary(context: Context, store: FaceModelStore): String? {
        val p = prefs(context)
        val parts = listOf(FaceModelKind.EMBEDDER to "Recognition", FaceModelKind.DETECTOR to "Detection").mapNotNull { (kind, label) ->
            val model = store.selected(kind) ?: return@mapNotNull null
            val cfg = RunConfig.decode(saved(context, "cfg_", model.spec.id)) ?: return@mapNotNull null
            val ms = p.getFloat("ms_${model.spec.id}", p.getFloat("ms_.bundled_${model.spec.id}", 0f))
            "$label: ${cfg.describe()}" + if (ms > 0f) " (${ms.toInt()} ms)" else ""
        }
        return parts.takeIf { it.isNotEmpty() }?.joinToString("\n")
    }

    /**
     * Runs the benchmark (tens of seconds, blocking). Nothing is saved if
     * [shouldStop] interrupts it, so it simply runs again next time.
     */
    fun tune(context: Context, store: FaceModelStore, shouldStop: () -> Boolean) {
        val p = prefs(context)

        // A candidate that was being tried when the process died is unsafe here.
        p.getString("trying", null)?.let { crashed ->
            Log.w(TAG, "a previous test of $crashed never finished - not trying it again")
            p.edit().putStringSet("bad", (p.getStringSet("bad", emptySet()) ?: emptySet()) + crashed).remove("trying").commit()
        }
        val bad = p.getStringSet("bad", emptySet()) ?: emptySet()

        val chosen = HashMap<String, Pair<RunConfig, Float>>()
        for (kind in listOf(FaceModelKind.EMBEDDER, FaceModelKind.DETECTOR)) {
            val model = store.selected(kind) ?: continue
            if (shouldStop()) return
            // Interrupted: save nothing, so it runs again next time. If every
            // candidate simply failed, settle for the defaults instead of
            // retrying on every launch.
            val best = tuneModel(context, store, model, bad, shouldStop)
                ?: if (shouldStop()) return else RunConfig(defaultThreads(kind)) to 0f
            chosen[model.spec.id] = best
            Log.i(TAG, "${model.spec.id}: chose ${best.first.describe()} at ${best.second.toInt()} ms")
        }

        val editor = p.edit()
        for ((id, result) in chosen) {
            editor.putString("cfg_$id", result.first.encode())
            editor.putFloat("ms_$id", result.second)
        }
        editor.putInt("version", VERSION).commit()
    }

    private fun tuneModel(
        context: Context,
        store: FaceModelStore,
        model: LocatedFaceModel,
        bad: Set<String>,
        shouldStop: () -> Boolean,
    ): Pair<RunConfig, Float>? {
        val p = prefs(context)
        val isEmbedder = model.spec.kind == FaceModelKind.EMBEDDER
        val cpus = Runtime.getRuntime().availableProcessors()
        val big = bigCores()

        val input = randomInput(model.spec, if (isEmbedder) EMBED_BATCH else 1)
        val perUnit = if (isEmbedder) EMBED_BATCH else 1
        var reference: FloatArray? = null
        val results = ArrayList<Pair<RunConfig, Float>>()

        // Time one candidate; null if it failed, was unsafe, or gave wrong answers.
        fun attempt(config: RunConfig): Float? {
            val key = "${model.spec.id}:${config.encode()}"
            if (key in bad) return null
            if (shouldStop()) return null
            p.edit().putString("trying", key).commit()
            val outcome = try {
                benchmark(store, model, config, input, perUnit, results.minOfOrNull { it.second }, if (config.provider == "cpu") null else reference)
            } catch (e: Throwable) {
                Log.w(TAG, "$key failed: ${e.message}")
                null
            }
            p.edit().remove("trying").commit()
            if (outcome != null) {
                if (reference == null && config.provider == "cpu") reference = outcome.output
                results += config to outcome.msPerUnit
                Log.i(TAG, "$key -> ${outcome.msPerUnit.toInt()} ms")
            }
            return outcome?.msPerUnit
        }

        // Stage 1: how many threads on the plain CPU backend.
        val threadOptions = listOf(2, 3, 4).filter { it <= maxOf(2, cpus - 1) }
        for (t in threadOptions) attempt(RunConfig(t))
        if (shouldStop()) return null
        val bestCpu = results.minByOrNull { it.second }?.first ?: return null

        // Stage 2: pinned to the fast cores (if we can tell which they are), and
        // the alternative backends for the recognition model.
        if (big.size in 2..4) {
            attempt(RunConfig(big.size, big.drop(1).joinToString(";")))
        }
        if (isEmbedder) {
            attempt(RunConfig(bestCpu.threads, provider = "xnnpack"))
            attempt(RunConfig(bestCpu.threads, provider = "nnapi"))
        }
        if (shouldStop()) return null

        return results.minByOrNull { it.second }
    }

    private class Outcome(val msPerUnit: Float, val output: FloatArray)

    private fun benchmark(
        store: FaceModelStore,
        model: LocatedFaceModel,
        config: RunConfig,
        input: FloatArray,
        units: Int,
        bestSoFar: Float?,
        reference: FloatArray?,
    ): Outcome? {
        val env = ai.onnxruntime.OrtEnvironment.getEnvironment()
        val session = store.openSession(model, config)
        try {
            val size = model.spec.inputSize.toLong()
            val shape = longArrayOf(units.toLong(), 3, size, size)
            val name = session.inputNames.first()

            fun runOnce(): Pair<Long, FloatArray> {
                val tensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(input), shape)
                return tensor.use {
                    val start = System.nanoTime()
                    session.run(mapOf(name to tensor)).use { result ->
                        val elapsed = System.nanoTime() - start
                        val buffer = (result[0] as OnnxTensor).floatBuffer
                        val out = FloatArray(minOf(buffer.remaining(), OUTPUT_SAMPLE))
                        buffer.get(out)
                        elapsed to out
                    }
                }
            }

            // The first run pays one-off setup costs, so it isn't the measurement -
            // but if even that is far slower than the best so far, stop wasting time.
            val (warmNs, warmOut) = runOnce()
            val warmMs = warmNs / 1_000_000f / units
            if (reference != null && cosine(warmOut, reference) < MIN_SIMILARITY) {
                Log.w(TAG, "${config.encode()} gave different answers - rejected")
                return null
            }
            if (bestSoFar != null && warmMs > bestSoFar * 3f) return Outcome(warmMs, warmOut)

            var best = Float.MAX_VALUE
            repeat(TIMED_RUNS) {
                val (ns, _) = runOnce()
                best = minOf(best, ns / 1_000_000f / units)
            }
            return Outcome(best, warmOut)
        } finally {
            session.close()
        }
    }

    private fun randomInput(spec: FaceModelSpec, batch: Int): FloatArray {
        val random = Random(42)
        return FloatArray(batch * 3 * spec.inputSize * spec.inputSize) { (random.nextFloat() - 0.5f) * 2f }
    }

    private fun cosine(a: FloatArray, b: FloatArray): Float {
        val n = minOf(a.size, b.size)
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for (i in 0 until n) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return if (na == 0.0 || nb == 0.0) 0f else (dot / (sqrt(na) * sqrt(nb))).toFloat()
    }

    /**
     * The phone's fast cores, if they can be told apart: those running at the
     * highest maximum frequency. Empty if the system doesn't say (or all cores are alike).
     */
    fun bigCores(): List<Int> {
        val count = Runtime.getRuntime().availableProcessors()
        val freqs = (0 until count).map { i ->
            try {
                File("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq").readText().trim().toLong()
            } catch (_: Exception) {
                -1L
            }
        }
        if (freqs.any { it < 0 }) return emptyList()
        val top = freqs.max()
        val fast = freqs.indices.filter { freqs[it] == top }
        return if (fast.size in 1 until count) fast else emptyList()
    }

    private const val EMBED_BATCH = 4
    private const val TIMED_RUNS = 2
    private const val OUTPUT_SAMPLE = 4096

    // A backend must reproduce the plain CPU answers this closely to be used.
    private const val MIN_SIMILARITY = 0.98f
}
