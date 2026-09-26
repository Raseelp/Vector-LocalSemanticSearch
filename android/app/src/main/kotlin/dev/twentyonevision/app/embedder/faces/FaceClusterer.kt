package dev.twentyonevision.app.embedder.faces

import android.content.Context
import android.util.Log
import kotlin.math.sqrt

/**
 * How strict grouping is. A face joins a person when it is at least [join]
 * similar to that person's average face; two people are merged when their
 * averages are [merge] similar, or (for the same person seen in two different
 * conditions, whose averages are far apart) when several individual faces of
 * one match several of the other at [link] or better. Weak faces need
 * [weakJoin]. Stricter means fewer wrong merges but more people split in two.
 */
class FaceClusterConfig(val join: Float, val weakJoin: Float, val merge: Float, val link: Float) {
    companion object {
        const val STRICT = "strict"
        const val BALANCED = "balanced"
        const val LOOSE = "loose"

        fun forStrictness(name: String?): FaceClusterConfig = when (name) {
            STRICT -> FaceClusterConfig(join = 0.50f, weakJoin = 0.56f, merge = 0.62f, link = 0.60f)
            LOOSE -> FaceClusterConfig(join = 0.36f, weakJoin = 0.42f, merge = 0.48f, link = 0.46f)
            else -> FaceClusterConfig(join = 0.42f, weakJoin = 0.48f, merge = 0.54f, link = 0.52f)
        }
    }
}

/**
 * Groups faces into people, and applies the user's corrections.
 *
 * Two ideas keep it sane:
 *  - A person is represented by the average (centroid) of their good faces;
 *    a new face joins the closest person if it is similar enough, else starts
 *    a new one. That makes it incremental - new photos just slot in.
 *  - Two faces in the same photo are never the same person, and a face the
 *    user rejected from someone never goes back to them.
 *
 * Anything the user named, merged or edited is "pinned": automatic regrouping
 * leaves those people (and hand-moved faces) exactly as they are.
 */
class FaceClusterer(private val context: Context, private val store: FaceStore) {

    // One of a person's best faces, kept to compare people face-to-face.
    private class Exemplar(val rank: Float, val vector: FloatArray)

    // One "look" of a person: a group of their faces that resemble each other
    // (with and without glasses, in sun and in shade, years apart). A person is
    // one or more of these, and a new face belongs to them if it matches ANY look.
    // That is what makes a merge stick: when two groups are joined as one person,
    // both looks are kept, so later faces of either kind find their way to that
    // person instead of starting a new group. (One average of everyone would sit
    // between the two looks and match neither well.)
    private class Proto(first: FloatArray) {
        val sum = first.copyOf()
        val centroid = first.copyOf()
        var count = 1

        fun add(e: FloatArray) {
            for (i in sum.indices) sum[i] += e[i]
            count++
            refresh()
        }

        fun absorb(other: Proto) {
            for (i in sum.indices) sum[i] += other.sum[i]
            count += other.count
            refresh()
        }

        fun copy(): Proto {
            val c = Proto(centroid)
            for (i in sum.indices) c.sum[i] = sum[i]
            c.count = count
            c.refresh()
            return c
        }

        private fun refresh() {
            var norm = 0.0
            for (v in sum) norm += v * v
            val n = sqrt(norm).toFloat()
            for (i in sum.indices) centroid[i] = if (n > 0f) sum[i] / n else 0f
        }
    }

    // Vector length is whatever the recognition model outputs, so the arrays
    // are sized by the first face added.
    private class PersonState(val id: Long, var pinned: Boolean, var named: Boolean) {
        var sum = FloatArray(0)
        var centroid = FloatArray(0)
        var count = 0
        val photos = HashSet<Long>()
        val protos = ArrayList<Proto>()

        // The best few faces (from the second face on: with just one, the
        // average IS that face). Two people who are really one - seen in
        // different light, with and without glasses - have averages that are far
        // apart but still have individual faces that match each other.
        private val exemplars = ArrayList<Exemplar>()
        private var firstRank = 0f

