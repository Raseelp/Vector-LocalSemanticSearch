package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import dev.twentyonevision.app.embedder.VideoFrameExtractor
import kotlin.math.max

/**
 * Frames of one video for finding faces: open once, then ask for as many moments as
 * needed. Decoding goes through the same lock the indexing scan and the thumbnail loader
 * use (a phone only has a few video decoders), one frame at a time, so this never holds
 * the decoder for long.
 */
class VideoFrameReader private constructor(
    private val retriever: MediaMetadataRetriever,
    val durationMs: Long,
    private val width: Int,
    private val height: Int,
    private val maxSide: Int,
) : AutoCloseable {

    /** One frame, upright, at most [MAX_SIDE] across; null if it could not be read. */
    fun frameAt(tsMs: Long, exact: Boolean = false): Bitmap? = synchronized(VideoFrameExtractor.decodeLock) {
        try {
            val option = if (exact) MediaMetadataRetriever.OPTION_CLOSEST else MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            val us = tsMs.coerceAtLeast(0L) * 1000L
            val long = max(width, height)
            val frame = if (Build.VERSION.SDK_INT >= 27 && width > 0 && height > 0 && long > maxSide) {
                val scale = maxSide.toFloat() / long
                retriever.getScaledFrameAtTime(us, option, (width * scale).toInt().coerceAtLeast(1), (height * scale).toInt().coerceAtLeast(1))
            } else {
                retriever.getFrameAtTime(us, option)
            }
            frame?.let { shrink(it) }
        } catch (e: Exception) {
            null
        } catch (e: OutOfMemoryError) {
            null
        }
    }

    // Older phones can only give the full frame: make it a sensible size.
    private fun shrink(frame: Bitmap): Bitmap {
        val long = max(frame.width, frame.height)
        if (long <= maxSide) return frame
        val scale = maxSide.toFloat() / long
        val small = Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt().coerceAtLeast(1), (frame.height * scale).toInt().coerceAtLeast(1), true)
        if (small !== frame) frame.recycle()
        return small
    }

    override fun close() {
        synchronized(VideoFrameExtractor.decodeLock) {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    companion object {
        /** Frames are read at most this many pixels across (faces are found at 640 anyway). */
        const val MAX_SIDE = 1600

        /** Null if the video can't be opened (yet: the decoder may just be busy). */
        fun open(context: Context, uri: Uri, maxSide: Int = MAX_SIDE): VideoFrameReader? = synchronized(VideoFrameExtractor.decodeLock) {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, uri)
                val duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                var w = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                var h = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                // Frames come out upright, so the size we ask for is the rotated one.
                if (rotation == 90 || rotation == 270) {
                    val t = w
                    w = h
                    h = t
                }
                if (duration <= 0L) {
                    retriever.release()
                    null
                } else {
                    VideoFrameReader(retriever, duration, w, h, maxSide)
                }
            } catch (e: Exception) {
                try {
                    retriever.release()
                } catch (_: Exception) {
                }
                null
            }
        }
    }
}
