package dev.twentyonevision.app.embedder.faces

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** A face about to be stored (coordinates are 0..1 fractions of the upright photo). */
class FaceRow(
    val boxL: Float,
    val boxT: Float,
    val boxR: Float,
    val boxB: Float,
    val landmarks: FloatArray,
    val score: Float,
    val sizePx: Int,
    val sharpness: Float,
    val yaw: Float,
    val good: Boolean,
    val rank: Float,
    val embedding: FloatArray,
)

/** A stored face as the grouping logic needs it. */
class StoredFace(
    val id: Long,
    val photoHash: Long,
    val embedding: FloatArray,
    val good: Boolean,
    val rank: Float,
    val personId: Long?,
    val locked: Boolean,
    val blockedPerson: Long?,
)

class PersonInfo(
    val id: Long,
    val name: String?,
    val hidden: Boolean,
    val pinned: Boolean,
)

class PersonSummary(
    val id: Long,
    val name: String?,
    val hidden: Boolean,
    val faceCount: Int,
    val photoCount: Int,
    val coverFaceId: Long,
)

class FaceLocation(
    val faceId: Long,
    val photoUri: String,
    val boxL: Float,
    val boxT: Float,
    val boxR: Float,
    val boxB: Float,
    val good: Boolean,
    val personId: Long?,
    // The photo's size at the scale face boxes were measured (0 if unknown).
    val photoW: Int,
    val photoH: Int,
)

/**
 * All face data lives here, in its own database, owned by native code (the
 * scan writes thousands of rows; going through Flutter for that would be
 * slow). Flutter only ever reads summaries and asks for edits through the
 * method channel.
 *
 *  - photos: which photos have been searched for faces (so a scan resumes
 *    and never repeats work), keyed by the photo's content hash
 *  - faces:  every face found, with its identity vector and quality
 *  - people: the groups; a person is "pinned" once the user named or
 *    edited it, which stops automatic regrouping from touching it
 */