        fun add(e: FloatArray, rank: Float = 0f, join: Float = 0.42f) {
            if (sum.isEmpty()) {
                sum = FloatArray(e.size)
                centroid = FloatArray(e.size)
            }
            if (e.size != sum.size) return
            if (count == 0) firstRank = rank
            else if (exemplars.isEmpty()) exemplars += Exemplar(firstRank, centroid.copyOf())
            for (i in sum.indices) sum[i] += e[i]
            count++
            refresh()
            keep(Exemplar(rank, e))

            // Into the look it resembles (if it resembles one closely enough), else a new look.
            var best = -1
            var bestSim = -2f
            for (i in protos.indices) {
                val sim = dotProduct(e, protos[i].centroid)
                if (sim > bestSim) {
                    bestSim = sim
                    best = i
                }
            }
            if (best >= 0 && bestSim >= join) protos[best].add(e) else protos += Proto(e)
            capProtos()
        }

        fun absorb(other: PersonState) {
            photos.addAll(other.photos)
            if (other.count == 0) return
            if (sum.isEmpty()) {
                sum = FloatArray(other.sum.size)
                centroid = FloatArray(other.sum.size)
            }
            if (other.sum.size != sum.size) return
            if (count == 1 && exemplars.isEmpty()) exemplars += Exemplar(firstRank, centroid.copyOf())
            val theirs = other.faceVectors()
            for (i in sum.indices) sum[i] += other.sum[i]
            count += other.count
            refresh()
            for (x in theirs) keep(x)

            // Both people's looks are kept.
            for (p in other.protos) protos += p.copy()
            capProtos()
        }

        /** How well [e] matches this person: its closest look. */
        fun bestSimTo(e: FloatArray): Float {
            var best = -1f
            for (p in protos) {
                if (p.centroid.size != e.size) continue
                val sim = dotProduct(e, p.centroid)
                if (sim > best) best = sim
            }
            return best
        }

        // A handful of looks is plenty; past that, the two most alike become one.
        private fun capProtos() {
            while (protos.size > MAX_PROTOS) {
                var bi = 0
                var bj = 1
                var bestSim = -2f
                for (i in protos.indices) {
                    for (j in i + 1 until protos.size) {
                        val sim = dotProduct(protos[i].centroid, protos[j].centroid)
                        if (sim > bestSim) {
                            bestSim = sim
                            bi = i
                            bj = j
                        }
                    }
                }
                protos[bi].absorb(protos[bj])
                protos.removeAt(bj)
            }
        }

        fun refresh() {
            var norm = 0.0
            for (v in sum) norm += v * v
            val n = sqrt(norm).toFloat()
            for (i in sum.indices) centroid[i] = if (n > 0f) sum[i] / n else 0f
        }

        /** The stored best faces, or the average when there is only one face. */
        fun faceVectors(): List<Exemplar> =
            if (exemplars.isNotEmpty()) exemplars else if (count > 0) listOf(Exemplar(firstRank, centroid.copyOf())) else emptyList()

        private fun keep(x: Exemplar) {
            if (count < 2) return
            exemplars += x
            exemplars.sortByDescending { it.rank }
            while (exemplars.size > EXEMPLARS) exemplars.removeAt(exemplars.size - 1)
        }
    }

    // How two people compare: their closest looks, and their individual faces.
    private class Link(val centroid: Float, val best: Float, val top3: Float, val pairs: Int)

    // How alike two people's closest looks are.
    private fun protoSim(a: PersonState, b: PersonState): Float {
        var best = -1f
        for (x in a.protos) {
            for (y in b.protos) {
                if (x.centroid.size != y.centroid.size) continue
                val sim = dotProduct(x.centroid, y.centroid)
                if (sim > best) best = sim
            }
        }
        return best
    }

    private fun link(a: PersonState, b: PersonState): Link? {
        if (a.count == 0 || b.count == 0 || a.centroid.size != b.centroid.size) return null
        val centroid = protoSim(a, b)
        val top = FloatArray(3) { -1f }
        var pairs = 0
        for (x in a.faceVectors()) {
            for (y in b.faceVectors()) {
                if (x.vector.size != y.vector.size) continue
                val sim = dotProduct(x.vector, y.vector)
                pairs++
                // keep the three best, largest first
                if (sim > top[0]) { top[2] = top[1]; top[1] = top[0]; top[0] = sim }
                else if (sim > top[1]) { top[2] = top[1]; top[1] = sim }
                else if (sim > top[2]) { top[2] = sim }
            }
        }
        val used = top.count { it > -1f }
        if (used == 0) return null
        return Link(centroid, top[0], top.filter { it > -1f }.sum() / used, pairs)
    }

