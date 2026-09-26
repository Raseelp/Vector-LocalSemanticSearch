package dev.twentyonevision.app.embedder.faces

import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import org.json.JSONObject
import java.io.File

enum class FaceModelKind { DETECTOR, EMBEDDER }

/**
 * Everything the pipeline needs to know about one face model - the code never
 * hard-codes a particular network, it reads this. A model is just an `.onnx`
 * file; if it needs settings other than the defaults, a `<name>.json` next to
 * it overrides them:
 *
 *   { "kind": "embedder", "inputSize": 112, "mean": 127.5, "std": 127.5,
 *     "rgb": true, "name": "AdaFace R100" }
 *
 * Defaults (no JSON): a file whose name contains "det", "scrfd", "retina" or
 * "yunet" is a detector (SCRFD family, 640 input, (v-127.5)/128); anything else
 * is an ArcFace-style embedder (112 input, (v-127.5)/127.5, RGB).
 *
 *  - kind      "detector" or "embedder"
 *  - inputSize side of the square input the network expects
 *  - mean/std  each channel is (pixel - mean) / std, pixel in 0..255
 *  - rgb       false for models that want BGR channel order
 */
data class FaceModelSpec(
    val id: String,
    val kind: FaceModelKind,
    val displayName: String,
    val inputSize: Int,
    val mean: Float,
    val std: Float,
    val rgb: Boolean,
)

/** A model file found somewhere on the device, with its resolved settings. */
data class LocatedFaceModel(
    val spec: FaceModelSpec,
    val file: File?,       // on disk (dropped in / downloaded), or
    val assetName: String?, // bundled in the APK
    val sizeBytes: Long,
) {
    val source get() = if (file != null) "device" else "bundled"
}

/**
 * Finds face models and opens them. Nothing else in the face code knows where a
 * model lives, so swapping one is: put a new `.onnx` in the models folder (see
 * [modelsDir]) and choose it - no rebuild.
 *
 * Search order for the same id: the app's external files folder (reachable over
 * adb / a file manager), then its private files folder, then the APK's assets.
 */
class FaceModelStore(private val context: Context) {

    private val prefs = context.getSharedPreferences("face_models", Context.MODE_PRIVATE)
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()

    /** Where to drop model files (created on first use). */
    val modelsDir: File
        get() = (context.getExternalFilesDir("face_models") ?: File(context.filesDir, "face_models"))
            .also { it.mkdirs() }

    private val privateDir get() = File(context.filesDir, "face_models").also { it.mkdirs() }

    fun available(kind: FaceModelKind): List<LocatedFaceModel> = all().filter { it.spec.kind == kind }

    /** The model in use for [kind]: the one chosen last, else the first found. */
    fun selected(kind: FaceModelKind): LocatedFaceModel? {
        val models = available(kind)
        val chosen = prefs.getString(prefKey(kind), null)
        return models.firstOrNull { it.spec.id == chosen } ?: models.firstOrNull()
    }

    fun select(kind: FaceModelKind, id: String) {
        prefs.edit().putString(prefKey(kind), id).apply()
    }

    private fun prefKey(kind: FaceModelKind) = "selected_${kind.name.lowercase()}"

    /** Opens a session for [model] with the settings tuned for this phone; the caller closes it. */
    fun openSession(model: LocatedFaceModel): OrtSession =
        openSession(model, FaceTuner.configFor(context, model.spec))