class FaceStore(context: Context) : SQLiteOpenHelper(context.applicationContext, "faces.db", null, 5) {

    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)
        db.enableWriteAheadLogging()
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        db.execSQL(
            """CREATE TABLE photos (
                hash INTEGER PRIMARY KEY,
                uri TEXT NOT NULL,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                face_count INTEGER NOT NULL DEFAULT 0,
                processed_at INTEGER NOT NULL DEFAULT 0,
                complete INTEGER NOT NULL DEFAULT 0
            )"""
        )
        db.execSQL(
            """CREATE TABLE people (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT,
                hidden INTEGER NOT NULL DEFAULT 0,
                pinned INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL DEFAULT 0,
                cover_face_id INTEGER,
                cover_count INTEGER NOT NULL DEFAULT 0
            )"""
        )
        db.execSQL(
            """CREATE TABLE faces (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                photo_hash INTEGER NOT NULL,
                box_l REAL NOT NULL, box_t REAL NOT NULL, box_r REAL NOT NULL, box_b REAL NOT NULL,
                landmarks BLOB,
                score REAL NOT NULL,
                size_px INTEGER NOT NULL,
                sharpness REAL NOT NULL DEFAULT 0,
                yaw REAL NOT NULL DEFAULT 0,
                good INTEGER NOT NULL DEFAULT 0,
                rank REAL NOT NULL DEFAULT 0,
                embedding BLOB NOT NULL,
                person_id INTEGER,
                locked INTEGER NOT NULL DEFAULT 0,
                blocked_person INTEGER
            )"""
        )
        db.execSQL("CREATE INDEX faces_person ON faces(person_id)")
        db.execSQL("CREATE INDEX faces_photo ON faces(photo_hash)")
        createRejections(db)
        createMergeHistory(db)
    }

    // What each merge you made moved, so it can be undone (see FaceClusterer.merge).
    private fun createMergeHistory(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS merge_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kept_id INTEGER NOT NULL,
                kept_name TEXT,
                kept_cover INTEGER,
                removed_name TEXT,
                removed_cover INTEGER,
                removed_pinned INTEGER NOT NULL DEFAULT 0,
                removed_hidden INTEGER NOT NULL DEFAULT 0,
                face_ids TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )"""
        )
    }

    // Pairs of people the user said are NOT the same person (a < b), so they are
    // never suggested again and never merged automatically.
    private fun createRejections(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE IF NOT EXISTS merge_rejections (a INTEGER NOT NULL, b INTEGER NOT NULL, PRIMARY KEY (a, b))")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) createRejections(db)
        if (oldVersion < 4) createMergeHistory(db)
        // "Every face in this photo has been recognised" - so opening it needs no more work.
        if (oldVersion < 5) db.execSQL("ALTER TABLE photos ADD COLUMN complete INTEGER NOT NULL DEFAULT 0")
        if (oldVersion < 3) {
            // The face shown for a person, and how many faces they had when it was chosen.
            db.execSQL("ALTER TABLE people ADD COLUMN cover_face_id INTEGER")
            db.execSQL("ALTER TABLE people ADD COLUMN cover_count INTEGER NOT NULL DEFAULT 0")
        }
    }

    // ---- meta ----

    fun getMeta(key: String): String? = readableDatabase.rawQuery(
        "SELECT value FROM meta WHERE key = ?", arrayOf(key)
    ).use { if (it.moveToFirst()) it.getString(0) else null }

    fun setMeta(key: String, value: String) {
        writableDatabase.execSQL("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arrayOf(key, value))
    }

    // ---- photos and faces ----

    fun processedHashes(): HashSet<Long> {
        val out = HashSet<Long>()
        readableDatabase.rawQuery("SELECT hash FROM photos", null).use {
            while (it.moveToNext()) out.add(it.getLong(0))
        }
        return out
    }

    fun isPhotoComplete(hash: Long): Boolean = readableDatabase.rawQuery(
        "SELECT complete FROM photos WHERE hash = ?", arrayOf(hash.toString())
    ).use { it.moveToFirst() && it.getInt(0) == 1 }

    fun markPhotoComplete(hash: Long) {
        writableDatabase.execSQL("UPDATE photos SET complete = 1 WHERE hash = ?", arrayOf(hash))
    }

    fun hasPhoto(hash: Long): Boolean = readableDatabase.rawQuery(
        "SELECT 1 FROM photos WHERE hash = ?", arrayOf(hash.toString())
    ).use { it.moveToFirst() }

    fun hasPhotoUri(uri: String): Boolean = readableDatabase.rawQuery(
        "SELECT 1 FROM photos WHERE uri = ?", arrayOf(uri)
    ).use { it.moveToFirst() }

    /** Records a searched photo with its faces; returns the new face ids in order. */
    fun insertPhoto(hash: Long, uri: String, width: Int, height: Int, faces: List<FaceRow>): List<Long> {
        val db = writableDatabase
        val ids = ArrayList<Long>(faces.size)
        db.beginTransaction()
        try {
            db.execSQL(
                "INSERT OR REPLACE INTO photos(hash, uri, width, height, face_count, processed_at) VALUES (?,?,?,?,?,?)",
                arrayOf(hash, uri, width, height, faces.size, System.currentTimeMillis())
            )
            for (f in faces) {
                val values = ContentValues().apply {
                    put("photo_hash", hash)
                    put("box_l", f.boxL); put("box_t", f.boxT); put("box_r", f.boxR); put("box_b", f.boxB)
                    put("landmarks", floatsToBlob(f.landmarks))
                    put("score", f.score)
                    put("size_px", f.sizePx)
                    put("sharpness", f.sharpness)
                    put("yaw", f.yaw)
                    put("good", if (f.good) 1 else 0)
                    put("rank", f.rank)
                    put("embedding", floatsToBlob(f.embedding))
                }
                ids += db.insertOrThrow("faces", null, values)
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return ids
    }

    /** Forgets photos that are no longer in the search index, and people left empty. */
    fun purgeMissing(existing: Set<Long>): Boolean {
        val db = writableDatabase
        val stored = ArrayList<Long>()
        db.rawQuery("SELECT hash FROM photos", null).use { while (it.moveToNext()) stored.add(it.getLong(0)) }
        val gone = stored.filter { it !in existing }
        if (gone.isEmpty()) return false

        db.beginTransaction()
        try {
            for (chunk in gone.chunked(400)) {
                val marks = chunk.joinToString(",") { "?" }
                val args = chunk.map { it.toString() }.toTypedArray()
                db.execSQL("DELETE FROM faces WHERE photo_hash IN ($marks)", args)
                db.execSQL("DELETE FROM photos WHERE hash IN ($marks)", args)
            }
            pruneEmptyPeople(db)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return true
    }

    fun pruneEmptyPeople() = pruneEmptyPeople(writableDatabase)

    private fun pruneEmptyPeople(db: SQLiteDatabase) {
        db.execSQL("DELETE FROM people WHERE id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
    }

    fun wipeAll() {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL("DELETE FROM faces")
            db.execSQL("DELETE FROM photos")
            db.execSQL("DELETE FROM people")
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    // ---- people ----

    fun createPerson(pinned: Boolean = false, name: String? = null): Long {
        val values = ContentValues().apply {
            put("name", name)
            put("pinned", if (pinned) 1 else 0)
            put("created_at", System.currentTimeMillis())
        }
        return writableDatabase.insertOrThrow("people", null, values)
    }

    fun setFacePerson(faceId: Long, personId: Long?) {
        writableDatabase.execSQL("UPDATE faces SET person_id = ? WHERE id = ?", arrayOf(personId, faceId))
    }

    fun person(id: Long): PersonInfo? = readableDatabase.rawQuery(
        "SELECT id, name, hidden, pinned FROM people WHERE id = ?", arrayOf(id.toString())
    ).use {
        if (it.moveToFirst()) PersonInfo(it.getLong(0), it.getString(1), it.getInt(2) == 1, it.getInt(3) == 1) else null
    }

    fun allPeople(): List<PersonInfo> {
        val out = ArrayList<PersonInfo>()
        readableDatabase.rawQuery("SELECT id, name, hidden, pinned FROM people", null).use {
            while (it.moveToNext()) {
                out += PersonInfo(it.getLong(0), it.getString(1), it.getInt(2) == 1, it.getInt(3) == 1)
            }
        }
        return out
    }

    fun rename(id: Long, name: String?) {
        val clean = name?.trim()?.takeIf { it.isNotEmpty() }
        writableDatabase.execSQL(
            "UPDATE people SET name = ?, pinned = CASE WHEN ? IS NULL THEN pinned ELSE 1 END WHERE id = ?",
            arrayOf(clean, clean, id)
        )
    }

    fun setHidden(id: Long, hidden: Boolean) {
        writableDatabase.execSQL("UPDATE people SET hidden = ?, pinned = 1 WHERE id = ?", arrayOf(if (hidden) 1 else 0, id))
    }

    fun setPinned(id: Long) {
        writableDatabase.execSQL("UPDATE people SET pinned = 1 WHERE id = ?", arrayOf(id))
    }

    /** Moves every face of [from] into [into] and removes [from]. */
    fun mergeInto(from: Long, into: Long) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL("UPDATE faces SET person_id = ? WHERE person_id = ?", arrayOf(into, from))
            db.execSQL("DELETE FROM people WHERE id = ?", arrayOf(from))
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** Sets a face's person, or (null) takes it out of any person, and locks it against auto-moves. */
    fun lockFace(faceId: Long, personId: Long?, blockedPerson: Long?) {
        writableDatabase.execSQL(
            "UPDATE faces SET person_id = ?, locked = 1, blocked_person = COALESCE(?, blocked_person) WHERE id = ?",
            arrayOf(personId, blockedPerson, faceId)
        )
    }

    /** Unassigns every unlocked face of a person who was never named or edited, and deletes them. */
    fun dissolveUnpinnedPeople() {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL(
                "UPDATE faces SET person_id = NULL WHERE locked = 0 AND person_id IN (SELECT id FROM people WHERE pinned = 0)"
            )
            db.execSQL("DELETE FROM people WHERE pinned = 0")
            pruneEmptyPeople(db)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun applyAssignments(assignments: List<Pair<Long, Long>>) {
        if (assignments.isEmpty()) return
        val db = writableDatabase
        db.beginTransaction()
        try {
            for ((faceId, personId) in assignments) {
                db.execSQL("UPDATE faces SET person_id = ? WHERE id = ?", arrayOf(personId, faceId))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    // ---- streaming faces for grouping ----

    /** Streams faces matching [where] (best rank first) without holding them all in memory. */
    fun forEachFace(where: String, block: (StoredFace) -> Unit) {
        readableDatabase.rawQuery(
            "SELECT id, photo_hash, embedding, good, rank, person_id, locked, blocked_person " +
                "FROM faces WHERE ($where) AND length(embedding) > 0 ORDER BY rank DESC",
            null
        ).use { c ->
            while (c.moveToNext()) block(readFace(c))
        }
    }

    private fun readFace(c: Cursor) = StoredFace(
        id = c.getLong(0),
        photoHash = c.getLong(1),
        embedding = blobToFloats(c.getBlob(2)),
        good = c.getInt(3) == 1,
        rank = c.getFloat(4),
        personId = if (c.isNull(5)) null else c.getLong(5),
        locked = c.getInt(6) == 1,
        blockedPerson = if (c.isNull(7)) null else c.getLong(7),
    )

    fun face(id: Long): StoredFace? = readableDatabase.rawQuery(
        "SELECT id, photo_hash, embedding, good, rank, person_id, locked, blocked_person FROM faces WHERE id = ?",
        arrayOf(id.toString())
    ).use { if (it.moveToFirst()) readFace(it) else null }

    /** Moves the given faces from one person to another (faces not currently in [from] are left alone). */
    fun moveFaces(faceIds: List<Long>, from: Long, to: Long) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (chunk in faceIds.chunked(400)) {
                val marks = chunk.joinToString(",") { "?" }
                val args = (listOf<Any>(to, from) + chunk.map { it.toString() }).toTypedArray()
                db.execSQL("UPDATE faces SET person_id = ? WHERE person_id = ? AND id IN ($marks)", args)
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    // ---- merge history (for undo) ----

    class MergeRecord(
        val id: Long,
        val keptId: Long,
        val keptName: String?,
        val keptCover: Long?,
        val removedName: String?,
        val removedCover: Long?,
        val removedPinned: Boolean,
        val removedHidden: Boolean,
        val faceIds: List<Long>,
        val createdAt: Long,
    )

    fun faceIdsOf(personId: Long): List<Long> {
        val out = ArrayList<Long>()
        readableDatabase.rawQuery("SELECT id FROM faces WHERE person_id = ?", arrayOf(personId.toString())).use {
            while (it.moveToNext()) out += it.getLong(0)
        }
        return out
    }

    /** A person's clearest face (for showing who they are), or null. */
    fun bestFaceOf(personId: Long): Long? = readableDatabase.rawQuery(
        "SELECT id FROM faces WHERE person_id = ? AND length(embedding) > 0 ORDER BY good DESC, rank DESC LIMIT 1",
        arrayOf(personId.toString())
    ).use { if (it.moveToFirst()) it.getLong(0) else null }

    fun logMerge(
        keptId: Long, keptName: String?, keptCover: Long?,
        removedName: String?, removedCover: Long?, removedPinned: Boolean, removedHidden: Boolean,
        faceIds: List<Long>,
    ): Long {
        val values = ContentValues().apply {
            put("kept_id", keptId)
            put("kept_name", keptName)
            put("kept_cover", keptCover)
            put("removed_name", removedName)
            put("removed_cover", removedCover)
            put("removed_pinned", if (removedPinned) 1 else 0)
            put("removed_hidden", if (removedHidden) 1 else 0)
            put("face_ids", faceIds.joinToString(","))
            put("created_at", System.currentTimeMillis())
        }
        val id = writableDatabase.insertOrThrow("merge_history", null, values)
        // Only the recent ones are worth keeping.
        writableDatabase.execSQL(
            "DELETE FROM merge_history WHERE id NOT IN (SELECT id FROM merge_history ORDER BY id DESC LIMIT $MERGE_HISTORY_LIMIT)"
        )
        return id
    }

    private fun readMerge(c: Cursor) = MergeRecord(
        id = c.getLong(0), keptId = c.getLong(1), keptName = c.getString(2),
        keptCover = if (c.isNull(3)) null else c.getLong(3),
        removedName = c.getString(4), removedCover = if (c.isNull(5)) null else c.getLong(5),
        removedPinned = c.getInt(6) == 1, removedHidden = c.getInt(7) == 1,
        faceIds = c.getString(8).split(",").mapNotNull { it.toLongOrNull() },
        createdAt = c.getLong(9),
    )

    private val mergeColumns =
        "id, kept_id, kept_name, kept_cover, removed_name, removed_cover, removed_pinned, removed_hidden, face_ids, created_at"

    fun mergeHistory(): List<MergeRecord> {
        val out = ArrayList<MergeRecord>()
        readableDatabase.rawQuery("SELECT $mergeColumns FROM merge_history ORDER BY id DESC", null).use {
            while (it.moveToNext()) out += readMerge(it)
        }
        return out
    }

    fun mergeRecord(id: Long): MergeRecord? = readableDatabase.rawQuery(
        "SELECT $mergeColumns FROM merge_history WHERE id = ?", arrayOf(id.toString())
    ).use { if (it.moveToFirst()) readMerge(it) else null }

    fun deleteMergeRecord(id: Long) {
        writableDatabase.execSQL("DELETE FROM merge_history WHERE id = ?", arrayOf(id))
    }

    /**
     * Brings back the person a merge removed: a new person with the old name, and
     * the faces that were theirs and are still sitting in some person (a face you
     * later took out by hand stays where you put it). Returns the new person's id.
     */
    fun restorePerson(record: MergeRecord): Long {
        val db = writableDatabase
        var newId = 0L
        db.beginTransaction()
        try {
            newId = createPerson(pinned = true, name = record.removedName)
            if (record.removedHidden) db.execSQL("UPDATE people SET hidden = 1 WHERE id = ?", arrayOf(newId))
            for (chunk in record.faceIds.chunked(400)) {
                val marks = chunk.joinToString(",") { "?" }
                val args = (listOf<Any>(newId) + chunk.map { it.toString() }).toTypedArray()
                db.execSQL(
                    "UPDATE faces SET person_id = ? WHERE id IN ($marks) AND person_id IS NOT NULL AND locked = 0",
                    args
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return newId
    }

    // ---- "not the same person" answers ----

    fun rejectMerge(a: Long, b: Long) {
        writableDatabase.execSQL(
            "INSERT OR IGNORE INTO merge_rejections(a, b) VALUES (?, ?)",
            arrayOf(minOf(a, b), maxOf(a, b))
        )
    }

    /** Every rejected pair, as (smaller id, larger id). */
    fun rejectedPairs(): HashSet<Pair<Long, Long>> {
        val out = HashSet<Pair<Long, Long>>()
        readableDatabase.rawQuery("SELECT a, b FROM merge_rejections", null).use {
            while (it.moveToNext()) out.add(it.getLong(0) to it.getLong(1))
        }
        return out
    }

    // ---- faces stored without a vector (recognised later, see FaceScanner) ----
    //
    // A face found but not yet recognised has an empty vector. It is kept so the
    // photo counts as done and the face can be recognised in a later, lower
    // priority pass - clustering only ever looks at faces that have a vector.

    /** How many photos have faces still waiting to be recognised. */
    fun deferredPhotoCount(): Int = readableDatabase.rawQuery(
        "SELECT COUNT(DISTINCT photo_hash) FROM faces WHERE length(embedding) = 0", null
    ).use { it.moveToFirst(); it.getInt(0) }

    class DeferredPhoto(val hash: Long, val uri: String)

    class DeferredFace(
        val id: Long,
        val landmarks: FloatArray, // 0..1 fractions of the photo
        val sizePx: Int,
        val score: Float,
        val yaw: Float,
        val rank: Float,
    )

    fun deferredPhotos(limit: Int): List<DeferredPhoto> {
        val out = ArrayList<DeferredPhoto>()
        readableDatabase.rawQuery(
            """SELECT ph.hash, ph.uri FROM photos ph
               WHERE EXISTS (SELECT 1 FROM faces f WHERE f.photo_hash = ph.hash AND length(f.embedding) = 0)
               LIMIT ?""",
            arrayOf(limit.toString())
        ).use { while (it.moveToNext()) out += DeferredPhoto(it.getLong(0), it.getString(1)) }
        return out
    }

    fun deferredFaces(photoHash: Long): List<DeferredFace> {
        val out = ArrayList<DeferredFace>()
        readableDatabase.rawQuery(
            "SELECT id, landmarks, size_px, score, yaw, rank FROM faces WHERE photo_hash = ? AND length(embedding) = 0 ORDER BY rank DESC",
            arrayOf(photoHash.toString())
        ).use {
            while (it.moveToNext()) {
                out += DeferredFace(
                    it.getLong(0), blobToFloats(it.getBlob(1)), it.getInt(2),
                    it.getFloat(3), it.getFloat(4), it.getFloat(5),
                )
            }
        }
        return out
    }

    /** True while a face has been found but not recognised yet. */
    fun isDeferred(faceId: Long): Boolean = readableDatabase.rawQuery(
        "SELECT 1 FROM faces WHERE id = ? AND length(embedding) = 0", arrayOf(faceId.toString())
    ).use { it.moveToFirst() }

    fun photoHashForUri(uri: String): Long? = readableDatabase.rawQuery(
        "SELECT hash FROM photos WHERE uri = ?", arrayOf(uri)
    ).use { if (it.moveToFirst()) it.getLong(0) else null }

    /** A face recognised late: its vector, and whether it turned out clear enough to count. */
    fun setFaceRecognised(faceId: Long, embedding: FloatArray, sharpness: Float, good: Boolean) {
        writableDatabase.execSQL(
            "UPDATE faces SET embedding = ?, sharpness = ?, good = ? WHERE id = ?",
            arrayOf(floatsToBlob(embedding), sharpness, if (good) 1 else 0, faceId)
        )
    }

    fun setFaceEmbedding(faceId: Long, embedding: FloatArray, sharpness: Float) {
        writableDatabase.execSQL(
            "UPDATE faces SET embedding = ?, sharpness = ? WHERE id = ?",
            arrayOf(floatsToBlob(embedding), sharpness, faceId)
        )
    }

    fun deleteFaces(ids: List<Long>) {
        if (ids.isEmpty()) return
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (chunk in ids.chunked(400)) {
                val marks = chunk.joinToString(",") { "?" }
                db.execSQL("DELETE FROM faces WHERE id IN ($marks)", chunk.map { it.toString() }.toTypedArray())
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    // ---- what the UI reads ----

    fun stats(): Triple<Int, Int, Int> {
        val db = readableDatabase
        val photos = db.rawQuery("SELECT COUNT(*) FROM photos", null).use { it.moveToFirst(); it.getInt(0) }
        val faces = db.rawQuery("SELECT COUNT(*) FROM faces", null).use { it.moveToFirst(); it.getInt(0) }
        val people = db.rawQuery(
            "SELECT COUNT(*) FROM (SELECT person_id FROM faces WHERE person_id IS NOT NULL " +
                "GROUP BY person_id HAVING COUNT(DISTINCT photo_hash) >= $MIN_PHOTOS_TO_SHOW)",
            null
        ).use { it.moveToFirst(); it.getInt(0) }
        return Triple(photos, faces, people)
    }

    /**
     * People with at least [MIN_PHOTOS_TO_SHOW] photos (one-off faces are
     * mostly strangers in the background, so they stay out of the list), most
     * photographed first.
     */
    fun listPeople(hidden: Boolean): List<PersonSummary> {
        val rows = ArrayList<CoverRow>()
        readableDatabase.rawQuery(
            """SELECT p.id, p.name, p.hidden, COUNT(f.id), COUNT(DISTINCT f.photo_hash),
                      p.cover_face_id, p.cover_count,
                      (SELECT 1 FROM faces c WHERE c.id = p.cover_face_id AND c.person_id = p.id)
               FROM people p JOIN faces f ON f.person_id = p.id
               WHERE p.hidden = ?
               GROUP BY p.id
               HAVING COUNT(DISTINCT f.photo_hash) >= $MIN_PHOTOS_TO_SHOW
               ORDER BY COUNT(DISTINCT f.photo_hash) DESC, p.id ASC""",
            arrayOf(if (hidden) "1" else "0")
        ).use { while (it.moveToNext()) rows += readCoverRow(it) }
        // After the read cursor is closed: choosing a cover can write.
        return rows.map { it.toSummary() }
    }

    fun personSummary(id: Long): PersonSummary? {
        val row = readableDatabase.rawQuery(
            """SELECT p.id, p.name, p.hidden, COUNT(f.id), COUNT(DISTINCT f.photo_hash),
                      p.cover_face_id, p.cover_count,
                      (SELECT 1 FROM faces c WHERE c.id = p.cover_face_id AND c.person_id = p.id)
               FROM people p JOIN faces f ON f.person_id = p.id WHERE p.id = ? GROUP BY p.id""",
            arrayOf(id.toString())
        ).use { if (it.moveToFirst()) readCoverRow(it) else null }
        return row?.toSummary()
    }

    // ---- the face shown for a person ----
    //
    // The best face when a person first appears; after that it changes only
    // once a fair few new faces have been added (a sixth more, at least
    // COVER_MIN_NEW), to the newest of their best few - so the picture follows
    // the person's newer photos without flickering every time one arrives. Kept
    // in the database, so it is the same everywhere and doesn't reshuffle on restart.

    private class CoverRow(
        val id: Long, val name: String?, val hidden: Boolean, val faceCount: Int, val photoCount: Int,
        val storedCover: Long?, val storedCount: Int, val coverValid: Boolean,
    )

    private fun readCoverRow(c: Cursor) = CoverRow(
        id = c.getLong(0), name = c.getString(1), hidden = c.getInt(2) == 1,
        faceCount = c.getInt(3), photoCount = c.getInt(4),
        storedCover = if (c.isNull(5)) null else c.getLong(5), storedCount = c.getInt(6),
        coverValid = !c.isNull(7),
    )

    private fun CoverRow.toSummary() = PersonSummary(
        id = id, name = name, hidden = hidden, faceCount = faceCount, photoCount = photoCount,
        coverFaceId = coverFor(this),
    )

    private fun coverFor(row: CoverRow): Long {
        val current = row.storedCover
        val stillTheirs = current != null && row.coverValid
        val due = row.faceCount - row.storedCount >= maxOf(COVER_MIN_NEW, row.faceCount / 6)
        if (stillTheirs && !due) return current!!

        // Their best few faces, best first.
        val best = ArrayList<Long>()
        readableDatabase.rawQuery(
            "SELECT id FROM faces WHERE person_id = ? AND length(embedding) > 0 ORDER BY good DESC, rank DESC LIMIT $COVER_POOL",
            arrayOf(row.id.toString())
        ).use { while (it.moveToNext()) best += it.getLong(0) }
        if (best.isEmpty()) return current ?: 0L

        val pick = if (!stillTheirs) {
            best.first() // first time, or the old one is gone: the best
        } else {
            // A change: the newest of the best few, other than the one showing.
            best.filter { it != current }.maxOrNull() ?: current!!
        }
        writableDatabase.execSQL(
            "UPDATE people SET cover_face_id = ?, cover_count = ? WHERE id = ?",
            arrayOf(pick, row.faceCount, row.id)
        )
        return pick
    }

    /** Photos containing a person, clearest first: (uri, hash). */
    fun personPhotos(personId: Long): List<Pair<String, Long>> {
        val out = ArrayList<Pair<String, Long>>()
        readableDatabase.rawQuery(
            """SELECT ph.uri, ph.hash FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE f.person_id = ? GROUP BY ph.hash ORDER BY MAX(f.rank) DESC""",
            arrayOf(personId.toString())
        ).use { while (it.moveToNext()) out += it.getString(0) to it.getLong(1) }
        return out
    }

    // ---- photos by several people ----
    //
    // For every photo that has at least one of the chosen people: how many of them
    // are in it, and how many OTHER people are (clear faces only - a tiny or
    // blurry face in the background is not "somebody else in the photo").

    class PhotoPeople(val uri: String, val hash: Long, val chosen: Int, val others: Int, val rank: Float)

    private fun photoPeople(people: List<Long>): List<PhotoPeople> {
        if (people.isEmpty()) return emptyList()
        val marks = people.joinToString(",") { "?" }
        val args = people.map { it.toString() }.toTypedArray()
        val out = ArrayList<PhotoPeople>()
        readableDatabase.rawQuery(
            """SELECT ph.uri, ph.hash,
                      COUNT(DISTINCT CASE WHEN f.person_id IN ($marks) THEN f.person_id END),
                      SUM(CASE WHEN f.good = 1 AND length(f.embedding) > 0
                                AND (f.person_id IS NULL OR f.person_id NOT IN ($marks)) THEN 1 ELSE 0 END),
                      MAX(f.rank)
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE f.photo_hash IN (SELECT photo_hash FROM faces WHERE person_id IN ($marks))
               GROUP BY ph.hash""",
            args + args + args
        ).use {
            while (it.moveToNext()) {
                out += PhotoPeople(it.getString(0), it.getLong(1), it.getInt(2), it.getInt(3), it.getFloat(4))
            }
        }
        return out
    }

    /**
     * Which photos match, for one way of combining [people]:
     *  - "any":      at least one of them
     *  - "together": all of them, with or without other people
     *  - "only":     all of them and nobody else
     */
    private fun matchesMode(row: PhotoPeople, count: Int, mode: String): Boolean = when (mode) {
        MODE_ANY -> row.chosen >= 1
        MODE_TOGETHER -> row.chosen == count
        MODE_ONLY -> row.chosen == count && row.others == 0
        else -> false
    }

    /** Matching photos, clearest first: (uri, hash). */
    fun peoplePhotos(people: List<Long>, mode: String): List<Pair<String, Long>> =
        photoPeople(people)
            .filter { matchesMode(it, people.size, mode) }
            .sortedByDescending { it.rank }
            .map { it.uri to it.hash }

    /** How many photos each way of combining would give (so the choices can show it). */
    fun peopleCounts(people: List<Long>): Map<String, Int> {
        val rows = photoPeople(people)
        return listOf(MODE_ANY, MODE_TOGETHER, MODE_ONLY).associateWith { mode ->
            rows.count { matchesMode(it, people.size, mode) }
        }
    }

    /** A recognised face in one photo (box as 0..1 fractions of the upright photo). */
    class PhotoFace(
        val faceId: Long,
        val personId: Long,
        val boxL: Float,
        val boxT: Float,
        val boxR: Float,
        val boxB: Float,
        val photoW: Int,
        val photoH: Int,
    )

    /** The faces in a photo that belong to a person (for tapping them in the viewer). */
    fun photoFaces(uri: String): List<PhotoFace> {
        val out = ArrayList<PhotoFace>()
        readableDatabase.rawQuery(
            """SELECT f.id, f.person_id, f.box_l, f.box_t, f.box_r, f.box_b, ph.width, ph.height
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE ph.uri = ? AND f.person_id IS NOT NULL AND length(f.embedding) > 0""",
            arrayOf(uri)
        ).use {
            while (it.moveToNext()) {
                out += PhotoFace(
                    it.getLong(0), it.getLong(1), it.getFloat(2), it.getFloat(3), it.getFloat(4), it.getFloat(5),
                    it.getInt(6), it.getInt(7),
                )
            }
        }
        return out
    }

    /** Every face of a person with where to crop it from, clearest first. */
    fun personFaces(personId: Long): List<FaceLocation> {
        val out = ArrayList<FaceLocation>()
        readableDatabase.rawQuery(
            """SELECT f.id, ph.uri, f.box_l, f.box_t, f.box_r, f.box_b, f.good, f.person_id, ph.width, ph.height
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE f.person_id = ? ORDER BY f.rank DESC""",
            arrayOf(personId.toString())
        ).use { while (it.moveToNext()) out += location(it) }
        return out
    }

    fun faceLocation(faceId: Long): FaceLocation? = readableDatabase.rawQuery(
        """SELECT f.id, ph.uri, f.box_l, f.box_t, f.box_r, f.box_b, f.good, f.person_id, ph.width, ph.height
           FROM faces f JOIN photos ph ON ph.hash = f.photo_hash WHERE f.id = ?""",
        arrayOf(faceId.toString())
    ).use { if (it.moveToFirst()) location(it) else null }

    private fun location(c: Cursor) = FaceLocation(
        faceId = c.getLong(0), photoUri = c.getString(1),
        boxL = c.getFloat(2), boxT = c.getFloat(3), boxR = c.getFloat(4), boxB = c.getFloat(5),
        good = c.getInt(6) == 1, personId = if (c.isNull(7)) null else c.getLong(7),
        photoW = c.getInt(8), photoH = c.getInt(9),
    )

    companion object {
        /** A person needs this many different photos to be listed. */
        const val MIN_PHOTOS_TO_SHOW = 2

        /** How many past merges are remembered (older ones can no longer be undone). */
        private const val MERGE_HISTORY_LIMIT = 30

        const val MODE_ANY = "any"
        const val MODE_TOGETHER = "together"
        const val MODE_ONLY = "only"

        /** At least this many new faces before a person's picture may change. */
        private const val COVER_MIN_NEW = 5

        /** The picture is one of a person's best this-many faces. */
        private const val COVER_POOL = 8

        fun floatsToBlob(values: FloatArray): ByteArray {
            val buffer = ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
            buffer.asFloatBuffer().put(values)
            return buffer.array()
        }

        fun blobToFloats(bytes: ByteArray): FloatArray {
            val out = FloatArray(bytes.size / 4)
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(out)
            return out
        }
    }
}