    private val lock = Any()
    private var people: HashMap<Long, PersonState>? = null

    // photo -> people who already have a face in it (a person can't appear twice).
    private val photoPeople = HashMap<Long, HashSet<Long>>()

    private val config: FaceClusterConfig
        get() = FaceClusterConfig.forStrictness(store.getMeta(META_STRICTNESS))

    fun strictness(): String = store.getMeta(META_STRICTNESS) ?: FaceClusterConfig.BALANCED

    fun setStrictness(value: String) = store.setMeta(META_STRICTNESS, value)

    /** Drops the in-memory state; it is rebuilt from the database on next use. */
    fun invalidate() = synchronized(lock) {
        people = null
        photoPeople.clear()
    }

    private fun state(): HashMap<Long, PersonState> {
        people?.let { return it }
        val join = config.join
        val map = HashMap<Long, PersonState>()
        for (p in store.allPeople()) map[p.id] = PersonState(p.id, p.pinned, p.name != null)
        photoPeople.clear()
        store.forEachFace("person_id IS NOT NULL") { f ->
            val personId = f.personId ?: return@forEachFace
            val person = map[personId] ?: return@forEachFace
            person.photos.add(f.photoHash)
            photoPeople.getOrPut(f.photoHash) { HashSet() }.add(person.id)
            if (f.good) person.add(f.embedding, f.rank, join)
        }
        people = map
        return map
    }

    // ---- assigning new faces ----

    /** Places the faces of one just-processed photo, best first, creating people as needed. */
    fun assignPhotoFaces(photoHash: Long, ids: List<Long>, rows: List<FaceRow>) = synchronized(lock) {
        val state = state()
        val cfg = config
        val order = ids.indices.sortedByDescending { rows[it].rank }

        for (i in order) {
            val row = rows[i]
            // Found but not recognised yet (an empty vector): it is placed in pass 2.
            if (row.embedding.isEmpty()) continue
            place(state, cfg, photoHash, ids[i], row.embedding, row.good, row.rank)
        }
    }

    /**
     * Places one face that was stored without a vector and has now been recognised in
     * full (a photo opened in the viewer): like a face of a new photo - it joins a person,
     * or, if it is clear, starts one.
     */
    fun assignRecognised(faceId: Long, photoHash: Long, embedding: FloatArray, good: Boolean, rank: Float) =
        synchronized(lock) { place(state(), config, photoHash, faceId, embedding, good, rank) }

    private fun place(
        state: HashMap<Long, PersonState>,
        cfg: FaceClusterConfig,
        photoHash: Long,
        faceId: Long,
        embedding: FloatArray,
        good: Boolean,
        rank: Float,
    ) {
        val best = closest(listOf(state.values), embedding, photoHash, blocked = null, threshold = if (good) cfg.join else cfg.weakJoin)

        if (best != null) {
            store.setFacePerson(faceId, best.id)
            if (good) best.add(embedding, rank, cfg.join)
            best.photos.add(photoHash)
            photoPeople.getOrPut(photoHash) { HashSet() }.add(best.id)
        } else if (good) {
            val id = store.createPerson()
            val person = PersonState(id, pinned = false, named = false)
            person.add(embedding, rank, cfg.join)
            person.photos.add(photoHash)
            state[id] = person
            store.setFacePerson(faceId, id)
            photoPeople.getOrPut(photoHash) { HashSet() }.add(id)
        }
        // A weak face nobody matches stays unassigned.
    }

