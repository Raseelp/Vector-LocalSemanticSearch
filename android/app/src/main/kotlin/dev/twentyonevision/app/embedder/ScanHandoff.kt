package dev.twentyonevision.app.embedder

/**
 * Where the indexing scan hands over the photos it has just written to the index,
 * for whoever wants to work on them straight away (the face scan, see FaceFollower).
 *
 * The call is synchronous on purpose: the indexing scan waits for it to return, so
 * the two never compete for the CPU - index a batch, find its faces at full speed,
 * then carry on indexing. Whatever the consumer doesn't get to is found later by the
 * face worker's normal comparison of the index against what it has already done.
 */
object ScanHandoff {

    fun interface Consumer {
        /** [shouldStop] turns true if the indexing scan is cancelled while this is working. */
        fun onIndexed(photos: List<IndexedImage>, shouldStop: () -> Boolean)
    }

    @Volatile
    var consumer: Consumer? = null
}
