package dev.twentyonevision.app.embedder

import android.content.Context
import dev.twentyonevision.app.embedder.models.ModelManager

// Process-wide, not tied to any MainActivity instance - the same reason
// ScanForegroundService's progress sink and notification cache are
// process-wide (see its doc). Removing the app from Recents doesn't kill
// this process, only recreates the Activity/Flutter engine, and a scan
// keeps running via its own thread on whichever EmbeddingEngine instance
// started it. A method-channel call like cancelEmbedding has to reach that
// SAME instance - a fresh per-Activity one (the old lateinit var here)
// would silently act on an idle engine instead, which is exactly the "Stop
// indexing does nothing after reopening from Recents" bug.
//
// Deliberately does NOT also hold the scan's executor - that was tried and
// reverted. A quick query like areModelsReady (which Dart's startup calls
// unconditionally, before it even knows a scan is running) would then queue
// behind an already-running scan on the one shared thread and never
// return, hanging the app on its loading spinner. cancelEmbedding doesn't
// need the executor anyway - it just flips a flag directly on the shared
// engine below - so only the engine/model-manager instances need to be
// process-wide, not the thread they happen to run on.
object ScanEngineHolder {

    @Volatile
    private var modelManagerInstance: ModelManager? = null
    @Volatile
    private var embeddingEngineInstance: EmbeddingEngine? = null

    fun modelManager(context: Context): ModelManager =
        modelManagerInstance ?: synchronized(this) {
            modelManagerInstance ?: ModelManager(context.applicationContext).also {
                modelManagerInstance = it
            }
        }

    fun embeddingEngine(context: Context): EmbeddingEngine =
        embeddingEngineInstance ?: synchronized(this) {
            embeddingEngineInstance ?: EmbeddingEngine(
                context.applicationContext,
                modelManager(context)
            ).also { embeddingEngineInstance = it }
        }
}