    /**
     * Places a face that was stored earlier without a vector and has just been
     * recognised: it joins a person if it is similar enough, but as a weak face
     * it never starts one or shifts anyone's average.
     */
    fun assignExisting(faceId: Long, photoHash: Long, embedding: FloatArray) = synchronized(lock) {
        val state = state()
        val best = closest(listOf(state.values), embedding, photoHash, blocked = null, threshold = config.weakJoin)
            ?: return@synchronized
        store.setFacePerson(faceId, best.id)
        best.photos.add(photoHash)
        photoPeople.getOrPut(photoHash) { HashSet() }.add(best.id)
    }

    // The most similar person at or above the threshold, skipping anyone who
    // already has a face in this photo and the one this face was rejected from.
    private fun closest(
        pools: List<Collection<PersonState>>,
        embedding: FloatArray,
        photoHash: Long,
        blocked: Long?,
        threshold: Float,
    ): PersonState? {
        val taken = photoPeople[photoHash]
        var best: PersonState? = null
        var bestSim = threshold
        for (pool in pools) {
            for (person in pool) {
                if (person.count == 0) continue
                if (person.id == blocked || (taken != null && person.id in taken)) continue
                val sim = person.bestSimTo(embedding)
                if (sim >= bestSim) {
                    bestSim = sim
                    best = person
                }
            }
        }
        return best
    }

    // ---- merging look-alike people ----

    /**
     * Joins people who are very likely one (the same person split by early
     * greedy choices): their averages are close, or several faces of one match
     * several faces of the other. Never merges a pair that shares a photo (two
     * faces in one photo are two people), a pair the user said is not the same
     * person, or two people the user has named.
     */
    fun mergeSimilar() = synchronized(lock) {
        val state = state()
        val cfg = config
        val rejected = store.rejectedPairs()
        val ordered = state.values.filter { it.count > 0 }.sortedByDescending { it.count }.toMutableList()
        val removed = HashSet<Long>()

        for (i in ordered.indices) {
            val a = ordered[i]
            if (a.id in removed) continue
            // Sorted biggest first: from here on everyone is a single face, and
            // two loners were already compared when the second one arrived (they
            // didn't match then, and their averages haven't changed since).
            if (a.count <= 1) break
            for (j in i + 1 until ordered.size) {
                val b = ordered[j]
                if (b.id in removed) continue
                if (a.pinned && b.pinned) continue
                if (a.named && b.named) continue
                if (a.centroid.size != b.centroid.size) continue
                if ((minOf(a.id, b.id) to maxOf(a.id, b.id)) in rejected) continue

                // Cheap first: unrelated people are nowhere near each other.
                val centroidSim = protoSim(a, b)
                if (centroidSim < PREFILTER) continue
                if (sharesPhoto(a, b)) continue

                val strong = centroidSim >= cfg.merge || run {
                    val l = link(a, b)
                    l != null && l.pairs >= 3 && l.top3 >= cfg.link
                }
                if (!strong) continue

                // The named / pinned one survives.
                val (keep, drop) = if (b.named || (b.pinned && !a.named)) b to a else a to b
                Log.d(TAG, "merge person ${drop.id} into ${keep.id} (centroids $centroidSim)")
                store.mergeInto(drop.id, keep.id)
                keep.absorb(drop)
                for (photo in drop.photos) {
                    photoPeople[photo]?.let { it.remove(drop.id); it.add(keep.id) }
                }
                removed.add(drop.id)
                state.remove(drop.id)
                if (drop === a) break // a is gone; move on to the next anchor
            }
        }
    }

    // ---- suggestions ----

    class MergeSuggestion(val aId: Long, val bId: Long, val score: Float)