    /** Opens a session with explicit settings (used by the tuner's benchmark). */
    fun openSession(model: LocatedFaceModel, config: RunConfig): OrtSession {
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(config.threads)
            setInterOpNumThreads(1)
            config.affinity?.let { addConfigEntry("session.intra_op_thread_affinities", it) }
            when (config.provider) {
                "xnnpack" -> addXnnpack(mapOf("intra_op_num_threads" to config.threads.toString()))
                "nnapi" -> addNnapi(java.util.EnumSet.of(ai.onnxruntime.providers.NNAPIFlags.USE_FP16))
            }
        }
        val file = model.file ?: copyAssetToCache(model.assetName!!)
        // From a path, not a byte array: a 170MB model would otherwise sit in
        // memory twice while loading.
        return env.createSession(file.absolutePath, options)
    }

    // ONNX Runtime opens files by path, so a bundled model is unpacked once.
    // Re-copied after an app update (the bundled file may have changed). The
    // asset's size can't be asked for directly: assets are compressed in the
    // APK, and openFd() refuses those.
    private fun copyAssetToCache(assetName: String): File {
        val target = File(privateDir, ".bundled_$assetName")
        val stamp = File(privateDir, ".bundled_$assetName.stamp")
        val version = installStamp()
        if (!target.exists() || !stamp.exists() || stamp.readText() != version) {
            context.assets.open(assetName).use { input ->
                target.outputStream().use { input.copyTo(it) }
            }
            stamp.writeText(version)
        }
        return target
    }

    private fun installStamp(): String = try {
        context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
    } catch (_: Exception) {
        "0"
    }

    // Counted once per asset by reading it through (a few MB at most).
    private val assetSizes = HashMap<String, Long>()

    private fun assetSize(name: String): Long = assetSizes.getOrPut(name) {
        try {
            context.assets.open(name).use { input ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                }
                total
            }
        } catch (_: Exception) {
            0L
        }
    }

    private fun all(): List<LocatedFaceModel> {
        val found = LinkedHashMap<String, LocatedFaceModel>()

        // Earlier sources win for the same id.
        for (dir in listOf(modelsDir, privateDir)) {
            // Hidden files (".bundled_*", the unpacked copies of bundled models) are not models.
            dir.listFiles { f -> f.isFile && !f.name.startsWith(".") && f.extension.equals("onnx", true) }
                ?.sortedBy { it.name }
                ?.forEach { file ->
                    val id = file.nameWithoutExtension
                    if (id !in found) {
                        val sidecar = File(dir, "$id.json").takeIf { it.exists() }?.readText()
                        found[id] = LocatedFaceModel(specFor(id, sidecar), file, null, file.length())
                    }
                }
        }

        val assets = context.assets.list("")?.filter { it.endsWith(".onnx", true) }?.sorted().orEmpty()
        for (name in assets) {
            val id = name.removeSuffix(".onnx")
            if (id in found) continue
            val sidecar = try {
                context.assets.open("$id.json").use { it.readBytes().toString(Charsets.UTF_8) }
            } catch (_: Exception) {
                null
            }
            found[id] = LocatedFaceModel(specFor(id, sidecar), null, name, assetSize(name))
        }
        return found.values.toList()
    }

    private fun specFor(id: String, sidecarJson: String?): FaceModelSpec {
        val lower = id.lowercase()
        val looksLikeDetector = listOf("det", "scrfd", "retina", "yunet").any { it in lower }
        val json = try { sidecarJson?.let { JSONObject(it) } } catch (_: Exception) { null }

        val kind = when (json?.optString("kind")?.lowercase()) {
            "detector" -> FaceModelKind.DETECTOR
            "embedder" -> FaceModelKind.EMBEDDER
            else -> if (looksLikeDetector) FaceModelKind.DETECTOR else FaceModelKind.EMBEDDER
        }
        val detector = kind == FaceModelKind.DETECTOR

        return FaceModelSpec(
            id = id,
            kind = kind,
            displayName = json?.optString("name")?.takeIf { it.isNotBlank() } ?: id,
            inputSize = json?.optInt("inputSize", 0)?.takeIf { it > 0 } ?: if (detector) 640 else 112,
            mean = json?.optDouble("mean", Double.NaN)?.takeIf { !it.isNaN() }?.toFloat() ?: 127.5f,
            std = json?.optDouble("std", Double.NaN)?.takeIf { !it.isNaN() }?.toFloat()
                ?: if (detector) 128f else 127.5f,
            rgb = json?.optBoolean("rgb", true) ?: true,
        )
    }
}
