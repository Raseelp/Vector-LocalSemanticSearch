package dev.twentyonevision.app.embedder

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build

object VideoFrameExtractor {

    // A device only has a handful of concurrent hardware video-decoder
    // sessions (sometimes very few on low/mid-range hardware). This app
    // creates a MediaMetadataRetriever in two places that can run at the
    // same time - this during a scan, and MainActivity's loadVideoThumbnail
    // for the "recently scanned" strip fetching a thumbnail for a video
    // this same scan just embedded. Without serializing them, both can hit
    // that limit and silently fail (setDataSource/getFrameAtTime throwing
    // or returning null, both swallowed) - a missing thumbnail, and/or that
    // video getting silently skipped this run and left for the next scan
    // to retry. Exposed so MainActivity can synchronize on the same lock -
    // see its loadVideoThumbnail handler.
    val decodeLock = Any()

    private const val DEFAULT_FRAME_COUNT = 10

    private fun adaptiveFrameCount(durationMs: Long): Int {
        return when {
            durationMs < 10_000L  -> 3
            durationMs < 30_000L  -> 5
            durationMs < 120_000L -> 8
            else                  -> 10
        }
    }

    fun extractFrames(
        context: Context,
        uri: Uri,
        frameCount: Int = -1
    ): List<Pair<Long, Bitmap>> = synchronized(decodeLock) {

        val retriever = MediaMetadataRetriever()

        return@synchronized try {
            retriever.setDataSource(context, uri)

            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: return emptyList()

            if (durationMs <= 0L) return emptyList()

            val resolvedFrameCount = if (frameCount <= 0) {
                adaptiveFrameCount(durationMs)
            } else {
                frameCount
            }

            val timestamps = (0 until resolvedFrameCount).map { i ->
                durationMs * (2 * i + 1) / (2 * resolvedFrameCount)
            }.sorted()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                retrieveFramesBatched(retriever, timestamps)
            } else {
                retrieveFramesSequential(retriever, timestamps)
            }

        } catch (e: Exception) {
            emptyList()
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }

    private fun retrieveFramesBatched(
        retriever: MediaMetadataRetriever,
        timestampsMs: List<Long>
    ): List<Pair<Long, Bitmap>> {

        val frameRateStr = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
            ?: retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)

        val fps = frameRateStr?.toFloatOrNull()
        if (fps == null || fps <= 0f) {
            return retrieveFramesSequential(retriever, timestampsMs)
        }

        val results = mutableListOf<Pair<Long, Bitmap>>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val frameIndices = timestampsMs.map { ms ->
                ((ms / 1000f) * fps).toInt().coerceAtLeast(0)
            }

            try {
                val bitmaps = retriever.getFramesAtIndex(
                    frameIndices.first(),
                    frameIndices.size
                )

                bitmaps?.forEachIndexed { i, bitmap ->
                    if (bitmap != null && i < timestampsMs.size) {
                        results.add(Pair(timestampsMs[i], bitmap))
                    }
                }

                if (results.isNotEmpty()) return results
            } catch (_: Exception) {}
        }

        return retrieveFramesSequential(retriever, timestampsMs)
    }

    private fun retrieveFramesSequential(
        retriever: MediaMetadataRetriever,
        timestampsMs: List<Long>
    ): List<Pair<Long, Bitmap>> {

        val results = mutableListOf<Pair<Long, Bitmap>>()

        for (timestampMs in timestampsMs) {
            if (Thread.currentThread().isInterrupted) break

            val bitmap = retriever.getFrameAtTime(
                timestampMs * 1000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: continue

            results.add(Pair(timestampMs, bitmap))
        }

        return results
    }
}