    /**
     * Pairs of listed people who may be the same person, most likely first -
     * the ones automatic merging wasn't sure enough about. The user decides.
     * Pairs already said to be different, hidden people, and pairs sharing a
     * photo are left out.
     */
    fun suggestMerges(limit: Int): List<MergeSuggestion> = synchronized(lock) {
        val state = state()
        val rejected = store.rejectedPairs()
        val hidden = store.allPeople().filter { it.hidden }.map { it.id }.toSet()
        val listed = state.values.filter {
            it.count > 0 && it.photos.size >= FaceStore.MIN_PHOTOS_TO_SHOW && it.id !in hidden
        }

        val out = ArrayList<MergeSuggestion>()
        for (i in listed.indices) {
            val a = listed[i]
            for (j in i + 1 until listed.size) {
                val b = listed[j]
                if (a.named && b.named) continue // the user already told these apart
                if (a.centroid.size != b.centroid.size) continue
                if ((minOf(a.id, b.id) to maxOf(a.id, b.id)) in rejected) continue
                if (protoSim(a, b) < PREFILTER) continue
                if (sharesPhoto(a, b)) continue

                // Both must hold: several faces of one match several of the other
                // (not a lone lucky pair - look-alikes, and drawings or cartoons,
                // produce those), and the closest pair is clearly alike.
                val l = link(a, b) ?: continue
                if (l.pairs < 3 || l.top3 < SUGGEST_TOP3 || l.best < SUGGEST_BEST) continue
                out += MergeSuggestion(a.id, b.id, l.top3)
            }
        }
        out.sortByDescending { it.score }
        out.take(limit)
    }

    /** "Not the same person": never suggested or merged automatically again. */
    fun rejectMerge(a: Long, b: Long) = synchronized(lock) {
        store.rejectMerge(a, b)
    }

    /**
     * Joins [otherId] into [keepId] (the name and pin carry over). Remembers what
     * it moved so the merge can be undone; returns that record's id (0 if nothing
     * was merged).
     */
    fun merge(keepId: Long, otherId: Long): Long = synchronized(lock) {
        if (keepId == otherId) return@synchronized 0L
        val keep = store.person(keepId) ?: return@synchronized 0L
        val other = store.person(otherId) ?: return@synchronized 0L

        // Written down before anything moves.
        val movedFaces = store.faceIdsOf(otherId)
        val recordId = store.logMerge(
            keptId = keepId, keptName = keep.name, keptCover = store.bestFaceOf(keepId),
            removedName = other.name, removedCover = store.bestFaceOf(otherId),
            removedPinned = other.pinned, removedHidden = other.hidden,
            faceIds = movedFaces,
        )

        store.mergeInto(otherId, keepId)
        if (keep.name == null && other.name != null) store.rename(keepId, other.name)
        store.setPinned(keepId)
        if (keep.hidden) store.setHidden(keepId, true)
        invalidate()
        recordId
    }

    // ---- splitting one person into two ----

    class SplitPreview(
        val first: List<Long>,
        val second: List<Long>,
        val firstCovers: List<Long>,
        val secondCovers: List<Long>,
    )

    private class SplitFace(val id: Long, val e: FloatArray, val good: Boolean, val rank: Float)

