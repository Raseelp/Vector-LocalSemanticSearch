package dev.twentyonevision.app.embedder

import android.content.Context
import android.net.Uri
import org.pytorch.IValue
import org.pytorch.Module
import org.pytorch.Tensor
import com.facebook.soloader.SoLoader
import dev.twentyonevision.app.embedder.models.ModelCatalog
import dev.twentyonevision.app.embedder.models.ModelManager
import dev.twentyonevision.app.embedder.models.ModelsNotReadyException
import dev.twentyonevision.app.embedder.storage.EmbeddingRecord
import dev.twentyonevision.app.embedder.storage.EmbeddingStore
import dev.twentyonevision.app.embedder.storage.HashUtils
import androidx.documentfile.provider.DocumentFile
import android.provider.DocumentsContract
import android.util.Log
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future


class EmbeddingEngine(
    private val context: Context,
    private val modelManager: ModelManager
) {

    // Loaded lazily - always go through ensureModelsLoaded() first.
    private var visionModule: Module? = null
    private var textModule: Module? = null
    private val store: EmbeddingStore

    // A single Module instance isn't safe to call forward() on from two
    // threads at once. Search can now run at the same time as a scan (see
    // MainActivity), and image-based search shares this exact vision
    // module with scanning - so every actual forward() call on it goes
    // through this lock. Only the call itself is locked, not the tensor
    // prep around it, so a wait here is short: at most one batch's worth
    // of inference time, not the other side's whole operation.
    private val visionLock = Any()
    private val textLock = Any()

    private var lastEmit: Long = 0L
    private var startTimeMs: Long = 0L

    @Volatile
    private var isCancelled = false

    // Small rolling window of the most-recently embedded files, newest
    // first - feeds the "recently indexed" strip in the UI. Only ever
    // touched from the scan's own thread, same as lastEmit/startTimeMs
    // above, so it needs no locking of its own.
    private val recentItems = ArrayDeque<RecentEmbeddedItem>()

    private fun recordRecent(item: RecentEmbeddedItem) {
        recentItems.addFirst(item)
        while (recentItems.size > RECENT_WINDOW_SIZE) recentItems.removeLast()
    }

    companion object {
        private const val TAG = "EmbeddingEngine"
        private const val PROGRESS_INTERVAL_MS = 500L

        // How many images go into one forward() call, and how many decode
        // threads prepare tensors ahead of the inference thread. Tunable -
        // not measured against real devices yet.
        private const val INFERENCE_BATCH_SIZE = 4
        private const val PREP_THREAD_COUNT = 2

        // How many recently-embedded files to remember for the UI strip.
        private const val RECENT_WINDOW_SIZE = 10

        // Every image/frame tensor is always exactly 3x224x224 - fixed by
        // ImagePreprocessor - so batching can rely on this instead of
        // inspecting each Tensor's shape at runtime.
        private const val VISION_INPUT_SIZE = 224
    }

    init {
        SoLoader.init(context, false)
        store = EmbeddingStore(context)
    }

    // Throws ModelsNotReadyException if the download hasn't finished yet -
    // Dart checks areModelsReady() up front, this is just the backstop.
    @Synchronized
    private fun ensureModelsLoaded() {
        if (visionModule != null && textModule != null) return

        if (!modelManager.areModelsReady()) {
            throw ModelsNotReadyException("CLIP models are not downloaded yet")
        }

        if (visionModule == null) {
            val visionModel = ModelCatalog.MODELS.first { it.id == "vision" }
            visionModule = Module.load(modelManager.localFile(visionModel).absolutePath)
        }
        if (textModule == null) {
            val textModel = ModelCatalog.MODELS.first { it.id == "text" }
            textModule = Module.load(modelManager.localFile(textModel).absolutePath)
        }
    }

    fun cancelEmbedding() {
        isCancelled = true
    }

    fun encodeText(tokens: IntArray): FloatArray {
        require(tokens.size == 77) { "Expected 77 tokens, got ${tokens.size}" }

        ensureModelsLoaded()
        val text = textModule!!

        val longs = LongArray(77) { tokens[it].toLong() }
        val tensor = Tensor.fromBlob(longs, longArrayOf(1, 77))

        // Same reason as visionLock: a Module isn't safe to call from two
        // threads at once, and text encoding now happens off the main
        // thread (collections, search) so calls can overlap.
        return synchronized(textLock) {
            text
                .forward(IValue.from(tensor))
                .toTensor()
                .dataAsFloatArray
        }
    }

    fun embedImages(
        mode: String,
        folderUriString: String?,
        folderId: String,
        contentMode: String = "both",
        onProgress: (ScanProgress) -> Unit
    ): ScanResult {

        isCancelled = false
        startTimeMs = System.currentTimeMillis()
        lastEmit = startTimeMs
        recentItems.clear()
        Log.d(TAG, "embedImages: start — mode=$mode contentMode=$contentMode")

        ensureModelsLoaded()
        val vision = visionModule!!

        onProgress(
            ScanProgress(
                total = 0, processed = 0, embedded = 0,
                skipped = 0, elapsedMs = 0, done = false,
                path = "Preparing..."
            )
        )

        val scanImages = contentMode == "images" || contentMode == "both"
        val scanVideos = contentMode == "videos" || contentMode == "both"

        val imageFiles: List<ImageSource>
        val videoFiles: List<VideoSource>
        val label: String

        val runtime = Runtime.getRuntime()

        if (mode == "device") {

            Log.d(TAG, "embedImages: loading device images (scanImages=$scanImages)...")
            imageFiles = if (scanImages) {
                getAllDeviceImages().also {
                    Log.d(TAG, "embedImages: got ${it.size} images, mem=${
                        (runtime.totalMemory() - runtime.freeMemory()) / 1_048_576}MB")
                }
            } else emptyList()

            Log.d(TAG, "embedImages: loading device videos (scanVideos=$scanVideos)...")
            videoFiles = if (scanVideos) {
                getAllDeviceVideos().also {
                    Log.d(TAG, "embedImages: got ${it.size} videos, mem=${
                        (runtime.totalMemory() - runtime.freeMemory()) / 1_048_576}MB")
                }
            } else emptyList()

            label = "Full device scan"

        } else {
            val folderUri = Uri.parse(folderUriString!!)
            val label0 = getDisplayPath(folderUriString)

            // Surface progress during the (possibly slow) SAF traversal so
            // the UI doesn't just sit on "Preparing..." looking hung. No
            // folder label here on purpose - label0 can be an arbitrarily
            // long path, and the UI only has one line to show this in
            // before a total is known.
            var foundSoFar = 0
            val onFileFound: () -> Unit = {
                foundSoFar++
                val now = System.currentTimeMillis()
                if (now - lastEmit > PROGRESS_INTERVAL_MS) {
                    onProgress(
                        ScanProgress(
                            total = 0, processed = 0, embedded = 0, skipped = 0,
                            elapsedMs = now - startTimeMs,
                            done = false,
                            path = "Found $foundSoFar files so far"
                        )
                    )
                    lastEmit = now
                }
            }

            imageFiles = if (scanImages) getFolderImages(folderUri, onFileFound) else emptyList()
            videoFiles = if (scanVideos && !isCancelled) {
                getFolderVideos(folderUri, onFileFound)
            } else emptyList()
            label = label0
        }

        // Enumeration itself can be cancelled - bail out before the scan loops.
        if (isCancelled) {
            onProgress(
                ScanProgress(
                    total = 0, processed = 0, embedded = 0, skipped = 0,
                    elapsedMs = System.currentTimeMillis() - startTimeMs,
                    done = true, path = label
                )
            )
            return ScanResult(0, 0, 0)
        }

        val total = imageFiles.size + videoFiles.size
        Log.d(TAG, "embedImages: total files to process = $total (${imageFiles.size} images + ${videoFiles.size} videos)")

        Log.d(TAG, "embedImages: reading existing hashes from store...")
        val existingHashes = try {
            store.readAll().map { it.hash }.toHashSet().also {
                Log.d(TAG, "embedImages: loaded ${it.size} existing hashes, mem=${
                    (runtime.totalMemory() - runtime.freeMemory()) / 1_048_576}MB")
            }
        } catch (e: Exception) {
            Log.e(TAG, "embedImages: FAILED reading existing hashes — ${e.message}", e)
            hashSetOf()
        }

        var processed = 0
        var embedded = 0
        var skipped = 0
        var failed = 0

        // Already-in-the-store files are filtered out here, upfront -
        // before shuffling/chunking anything - rather than left for
        // submitChunk/the video loop's own per-item check further down to
        // discover one at a time. A resumed scan of a mostly-finished
        // library needs this: if the done and not-done files stay mixed
        // together and get shuffled as one list, every chunk ends up with
        // at least one new file in it, so nothing is ever a fully-free,
        // instant-skip chunk - the progress bar crawls from 0 instead of
        // jumping straight to "8000 already done", and every chunk pays
        // for a real (now much smaller) inference call instead of only the
        // chunks with genuinely new files in them. Splitting first
        // restores both: the done portion is counted immediately below,
        // and only the genuinely new portion goes through shuffling and
        // the chunked inference pipeline.
        val newImages = mutableListOf<ImageSource>()
        for (img in imageFiles) {
            try {
                val hash = HashUtils.identityHash(img.size, img.lastModified, img.name)
                if (existingHashes.contains(hash)) skipped++ else newImages.add(img)
            } catch (e: Exception) {
                skipped++
                failed++
            }
        }
        val newVideos = mutableListOf<VideoSource>()
        for (video in videoFiles) {
            try {
                val hash = HashUtils.identityHash(video.size, video.lastModified, video.name)
                if (existingHashes.contains(hash)) skipped++ else newVideos.add(video)
            } catch (e: Exception) {
                skipped++
                failed++
            }
        }
        processed += skipped
        if (skipped > 0) {
            // Forced through even if it lands within the normal throttle
            // window - this jump should read as instant, not wait out
            // PROGRESS_INTERVAL_MS like a regular tick would.
            lastEmit = 0L
            emitProgressIfNeeded(total, processed, embedded, skipped, failed, label, onProgress)
        }

        val batchSize = 10
        val batch = mutableListOf<EmbeddingRecord>()

        // Images go through in small chunks: while one chunk's tensors are
        // being decoded on background threads, the previous (already
        // decoded) chunk is being batch-inferred on this thread. That
        // overlaps decode time with inference time instead of paying both
        // back to back per image, and running one forward() call per chunk
        // instead of per image cuts per-call overhead.
        val prepPool = Executors.newFixedThreadPool(PREP_THREAD_COUNT)
        try {
            data class PendingChunk(
                val toEmbed: List<Pair<ImageSource, Long>>,
                val futures: List<Future<Tensor?>>
            )

            fun submitChunk(chunk: List<ImageSource>): PendingChunk {
                val toEmbed = mutableListOf<Pair<ImageSource, Long>>()
                for (img in chunk) {
                    try {
                        val hash = HashUtils.identityHash(img.size, img.lastModified, img.name)
                        if (existingHashes.contains(hash)) {
                            skipped++
                        } else {
                            // Claimed now, not after a successful embed - two
                            // chunks decoding at once must never both try to
                            // embed the same hash.
                            existingHashes.add(hash)
                            toEmbed.add(img to hash)
                        }
                    } catch (e: Exception) {
                        skipped++
                failed++
                    }
                }
                val futures = toEmbed.map { (img, _) ->
                    prepPool.submit(Callable {
                        try { ImagePreprocessor.loadAsTensor(context, img.uri) } catch (e: Exception) { null }
                    })
                }
                return PendingChunk(toEmbed, futures)
            }

            // Shuffled here, not at enumeration - order only actually
            // matters for files that are genuinely going to be embedded
            // this run (see the doc above on newImages/newVideos). Both
            // MediaStore and SAF hand back a fixed, roughly date/name-
            // ordered sequence, so without this, a scan that's still
            // running or gets interrupted again leaves search only able to
            // find whatever contiguous slice of the new content got
            // embedded first (e.g. only the oldest of this batch of new
            // photos). Shuffling means whatever's newly embedded at any
            // given moment is a random cross-section of what's new,
            // instead of skewed toward "whichever new file came first."
            val chunks = newImages.shuffled().chunked(INFERENCE_BATCH_SIZE)
            var prefetched: PendingChunk? = null

            for (chunkIndex in chunks.indices) {
                if (isCancelled) break

                val chunk = chunks[chunkIndex]
                val current = prefetched ?: submitChunk(chunk)
                prefetched = if (chunkIndex + 1 < chunks.size && !isCancelled) {
                    submitChunk(chunks[chunkIndex + 1])
                } else null

                val tensors = mutableListOf<Tensor>()
                val meta = mutableListOf<Pair<ImageSource, Long>>()
                for ((idx, pair) in current.toEmbed.withIndex()) {
                    val tensor = try { current.futures[idx].get() } catch (e: Exception) { null }
                    if (tensor == null) {
                        skipped++
                failed++
                    } else {
                        tensors.add(tensor)
                        meta.add(pair)
                    }
                }

                if (tensors.isNotEmpty()) {
                    val embeddings = runBatchedInference(vision, tensors)
                    for ((idx, pair) in meta.withIndex()) {
                        val embedding = embeddings[idx]
                        if (embedding == null) {
                            skipped++
                failed++
                        } else {
                            val (img, hash) = pair
                            batch.add(
                                EmbeddingRecord(
                                    imagePath = img.uri.toString(),
                                    hash = hash,
                                    embedding = embedding,
                                    folderId = folderId
                                )
                            )
                            embedded++
                            recordRecent(
                                RecentEmbeddedItem(
                                    uri = img.uri.toString(),
                                    isVideo = false,
                                    timestampMs = 0L
                                )
                            )
                            if (batch.size >= batchSize) {
                                store.appendBatch(batch)
                                batch.clear()
                            }
                        }
                    }
                }

                processed += chunk.size
                emitProgressIfNeeded(total, processed, embedded, skipped, failed, label, onProgress)
            }

            if (isCancelled && batch.isNotEmpty()) {
                store.appendBatch(batch)
                batch.clear()
            }
        } finally {
            prepPool.shutdownNow()
        }

        if (!isCancelled) {
            // Shuffled for the same reason newImages is above - only the
            // genuinely new videos, so an interrupted run's videos are a
            // random cross-section of what's new too, not just "whichever
            // came first."
            for (video in newVideos.shuffled()) {

                if (isCancelled) {
                    if (batch.isNotEmpty()) { store.appendBatch(batch); batch.clear() }
                    break
                }

                try {
                    val hash = HashUtils.identityHash(video.size, video.lastModified, video.name)

                    if (existingHashes.contains(hash)) {
                        skipped++
                    } else {
                        val frameRecords = embedVideoFile(
                            video = video,
                            hash = hash,
                            folderId = folderId,
                            vision = vision
                        )

                        if (frameRecords.isEmpty()) {
                            skipped++
                failed++
                        } else {
                            batch.addAll(frameRecords)
                            existingHashes.add(hash)
                            embedded += frameRecords.size
                            recordRecent(
                                RecentEmbeddedItem(
                                    uri = video.uri.toString(),
                                    isVideo = true,
                                    timestampMs = frameRecords.first().timestampMs
                                )
                            )

                            if (batch.size >= batchSize) {
                                store.appendBatch(batch)
                                batch.clear()
                            }
                        }
                    }
                } catch (e: Exception) {
                    skipped++
                failed++
                }

                processed++
                emitProgressIfNeeded(total, processed, embedded, skipped, failed, label, onProgress)
            }
        }

        if (batch.isNotEmpty()) store.appendBatch(batch)

        val elapsed = System.currentTimeMillis() - startTimeMs

        onProgress(
            ScanProgress(
                total = total,
                processed = processed,
                embedded = embedded,
                skipped = skipped,
                elapsedMs = elapsed,
                done = true,
                path = label,
                recentItems = recentItems.toList(),
                failed = failed
            )
        )

        return ScanResult(total, embedded, skipped)
    }

    private fun embedVideoFile(
        video: VideoSource,
        hash: Long,
        folderId: String,
        vision: Module
    ): List<EmbeddingRecord> {

        val videoUriString = video.uri.toString()

        val frames = VideoFrameExtractor.extractFrames(
            context = context,
            uri = video.uri
        )

        if (frames.isEmpty()) return emptyList()

        val tensors = mutableListOf<Tensor>()
        val timestamps = mutableListOf<Long>()

        for ((timestampMs, bitmap) in frames) {
            try {
                tensors.add(ImagePreprocessor.bitmapToTensor(bitmap))
                timestamps.add(timestampMs)
            } catch (e: Exception) {
                // one bad frame doesn't kill the whole video
            } finally {
                bitmap.recycle()
            }
        }

        if (tensors.isEmpty()) return emptyList()

        // All of a video's frames are already extracted by this point, so
        // one forward() call for all of them is a straightforward win - no
        // pipelining needed here, just batching.
        val embeddings = runBatchedInference(vision, tensors)
        val records = mutableListOf<EmbeddingRecord>()

        for (i in tensors.indices) {
            val embedding = embeddings[i] ?: continue
            records.add(
                EmbeddingRecord(
                    imagePath   = videoUriString,
                    hash        = hash,
                    embedding   = embedding,
                    folderId    = folderId,
                    videoUri    = videoUriString,
                    timestampMs = timestamps[i]
                )
            )
        }

        return records
    }

    /**
     * One forward() call for the whole batch instead of one per tensor -
     * cuts per-call overhead. Falls back to one-by-one, with per-tensor
     * isolation, if the batched call fails for any reason (a bad shape
     * assumption, an odd tensor, anything) - a wrong guess here can't crash
     * a scan, at worst it just loses the speedup.
     *
     * A null in the returned list means that specific tensor failed to
     * embed (caller should treat it as a skip, same as before batching).
     */
    private fun runBatchedInference(vision: Module, tensors: List<Tensor>): List<FloatArray?> {
        if (tensors.isEmpty()) return emptyList()

        if (tensors.size == 1) {
            return listOf(
                try {
                    synchronized(visionLock) {
                        vision.forward(IValue.from(tensors[0])).toTensor().dataAsFloatArray
                    }
                } catch (e: Exception) {
                    null
                }
            )
        }

        val batched = try {
            val perItemFloats = 3 * VISION_INPUT_SIZE * VISION_INPUT_SIZE
            val batchedData = FloatArray(tensors.size * perItemFloats)
            for ((i, t) in tensors.withIndex()) {
                System.arraycopy(t.dataAsFloatArray, 0, batchedData, i * perItemFloats, perItemFloats)
            }
            val batchedTensor = Tensor.fromBlob(
                batchedData,
                longArrayOf(tensors.size.toLong(), 3L, VISION_INPUT_SIZE.toLong(), VISION_INPUT_SIZE.toLong())
            )
            val output = synchronized(visionLock) {
                vision.forward(IValue.from(batchedTensor)).toTensor().dataAsFloatArray
            }
            val embeddingDim = output.size / tensors.size
            (0 until tensors.size).map { i -> output.copyOfRange(i * embeddingDim, (i + 1) * embeddingDim) }
        } catch (e: Exception) {
            Log.w(TAG, "runBatchedInference: batched forward failed (${e.message}), falling back to one-by-one", e)
            null
        }

        if (batched != null) return batched

        return tensors.map { t ->
            try {
                synchronized(visionLock) {
                    vision.forward(IValue.from(t)).toTensor().dataAsFloatArray
                }
            } catch (e: Exception) {
                null
            }
        }
    }


    private fun getFolderImages(
        folderUri: Uri,
        onFileFound: () -> Unit = {}
    ): List<ImageSource> {
        // Fast path: this folder's files are already in MediaStore's own
        // index (see FolderMediaStoreScan for exactly when that's true and
        // when it isn't) - query that instead of walking SAF live. Only
        // trusted when it comes back non-empty - null (not confident this
        // is correct) and empty (MediaStore genuinely has nothing indexed
        // under this path, which can happen even for a real, non-empty
        // folder - see FolderMediaStoreScan's DATA/RELATIVE_PATH doc) are
        // treated the same way: fall through to the real, verified walk.
        // The cost of double-checking a folder that turns out to actually
        // be empty is negligible; silently trusting a false empty isn't
        // worth the risk.
        val relativePath = FolderMediaStoreScan.resolvePrimaryRelativePath(folderUri)
        if (relativePath != null) {
            val fast = FolderMediaStoreScan.queryImages(context, relativePath)
            if (!fast.isNullOrEmpty()) return fast
        }

        // SafDocument already carries size/lastModified/name resolved from
        // the same query that found it - no per-file re-query needed here,
        // unlike the old DocumentFile-based version this replaced.
        return SafUtils.listImageFiles(
            context, folderUri,
            isCancelled = { isCancelled },
            onFileFound = onFileFound
        ).map {
            ImageSource(
                uri = it.uri,
                size = it.size,
                lastModified = it.lastModified,
                name = it.name
            )
        }
    }

    private fun getFolderVideos(
        folderUri: Uri,
        onFileFound: () -> Unit = {}
    ): List<VideoSource> {
        val relativePath = FolderMediaStoreScan.resolvePrimaryRelativePath(folderUri)
        if (relativePath != null) {
            val fast = FolderMediaStoreScan.queryVideos(context, relativePath)
            if (!fast.isNullOrEmpty()) return fast
        }

        return SafUtils.listVideoFiles(
            context, folderUri,
            isCancelled = { isCancelled },
            onFileFound = onFileFound
        ).map {
            VideoSource(
                uri = it.uri,
                size = it.size,
                lastModified = it.lastModified,
                name = it.name
            )
        }
    }

    private fun getAllDeviceImages(): List<ImageSource> {
        val result = mutableListOf<ImageSource>()

        val collection =
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q)
                android.provider.MediaStore.Images.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL
                )
            else
                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI

        val projection = arrayOf(
            android.provider.MediaStore.Images.Media._ID,
            android.provider.MediaStore.Images.Media.SIZE,
            android.provider.MediaStore.Images.Media.DATE_MODIFIED,
            android.provider.MediaStore.Images.Media.DISPLAY_NAME
        )

        context.contentResolver.query(
            collection, projection, null, null, null
        )?.use { cursor ->
            val idCol   = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media._ID)
            val sizeCol = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.SIZE)
            val modCol  = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.DATE_MODIFIED)
            val nameCol = cursor.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.DISPLAY_NAME)

            while (cursor.moveToNext()) {
                val id  = cursor.getLong(idCol)
                val uri = android.content.ContentUris.withAppendedId(collection, id)
                result.add(
                    ImageSource(
                        uri          = uri,
                        size         = cursor.getLong(sizeCol),
                        lastModified = cursor.getLong(modCol),
                        name         = cursor.getString(nameCol) ?: ""
                    )
                )
            }
        }

        return result
    }

    private fun getAllDeviceVideos(): List<VideoSource> {
        Log.d(TAG, "getAllDeviceVideos: starting")

        val result = mutableListOf<VideoSource>()

        val collection =
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                Log.d(TAG, "getAllDeviceVideos: using VOLUME_EXTERNAL (API ${android.os.Build.VERSION.SDK_INT})")
                android.provider.MediaStore.Video.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL
                )
            } else {
                Log.d(TAG, "getAllDeviceVideos: using EXTERNAL_CONTENT_URI (legacy)")
                android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }

        val projection = arrayOf(
            android.provider.MediaStore.Video.Media._ID,
            android.provider.MediaStore.Video.Media.SIZE,
            android.provider.MediaStore.Video.Media.DATE_MODIFIED,
            android.provider.MediaStore.Video.Media.DISPLAY_NAME
        )

        Log.d(TAG, "getAllDeviceVideos: querying MediaStore...")

        val cursor = try {
            context.contentResolver.query(
                collection,
                projection,
                null,
                null,
                "${android.provider.MediaStore.Video.Media.DATE_MODIFIED} DESC"
            )
        } catch (e: Exception) {
            Log.e(TAG, "getAllDeviceVideos: query THREW EXCEPTION — ${e.javaClass.simpleName}: ${e.message}", e)
            return emptyList()
        }

        if (cursor == null) {
            Log.e(TAG, "getAllDeviceVideos: cursor is NULL — permission likely denied")
            return emptyList()
        }

        Log.d(TAG, "getAllDeviceVideos: cursor obtained, count = ${cursor.count}")

        val runtime = Runtime.getRuntime()
        val usedMemMb = (runtime.totalMemory() - runtime.freeMemory()) / 1_048_576
        val maxMemMb  = runtime.maxMemory() / 1_048_576
        Log.d(TAG, "getAllDeviceVideos: memory before list build — used=${usedMemMb}MB max=${maxMemMb}MB")

        try {
            cursor.use { c ->
                val idCol   = c.getColumnIndexOrThrow(android.provider.MediaStore.Video.Media._ID)
                val sizeCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Video.Media.SIZE)
                val modCol  = c.getColumnIndexOrThrow(android.provider.MediaStore.Video.Media.DATE_MODIFIED)
                val nameCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Video.Media.DISPLAY_NAME)

                var rowCount = 0

                while (c.moveToNext()) {
                    try {
                        val id  = c.getLong(idCol)
                        val uri = android.content.ContentUris.withAppendedId(collection, id)

                        result.add(
                            VideoSource(
                                uri          = uri,
                                size         = c.getLong(sizeCol),
                                lastModified = c.getLong(modCol),
                                name         = c.getString(nameCol) ?: ""
                            )
                        )

                        rowCount++

                        if (rowCount % 500 == 0) {
                            val usedNow = (runtime.totalMemory() - runtime.freeMemory()) / 1_048_576
                            Log.d(TAG, "getAllDeviceVideos: processed $rowCount rows, used=${usedNow}MB")
                        }

                    } catch (e: Exception) {
                        Log.w(TAG, "getAllDeviceVideos: skipped row $rowCount — ${e.message}")
                    }
                }

                Log.d(TAG, "getAllDeviceVideos: cursor loop complete, total rows = $rowCount")
            }
        } catch (e: Exception) {
            Log.e(TAG, "getAllDeviceVideos: CRASHED during cursor iteration at result.size=${result.size} — ${e.javaClass.simpleName}: ${e.message}", e)
            return result
        }

        val usedAfter = (runtime.totalMemory() - runtime.freeMemory()) / 1_048_576
        Log.d(TAG, "getAllDeviceVideos: done — ${result.size} videos, used=${usedAfter}MB")

        return result
    }

    fun encodeImageFromUri(uriString: String): FloatArray {
        ensureModelsLoaded()

        val uri = Uri.parse(uriString)
        val tensor = ImagePreprocessor.loadAsTensor(context, uri)
            ?: throw Exception("Failed to load image")

        return synchronized(visionLock) {
            visionModule!!
                .forward(IValue.from(tensor))
                .toTensor()
                .dataAsFloatArray
        }
    }

    // Same as encodeImageFromUri, for a frame already decoded in memory (a
    // paused video frame) - goes through the exact same preprocessing and
    // model call, so its embedding is directly comparable to every stored
    // one. The caller keeps ownership of the bitmap (not recycled here).
    fun encodeBitmap(bitmap: android.graphics.Bitmap): FloatArray {
        ensureModelsLoaded()

        val tensor = ImagePreprocessor.bitmapToTensor(bitmap)

        return synchronized(visionLock) {
            visionModule!!
                .forward(IValue.from(tensor))
                .toTensor()
                .dataAsFloatArray
        }
    }

    fun searchByText(
        textEmbedding: FloatArray,
        topK: Int = 20,
        contentFilter: String = "both"
    ): List<SearchResult> {
        if (topK <= 0) return emptyList()

        val bestPerKey = mutableMapOf<String, SearchResult>()

        for (record in store.readAll()) {
            if (!matchesContentFilter(record, contentFilter)) continue

            val score = EmbeddingMath.dot(textEmbedding, record.embedding)

            val result = SearchResult(
                imagePath   = record.imagePath,
                score       = score,
                videoUri    = record.videoUri,
                timestampMs = record.timestampMs
            )

            // Collapse all frames of the same video into its best-scoring one.
            val dedupKey = record.videoUri ?: record.imagePath

            val existing = bestPerKey[dedupKey]
            if (existing == null || score > existing.score) {
                bestPerKey[dedupKey] = result
            }
        }

        return bestPerKey.values
            .sortedByDescending { it.score }
            .take(topK)
    }

    fun searchByImageEmbedding(
        imageEmbedding: FloatArray,
        topK: Int = 20,
        contentFilter: String = "both"
    ): List<SearchResult> {
        if (topK <= 0) return emptyList()

        val bestPerKey = mutableMapOf<String, SearchResult>()

        for (record in store.readAll()) {
            if (!matchesContentFilter(record, contentFilter)) continue

            val score = EmbeddingMath.dot(imageEmbedding, record.embedding)

            val result = SearchResult(
                imagePath   = record.imagePath,
                score       = score,
                videoUri    = record.videoUri,
                timestampMs = record.timestampMs
            )

            val dedupKey = record.videoUri ?: record.imagePath

            val existing = bestPerKey[dedupKey]
            if (existing == null || score > existing.score) {
                bestPerKey[dedupKey] = result
            }
        }

        return bestPerKey.values
            .sortedByDescending { it.score }
            .take(topK)
    }

    // A record with a non-null videoUri is a video frame, null means a
    // photo - the same distinction embedImages already uses to tell them
    // apart (see RecentEmbeddedItem construction). Any unrecognized filter
    // string behaves as "both", same as an absent one.
    // ---- Collections -------------------------------------------------------
    //
    // A collection's members aren't "the top K" - CLIP returns *something* for
    // any query, and raw similarity isn't comparable across queries ("dog"
    // and "handwritten note" live in completely different score ranges). So
    // membership is a per-query z-score: how far above that query's own
    // average score, across the whole library, an item sits. Self-calibrating
    // - no hand-tuned absolute thresholds - and cheap, since mean/sigma come
    // from the same pass as the scoring.

    data class CollectionSpec(
        val id: String,
        val embedding: FloatArray,
        val contentMode: String,
        // Standard deviations above the library-wide mean an item must reach.
        val k: Double
    )

    data class CollectionScore(
        val id: String,
        val count: Int,
        val covers: List<SearchResult>
    )

    // Every member of one collection, best match first. Video frames are
    // collapsed to the video's best frame, same as search.
    private fun collectionMembers(
        records: List<EmbeddingRecord>,
        spec: CollectionSpec
    ): List<SearchResult> {
        val scores = FloatArray(records.size)
        var n = 0
        var sum = 0.0
        var sumSq = 0.0

        for ((i, record) in records.withIndex()) {
            // A record of a different size (an index from another model) can't
            // be compared - skip it rather than let one bad record crash the
            // whole scoring pass.
            if (!matchesContentFilter(record, spec.contentMode) ||
                record.embedding.size != spec.embedding.size
            ) {
                scores[i] = Float.NaN
                continue
            }
            val score = EmbeddingMath.dot(spec.embedding, record.embedding)
            scores[i] = score
            n++
            sum += score
            sumSq += score.toDouble() * score
        }

        if (n < 2) return emptyList()

        val mean = sum / n
        val variance = (sumSq / n) - mean * mean
        val sigma = kotlin.math.sqrt(kotlin.math.max(variance, 0.0))
        // A flat score distribution has no outliers to call members.
        if (sigma < 1e-6) return emptyList()

        val threshold = mean + spec.k * sigma
        val bestPerKey = mutableMapOf<String, SearchResult>()

        for ((i, record) in records.withIndex()) {
            val score = scores[i]
            if (score.isNaN() || score < threshold) continue

            val key = record.videoUri ?: record.imagePath
            val existing = bestPerKey[key]
            if (existing == null || score > existing.score) {
                bestPerKey[key] = SearchResult(
                    imagePath = record.imagePath,
                    score = score,
                    videoUri = record.videoUri,
                    timestampMs = record.timestampMs
                )
            }
        }

        return bestPerKey.values.sortedByDescending { it.score }
    }

    // Count + a few cover items for each collection, in one read of the store.
    fun scoreCollections(specs: List<CollectionSpec>): List<CollectionScore> {
        val records = store.readAll()
        return specs.map { spec ->
            val members = collectionMembers(records, spec)
            CollectionScore(spec.id, members.size, members.take(6))
        }
    }

    fun collectionMembers(spec: CollectionSpec, limit: Int): List<SearchResult> {
        return collectionMembers(store.readAll(), spec).take(limit)
    }

    private fun matchesContentFilter(record: EmbeddingRecord, contentFilter: String): Boolean {
        return when (contentFilter) {
            "images" -> record.videoUri == null
            "videos" -> record.videoUri != null
            else -> true
        }
    }

    private fun emitProgressIfNeeded(
        total: Int,
        processed: Int,
        embedded: Int,
        skipped: Int,
        failed: Int,
        path: String,
        onProgress: (ScanProgress) -> Unit
    ) {
        val now = System.currentTimeMillis()
        if (now - lastEmit > PROGRESS_INTERVAL_MS) {
            onProgress(
                ScanProgress(
                    total     = total,
                    processed = processed,
                    embedded  = embedded,
                    skipped   = skipped,
                    elapsedMs = now - startTimeMs,
                    done      = false,
                    path      = path,
                    failed    = failed,
                    recentItems = recentItems.toList()
                )
            )
            lastEmit = now
        }
    }

    // Turns a SAF tree URI into "Internal Storage/DCIM/Camera" instead of
    // just "Camera" - uses getTreeDocumentId, not getDocumentId (that's for
    // /document/ URIs, not the /tree/ URIs we get here).
    fun getDisplayPath(uriString: String): String {
        val uri = Uri.parse(uriString)
        return try {
            val docId = DocumentsContract.getTreeDocumentId(uri)
            val parts = docId.split(":", limit = 2)
            val storageName = if (parts[0] == "primary") "Internal Storage" else parts[0]
            val relativePath = parts.getOrNull(1)
            if (relativePath.isNullOrEmpty()) storageName else "$storageName/$relativePath"
        } catch (e: Exception) {
            Log.w(TAG, "getDisplayPath: couldn't parse $uriString, falling back to leaf name", e)
            DocumentFile.fromTreeUri(context, uri)?.name ?: "Folder"
        }
    }

    fun deleteEmbeddingsForFolder(folderId: String) {
        store.deleteByFolderId(folderId)
    }

    fun getStoredCount(): Int = store.readAll().size

    fun getStoredCountForFolder(folderId: String): Int = store.countForFolder(folderId)

    // Looks up one specific stored item's embedding by the same identity
    // a search result already carries - imagePath for a photo, or
    // videoUri+timestampMs for the specific frame a video's result
    // represents (search collapses a video's several frames to its best-
    // scoring one - see searchByText's dedupKey). Null if it's since been
    // deleted/re-embedded and no longer matches.
    fun findEmbedding(imagePath: String, videoUri: String?, timestampMs: Long): FloatArray? {
        val records = store.readAll()
        return if (videoUri != null) {
            records.firstOrNull { it.videoUri == videoUri && it.timestampMs == timestampMs }?.embedding
        } else {
            records.firstOrNull { it.videoUri == null && it.imagePath == imagePath }?.embedding
        }
    }

    // Approximates "why this matched": scores each candidate query word's
    // own text embedding against one specific item's stored embedding, so
    // the caller can show which of the query's words individually pulled
    // the most weight for this result. Not a true per-pixel/region
    // explanation - CLIP doesn't offer that - just a per-concept one,
    // which is what's honestly available here.
    fun scoreWordsAgainstItem(
        itemEmbedding: FloatArray,
        words: List<Pair<String, IntArray>>
    ): List<Pair<String, Float>> {
        return words.mapNotNull { (word, tokens) ->
            try {
                val wordEmbedding = encodeText(tokens)
                word to EmbeddingMath.dot(wordEmbedding, itemEmbedding)
            } catch (e: Exception) {
                null
            }
        }
    }

    // Everything the Library tab's stats need, in one pass over the store
    // instead of separate calls that would each re-read it - readAll()
    // isn't free for a large library, so this matters once the caller
    // starts asking for it on a timer during an active scan (see
    // NativeController's live stats refresh).
    data class LibraryStats(
        val totalEmbeddings: Int,
        val images: Int,
        val videos: Int,
        val sizeBytes: Long
    )

    fun getLibraryStats(): LibraryStats {
        val records = store.readAll()

        // Distinct media items, not raw embedding rows - a video's several
        // frame records (see embedVideoFile) all share its videoUri, so
        // it's one video no matter how many frames it embedded as. Images
        // have no videoUri, so imagePath alone identifies them.
        val images = mutableSetOf<String>()
        val videos = mutableSetOf<String>()
        for (record in records) {
            val videoUri = record.videoUri
            if (videoUri != null) videos.add(videoUri) else images.add(record.imagePath)
        }

        return LibraryStats(
            totalEmbeddings = records.size,
            images = images.size,
            videos = videos.size,
            sizeBytes = store.sizeBytes()
        )
    }

    fun clearAll() = store.clear()
}