    /**
     * For a person who is really two (merged by mistake, or grouped wrongly): finds
     * the two groups their faces fall into, so the user can look at them and split.
     * Two-means on the clear faces, seeded with the clearest face and the face least
     * like it; the rest of the faces join whichever group they are closer to.
     * Null when there are too few clear faces to tell.
     */
    fun previewSplit(personId: Long): SplitPreview? = synchronized(lock) {
        val faces = ArrayList<SplitFace>()
        store.forEachFace("person_id = $personId") { faces += SplitFace(it.id, it.embedding, it.good, it.rank) }
        val clear = faces.filter { it.good }
        if (clear.size < 4) return@synchronized null

        // Two-means from a few different starting pairs, keeping the best split. One
        // pair is not enough: seeded from a stray odd face, it can end up with a group
        // of one. Seeds: the clearest face against the one least like it, and then
        // two more chosen by walking away from those.
        fun farthest(from: FloatArray): FloatArray = clear.minByOrNull { dotProduct(it.e, from) }!!.e
        val top = clear.first().e
        val far1 = farthest(top)
        val far2 = farthest(far1)
        val seeds = listOf(top to far1, far1 to far2, far2 to farthest(far2))

        var a = FloatArray(0)
        var b = FloatArray(0)
        var bestScore = -1f
        for ((seedA, seedB) in seeds) {
            var ca = seedA.copyOf()
            var cb = seedB.copyOf()
            var countA = 0
            var countB = 0
            for (iteration in 0 until 15) {
                val sumA = FloatArray(ca.size)
                val sumB = FloatArray(ca.size)
                countA = 0
                countB = 0
                for (f in clear) {
                    val toA = dotProduct(f.e, ca) >= dotProduct(f.e, cb)
                    val target = if (toA) sumA else sumB
                    for (k in target.indices) target[k] += f.e[k]
                    if (toA) countA++ else countB++
                }
                if (countA == 0 || countB == 0) break
                val na = normalised(sumA)
                val nb = normalised(sumB)
                val moved = dotProduct(na, ca) < 0.9999f || dotProduct(nb, cb) < 0.9999f
                ca = na
                cb = nb
                if (!moved) break
            }
            if (countA == 0 || countB == 0) continue

            // How tightly the faces sit around their group's centre, and the smaller
            // group's share: a lopsided split (one stray face against everyone) is no split.
            var fit = 0f
            for (f in clear) fit += maxOf(dotProduct(f.e, ca), dotProduct(f.e, cb))
            val share = minOf(countA, countB).toFloat() / clear.size
            val score = if (share >= SPLIT_MIN_SHARE) fit / clear.size + 1f else fit / clear.size
            if (score > bestScore) {
                bestScore = score
                a = ca
                b = cb
            }
        }
        if (a.isEmpty()) return@synchronized null

        val first = ArrayList<SplitFace>()
        val second = ArrayList<SplitFace>()
        // Every face (weak ones too) goes with the group it is nearer to.
        for (f in faces) {
            if (f.e.size != a.size) continue
            if (dotProduct(f.e, a) >= dotProduct(f.e, b)) first += f else second += f
        }
        if (first.isEmpty() || second.isEmpty()) return@synchronized null

        // The bigger group first: it is the one that stays with the person.
        val (big, small) = if (first.size >= second.size) first to second else second to first
        fun covers(list: List<SplitFace>) = list.sortedWith(compareByDescending<SplitFace> { it.good }.thenByDescending { it.rank })
            .take(SPLIT_SAMPLE).map { it.id }
        SplitPreview(big.map { it.id }, small.map { it.id }, covers(big), covers(small))
    }

    private fun normalised(v: FloatArray): FloatArray {
        var norm = 0.0
        for (x in v) norm += x * x
        val n = sqrt(norm).toFloat()
        return FloatArray(v.size) { if (n > 0f) v[it] / n else 0f }
    }

    /**
     * Moves [faceIds] out of [personId] into a new person. The two are marked "not
     * the same person" so they are not suggested or merged again; both are kept as
     * the user's own (regrouping leaves them alone). Returns the new person's id.
     */
    fun splitPerson(personId: Long, faceIds: List<Long>): Long = synchronized(lock) {
        val newId = store.createPerson(pinned = true)
        store.moveFaces(faceIds, personId, newId)
        store.setPinned(personId)
        store.rejectMerge(newId, personId)
        store.pruneEmptyPeople()
        invalidate()
        newId
    }

    /**
     * Undoes a merge: the person it removed comes back with their name and the
     * faces that were theirs, and the two are marked "not the same person" so
     * neither the suggestions nor automatic merging join them again.
     */
    fun undoMerge(recordId: Long): Boolean = synchronized(lock) {
        val record = store.mergeRecord(recordId) ?: return@synchronized false
        val restored = store.restorePerson(record)

        val kept = store.person(record.keptId)
        if (kept != null) {
            store.rejectMerge(restored, record.keptId)
            // The kept person may have taken the other one's name in the merge: give it back.
            if (record.keptName == null && kept.name != null && kept.name == record.removedName) {
                store.rename(record.keptId, null)
            }
        }
        store.deleteMergeRecord(recordId)
        store.pruneEmptyPeople()
        invalidate()
        true
    }

    private fun sharesPhoto(a: PersonState, b: PersonState): Boolean {
        val (small, big) = if (a.photos.size <= b.photos.size) a.photos to b.photos else b.photos to a.photos
        return small.any { it in big }
    }

    // ---- regrouping everything ----

    /**
     * Rebuilds the automatic groups from scratch with the current strictness.
     * Best faces go first so they seed the people; pinned people and
     * hand-placed faces are left as they are and can still take faces in.
     */
    fun regroup() = synchronized(lock) {
        store.dissolveUnpinnedPeople()
        invalidate()

        val cfg = config
        val state = state()
        val assignments = ArrayList<Pair<Long, Long>>()
        val provisional = HashMap<Long, PersonState>() // negative temp ids
        var nextTemp = -1L

        // Good faces first, best rank first (forEachFace orders by rank).
        store.forEachFace("person_id IS NULL AND locked = 0 AND good = 1") { f ->
            val best = closest(listOf(state.values, provisional.values), f.embedding, f.photoHash, f.blockedPerson, cfg.join)
            val target = best ?: PersonState(nextTemp--, pinned = false, named = false).also { provisional[it.id] = it }
            target.add(f.embedding, f.rank, cfg.join)
            target.photos.add(f.photoHash)
            photoPeople.getOrPut(f.photoHash) { HashSet() }.add(target.id)
            assignments += f.id to target.id
        }

        // Turn temp ids into real people, then write every assignment.
        val realIds = HashMap<Long, Long>()
        for (temp in provisional.keys) realIds[temp] = store.createPerson()
        store.applyAssignments(assignments.map { (face, person) -> face to (realIds[person] ?: person) })
        invalidate()

        // Weak faces: only join people the good faces built.
        val weakState = state()
        val weak = ArrayList<Pair<Long, Long>>()
        store.forEachFace("person_id IS NULL AND locked = 0 AND good = 0") { f ->
            val best = closest(listOf(weakState.values), f.embedding, f.photoHash, f.blockedPerson, cfg.weakJoin)
            if (best != null) {
                weak += f.id to best.id
                photoPeople.getOrPut(f.photoHash) { HashSet() }.add(best.id)
            }
        }
        store.applyAssignments(weak)
        invalidate()

        mergeSimilar()
    }

    // ---- the user's corrections ----

    fun rename(personId: Long, name: String?) = synchronized(lock) {
        store.rename(personId, name)
        invalidate()
    }

    fun setHidden(personId: Long, hidden: Boolean) = synchronized(lock) {
        store.setHidden(personId, hidden)
        invalidate()
    }

    /**
     * "Not this person": takes a face out of its person for good. If it clearly
     * matches someone else it goes to them, otherwise it is left unassigned.
     */
    fun removeFace(faceId: Long) = synchronized(lock) {
        val face = store.face(faceId) ?: return@synchronized
        val from = face.personId
        store.lockFace(faceId, personId = null, blockedPerson = from)
        invalidate()

        val state = state()
        val other = closest(listOf(state.values), face.embedding, face.photoHash, blocked = from, threshold = config.join)
        if (other != null && face.good) {
            store.lockFace(faceId, personId = other.id, blockedPerson = null)
            store.setPinned(other.id)
        }
        invalidate()
        // The old person may now be empty.
        store.pruneEmptyPeople()
    }

    companion object {
        private const val TAG = "FaceClusterer"
        const val META_STRICTNESS = "strictness"

        // Best faces kept per person for face-to-face comparison.
        private const val EXEMPLARS = 10

        // Averages this far apart or less are unrelated people: skip the finer comparison.
        private const val PREFILTER = 0.26f

        // A pair is suggested only when their three best matching faces average at least
        // SUGGEST_TOP3 and the single best pair is at least SUGGEST_BEST. Measured on a
        // few thousand of real photos (338 people): the old rule (one good pair, or
        // similar averages) suggested about 90 pairs, most of them different people;
        // 0.40 / 0.42 suggested 5, all likely the same person but too few to be useful;
        // this in between gives about 15 - a review list worth opening, with the odd
        // wrong one that "Different" removes for good.
        private const val SUGGEST_TOP3 = 0.36f
        private const val SUGGEST_BEST = 0.39f

        // Looks kept per person.
        private const val MAX_PROTOS = 6

        // Faces shown per group when previewing a split.
        private const val SPLIT_SAMPLE = 8

        // The smaller group should hold at least this share of the clear faces for the
        // split to count as real rather than one stray face against everyone else.
        private const val SPLIT_MIN_SHARE = 0.1f
    }
}

private fun dotProduct(a: FloatArray, b: FloatArray): Float {
    var d = 0f
    for (i in a.indices) d += a[i] * b[i]
    return d
}
