package dev.twentyonevision.app.embedder.faces

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.graphics.Bitmap
import java.io.File
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
    // The photo or video the face is in (for a video's frames, the video's own key).
    val mediaKey: Long,
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
    // A face found in a video's frame: its picture is kept as a file, not cut from the video.
    val isVideo: Boolean = false,
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
class FaceStore(private val context: Context) : SQLiteOpenHelper(context.applicationContext, "faces.db", null, 8) {

    // Small pictures of the faces found in videos (a video frame can't be cut out again
    // cheaply, so the picture is kept when the face is found).
    private val cropsDir by lazy { File(context.applicationContext.filesDir, "face_crops") }

    fun cropFile(faceId: Long): File = File(cropsDir, "$faceId.jpg")

    fun saveCrop(faceId: Long, bitmap: Bitmap) {
        try {
            cropsDir.mkdirs()
            cropFile(faceId).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 82, it) }
        } catch (_: Exception) {
        }
    }

    fun saveCropBytes(faceId: Long, bytes: ByteArray) {
        try {
            cropsDir.mkdirs()
            cropFile(faceId).writeBytes(bytes)
        } catch (_: Exception) {
        }
    }

    private fun deleteCrops(ids: Collection<Long>) {
        for (id in ids) {
            try {
                cropFile(id).delete()
            } catch (_: Exception) {
            }
        }
    }

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
                complete INTEGER NOT NULL DEFAULT 0,
                video_hash INTEGER,
                ts_ms INTEGER NOT NULL DEFAULT 0
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
                blocked_person INTEGER,
                media_key INTEGER
            )"""
        )
        db.execSQL("CREATE INDEX faces_person ON faces(person_id)")
        db.execSQL("CREATE INDEX faces_photo ON faces(photo_hash)")
        db.execSQL("CREATE INDEX faces_media ON faces(media_key)")
        createRejections(db)
        createMergeHistory(db)
        createVideos(db)
        createVideoSeen(db)
    }

    // People named in a video by looking at one of its frames (the video viewer's paused-frame
    // check): nothing else is stored from that look, but "they are in this video, around here"
    // is, so they join the video's list of people.
    private fun createVideoSeen(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS video_seen (
                uri TEXT NOT NULL,
                ts_ms INTEGER NOT NULL,
                person_id INTEGER NOT NULL,
                PRIMARY KEY (uri, ts_ms, person_id)
            )"""
        )
    }

    // Videos already gone through (their sampled frames live in `photos` with video_hash set).
    private fun createVideos(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE IF NOT EXISTS videos (
                hash INTEGER PRIMARY KEY,
                uri TEXT NOT NULL,
                frames INTEGER NOT NULL DEFAULT 0,
                faces INTEGER NOT NULL DEFAULT 0,
                processed_at INTEGER NOT NULL DEFAULT 0,
                exact INTEGER NOT NULL DEFAULT 0
            )"""
        )
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
        if (oldVersion < 6) {
            // Video frames: a photo row per sampled frame, and every face knows which photo
            // or video it belongs to (for counting: a video is one item however many frames).
            db.execSQL("ALTER TABLE photos ADD COLUMN video_hash INTEGER")
            db.execSQL("ALTER TABLE photos ADD COLUMN ts_ms INTEGER NOT NULL DEFAULT 0")
            db.execSQL("ALTER TABLE faces ADD COLUMN media_key INTEGER")
            db.execSQL("UPDATE faces SET media_key = photo_hash")
            db.execSQL("CREATE INDEX IF NOT EXISTS faces_media ON faces(media_key)")
            createVideos(db)
        }
        // Whether a video's faces were found on the exact frame at each time (so their positions
        // line up with the picture the player shows there). Older scans used the nearest keyframe.
        if (oldVersion == 6) db.execSQL("ALTER TABLE videos ADD COLUMN exact INTEGER NOT NULL DEFAULT 0")
        if (oldVersion < 8) createVideoSeen(db)
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
        readableDatabase.rawQuery("SELECT hash FROM photos WHERE video_hash IS NULL", null).use {
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
        "SELECT 1 FROM photos WHERE uri = ? AND video_hash IS NULL", arrayOf(uri)
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
                    put("media_key", hash)
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

    // ---- videos ----

    /** One sampled frame of a video with the faces kept from it. */
    class FrameFaces(val tsMs: Long, val width: Int, val height: Int, val faces: List<FaceRow>)

    // A video's row says how it was gone through: exact 1 = a full scan on exact frames, 0 = a full
    // scan on keyframes (older), 2 = only single frames were looked at by hand (the viewer's
    // paused-frame check) - not a scan, so the video still counts as not scanned.

    /** Videos gone through completely. */
    fun processedVideoHashes(): HashSet<Long> {
        val out = HashSet<Long>()
        readableDatabase.rawQuery("SELECT hash FROM videos WHERE exact != 2", null).use { while (it.moveToNext()) out.add(it.getLong(0)) }
        return out
    }

    private fun allVideoHashes(): List<Long> {
        val out = ArrayList<Long>()
        readableDatabase.rawQuery("SELECT hash FROM videos", null).use { while (it.moveToNext()) out.add(it.getLong(0)) }
        return out
    }

    /** True if any frame of the video is stored (from a scan or from looking at a frame). */
    fun videoHasFrames(hash: Long): Boolean = readableDatabase.rawQuery(
        "SELECT 1 FROM photos WHERE video_hash = ? LIMIT 1", arrayOf(hash.toString())
    ).use { it.moveToFirst() }

    fun hasFrame(videoHash: Long, tsMs: Long): Boolean = readableDatabase.rawQuery(
        "SELECT 1 FROM photos WHERE hash = ?", arrayOf(frameHash(videoHash, tsMs).toString())
    ).use { it.moveToFirst() }

    /**
     * Stores one frame the viewer looked at by hand, with the faces that were matched to people
     * there - the same way a scan stores a frame, so what the person sees later (their moments,
     * the instant outline) never depends on how the face was found. It does not make the video
     * count as scanned. Returns the new face ids in order.
     */
    fun storeLookedFrame(videoHash: Long, uri: String, tsMs: Long, width: Int, height: Int, faces: List<FaceRow>): List<Long> {
        val db = writableDatabase
        val ids = ArrayList<Long>(faces.size)
        db.beginTransaction()
        try {
            db.execSQL(
                "INSERT OR IGNORE INTO videos(hash, uri, frames, faces, processed_at, exact) VALUES (?,?,0,0,?,2)",
                arrayOf(videoHash, uri, System.currentTimeMillis())
            )
            val hash = frameHash(videoHash, tsMs)
            db.execSQL(
                "INSERT OR REPLACE INTO photos(hash, uri, width, height, face_count, processed_at, complete, video_hash, ts_ms) VALUES (?,?,?,?,?,?,1,?,?)",
                arrayOf(hash, uri, width, height, faces.size, System.currentTimeMillis(), videoHash, tsMs)
            )
            for (f in faces) {
                val values = ContentValues().apply {
                    put("photo_hash", hash)
                    put("media_key", videoHash)
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

    /** A video that had only single frames looked at is now counted as fully scanned, keeping those frames. */
    fun markVideoScanned(hash: Long, uri: String) {
        val db = writableDatabase
        db.execSQL("INSERT OR IGNORE INTO videos(hash, uri, frames, faces, processed_at, exact) VALUES (?,?,0,0,?,1)", arrayOf(hash, uri, System.currentTimeMillis()))
        db.execSQL("UPDATE videos SET exact = 1, processed_at = ? WHERE hash = ?", arrayOf(System.currentTimeMillis(), hash))
    }

    /** True once a video has been gone through completely (even if no faces were found in it). */
    fun isVideoDone(hash: Long): Boolean = readableDatabase.rawQuery(
        "SELECT 1 FROM videos WHERE hash = ? AND exact != 2", arrayOf(hash.toString())
    ).use { it.moveToFirst() }

    /** How many faces the last scan of a video kept (null if it was never scanned). */
    fun videoFaceCount(hash: Long): Int? = readableDatabase.rawQuery(
        "SELECT faces FROM videos WHERE hash = ? AND exact != 2", arrayOf(hash.toString())
    ).use { if (it.moveToFirst()) it.getInt(0) else null }

    fun videoCount(): Int = readableDatabase.rawQuery("SELECT COUNT(*) FROM videos WHERE exact != 2", null).use {
        if (it.moveToFirst()) it.getInt(0) else 0
    }

    /** What identifies one sampled frame among all photos. */
    fun frameHash(videoHash: Long, tsMs: Long): Long =
        (videoHash * 1_000_003L) xor (tsMs * 0x2545F4914F6CDD1DL) xor 0x5851F42D4C957F2DL

    /**
     * Stores a whole video at once (all its frames and faces, and the mark that it is done),
     * so there is never a half-scanned video. Returns, per frame, the new face ids in order.
     */
    fun insertVideo(videoHash: Long, uri: String, frames: List<FrameFaces>): List<List<Long>> {
        val db = writableDatabase
        val all = ArrayList<List<Long>>(frames.size)
        db.beginTransaction()
        try {
            deleteVideoInside(db, videoHash)
            var faceTotal = 0
            for (frame in frames) {
                val hash = frameHash(videoHash, frame.tsMs)
                db.execSQL(
                    "INSERT OR REPLACE INTO photos(hash, uri, width, height, face_count, processed_at, complete, video_hash, ts_ms) VALUES (?,?,?,?,?,?,1,?,?)",
                    arrayOf(hash, uri, frame.width, frame.height, frame.faces.size, System.currentTimeMillis(), videoHash, frame.tsMs)
                )
                val ids = ArrayList<Long>(frame.faces.size)
                for (f in frame.faces) {
                    val values = ContentValues().apply {
                        put("photo_hash", hash)
                        put("media_key", videoHash)
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
                faceTotal += ids.size
                all += ids
            }
            db.execSQL(
                "INSERT OR REPLACE INTO videos(hash, uri, frames, faces, processed_at, exact) VALUES (?,?,?,?,?,1)",
                arrayOf(videoHash, uri, frames.size, faceTotal, System.currentTimeMillis())
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return all
    }

    // Removes what an earlier (interrupted) scan of this video left, faces and pictures included.
    private fun deleteVideoInside(db: SQLiteDatabase, videoHash: Long) {
        val ids = ArrayList<Long>()
        db.rawQuery(
            "SELECT f.id FROM faces f JOIN photos ph ON ph.hash = f.photo_hash WHERE ph.video_hash = ?",
            arrayOf(videoHash.toString())
        ).use { while (it.moveToNext()) ids += it.getLong(0) }
        for (chunk in ids.chunked(400)) {
            db.execSQL("DELETE FROM faces WHERE id IN (${chunk.joinToString(",") { "?" }})", chunk.map { it.toString() }.toTypedArray())
        }
        db.execSQL("DELETE FROM photos WHERE video_hash = ?", arrayOf(videoHash))
        db.execSQL("DELETE FROM videos WHERE hash = ?", arrayOf(videoHash))
        deleteCrops(ids)
    }

    /**
     * Forgets videos that are no longer in the search index; true if anything was removed.
     * Same safety rule as [purgeMissing]: an empty [existing] while videos are already stored
     * is treated as the index not being ready, not as every video having been deleted.
     */
    fun purgeMissingVideos(existing: Set<Long>): Boolean {
        val db = writableDatabase
        val all = allVideoHashes()
        if (existing.isEmpty() && all.isNotEmpty()) return false
        val gone = all.filter { it !in existing }
        if (gone.isEmpty()) return false
        db.beginTransaction()
        try {
            for (hash in gone) deleteVideoInside(db, hash)
            pruneEmptyPeople(db)
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        return true
    }

    /**
     * The people the scan stored for the frame of [uri] at exactly [tsMs]: (whether the scan
     * read exact frames, so the positions can be trusted on screen; the faces). Empty when
     * nothing was stored at that moment.
     */
    fun videoFrameFaces(uri: String, tsMs: Long): Pair<Boolean, List<PhotoFace>> {
        val out = ArrayList<PhotoFace>()
        var exact = false
        readableDatabase.rawQuery(
            """SELECT f.id, f.person_id, f.box_l, f.box_t, f.box_r, f.box_b, ph.width, ph.height, v.exact
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash JOIN videos v ON v.hash = ph.video_hash
               WHERE ph.uri = ? AND ph.video_hash IS NOT NULL AND ph.ts_ms = ? AND f.person_id IS NOT NULL""",
            arrayOf(uri, tsMs.toString())
        ).use {
            while (it.moveToNext()) {
                exact = it.getInt(8) != 0 // a scan on exact frames (1) or a frame looked at by hand (2)
                out += PhotoFace(
                    it.getLong(0), it.getLong(1), it.getFloat(2), it.getFloat(3), it.getFloat(4), it.getFloat(5),
                    it.getInt(6), it.getInt(7),
                )
            }
        }
        return exact to out
    }

    /** Notes that these people were seen around [tsMs] of a video (found by looking at that frame). */
    fun recordVideoSeen(uri: String, tsMs: Long, personIds: Collection<Long>) {
        if (personIds.isEmpty()) return
        val rounded = tsMs // the exact moment: it matches the frame stored for it
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (id in personIds) {
                db.execSQL("INSERT OR IGNORE INTO video_seen(uri, ts_ms, person_id) VALUES (?,?,?)", arrayOf(uri, rounded, id))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** People noted in a video by looking at its frames: (person id, time in ms), earliest first. */
    fun videoSeen(uri: String): List<Pair<Long, Long>> {
        val out = ArrayList<Pair<Long, Long>>()
        readableDatabase.rawQuery(
            "SELECT person_id, ts_ms FROM video_seen WHERE uri = ? AND person_id IN (SELECT id FROM people) ORDER BY ts_ms ASC",
            arrayOf(uri)
        ).use { while (it.moveToNext()) out += it.getLong(0) to it.getLong(1) }
        return out
    }

    /** The people seen in a video and when: (person id, time in ms), earliest first. */
    fun videoSightings(uri: String): List<Pair<Long, Long>> {
        val out = ArrayList<Pair<Long, Long>>()
        readableDatabase.rawQuery(
            """SELECT f.person_id, ph.ts_ms FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE ph.uri = ? AND ph.video_hash IS NOT NULL AND f.person_id IS NOT NULL
               ORDER BY ph.ts_ms ASC""",
            arrayOf(uri)
        ).use { while (it.moveToNext()) out += it.getLong(0) to it.getLong(1) }
        return out
    }

    /**
     * Forgets photos that are no longer in the search index, and people left empty.
     * [existing] empty while faces are already stored is treated as the index not being ready
     * yet (still loading, a permission hiccup, storage briefly unavailable) rather than "every
     * photo was deleted" - it is never trusted to wipe everything in one go.
     */
    fun purgeMissing(existing: Set<Long>): Boolean {
        val db = writableDatabase
        val stored = ArrayList<Long>()
        db.rawQuery("SELECT hash FROM photos WHERE video_hash IS NULL", null).use { while (it.moveToNext()) stored.add(it.getLong(0)) }
        if (existing.isEmpty() && stored.isNotEmpty()) return false
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
            db.execSQL("DELETE FROM videos")
            db.execSQL("DELETE FROM video_seen")
            // Each video's remembered search level starts over with the rest.
            db.execSQL("DELETE FROM meta WHERE key LIKE 'video_relax_%' OR key LIKE 'video_fail_%'")
            db.execSQL("DELETE FROM people")
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
        try {
            cropsDir.deleteRecursively()
        } catch (_: Exception) {
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
            db.execSQL("UPDATE OR IGNORE video_seen SET person_id = ? WHERE person_id = ?", arrayOf(into, from))
            db.execSQL("DELETE FROM video_seen WHERE person_id = ?", arrayOf(from))
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
            "SELECT id, photo_hash, embedding, good, rank, person_id, locked, blocked_person, media_key " +
                "FROM faces WHERE ($where) AND length(embedding) > 0 ORDER BY rank DESC",
            null
        ).use { c ->
            while (c.moveToNext()) block(readFace(c))
        }
    }

    private fun readFace(c: Cursor) = StoredFace(
        id = c.getLong(0),
        photoHash = c.getLong(1),
        mediaKey = if (c.isNull(8)) c.getLong(1) else c.getLong(8),
        embedding = blobToFloats(c.getBlob(2)),
        good = c.getInt(3) == 1,
        rank = c.getFloat(4),
        personId = if (c.isNull(5)) null else c.getLong(5),
        locked = c.getInt(6) == 1,
        blockedPerson = if (c.isNull(7)) null else c.getLong(7),
    )

    fun face(id: Long): StoredFace? = readableDatabase.rawQuery(
        "SELECT id, photo_hash, embedding, good, rank, person_id, locked, blocked_person, media_key FROM faces WHERE id = ?",
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
        "SELECT COUNT(DISTINCT f.photo_hash) FROM faces f JOIN photos ph ON ph.hash = f.photo_hash " +
            "WHERE length(f.embedding) = 0 AND ph.video_hash IS NULL", null
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
               WHERE ph.video_hash IS NULL
                 AND EXISTS (SELECT 1 FROM faces f WHERE f.photo_hash = ph.hash AND length(f.embedding) = 0)
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
        "SELECT hash FROM photos WHERE uri = ? AND video_hash IS NULL", arrayOf(uri)
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
        val photos = db.rawQuery("SELECT COUNT(*) FROM photos WHERE video_hash IS NULL", null).use { it.moveToFirst(); it.getInt(0) }
        val faces = db.rawQuery("SELECT COUNT(*) FROM faces", null).use { it.moveToFirst(); it.getInt(0) }
        val people = db.rawQuery(
            "SELECT COUNT(*) FROM (SELECT person_id FROM faces WHERE person_id IS NOT NULL " +
                "GROUP BY person_id HAVING COUNT(DISTINCT COALESCE(media_key, photo_hash)) >= $MIN_PHOTOS_TO_SHOW)",
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
            """SELECT p.id, p.name, p.hidden, COUNT(f.id), COUNT(DISTINCT COALESCE(f.media_key, f.photo_hash)),
                      p.cover_face_id, p.cover_count,
                      (SELECT 1 FROM faces c WHERE c.id = p.cover_face_id AND c.person_id = p.id)
               FROM people p JOIN faces f ON f.person_id = p.id
               WHERE p.hidden = ?
               GROUP BY p.id
               HAVING COUNT(DISTINCT COALESCE(f.media_key, f.photo_hash)) >= $MIN_PHOTOS_TO_SHOW
               ORDER BY COUNT(DISTINCT COALESCE(f.media_key, f.photo_hash)) DESC, p.id ASC""",
            arrayOf(if (hidden) "1" else "0")
        ).use { while (it.moveToNext()) rows += readCoverRow(it) }
        // After the read cursor is closed: choosing a cover can write.
        return rows.map { it.toSummary() }
    }

    fun personSummary(id: Long): PersonSummary? {
        val row = readableDatabase.rawQuery(
            """SELECT p.id, p.name, p.hidden, COUNT(f.id), COUNT(DISTINCT COALESCE(f.media_key, f.photo_hash)),
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

    /** A photo or a video that has someone in it; for a video, [tsMs] is the moment to open it at. */
    class MediaItem(val uri: String, val key: Long, val isVideo: Boolean, val tsMs: Long)

    /** Photos and videos containing a person, clearest first (a video once, at where they show best). */
    fun personMedia(personId: Long): List<MediaItem> {
        class Best(val uri: String, val isVideo: Boolean, val ts: Long, val rank: Float)

        val best = LinkedHashMap<Long, Best>()
        readableDatabase.rawQuery(
            """SELECT ph.uri, COALESCE(f.media_key, f.photo_hash), ph.video_hash IS NOT NULL, ph.ts_ms, f.rank
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE f.person_id = ?""",
            arrayOf(personId.toString())
        ).use {
            while (it.moveToNext()) {
                val key = it.getLong(1)
                val rank = it.getFloat(4)
                val current = best[key]
                if (current == null || rank > current.rank) {
                    best[key] = Best(it.getString(0), it.getInt(2) == 1, it.getLong(3), rank)
                }
            }
        }
        return best.entries.sortedByDescending { it.value.rank }
            .map { (key, b) -> MediaItem(b.uri, key, b.isVideo, b.ts) }
    }

    // ---- photos and videos with several people ----
    //
    // For every photo that has at least one of the chosen people: are they in it (any /
    // all / all and nobody else)? Only clear faces count as "somebody else" - a tiny or
    // blurry face in the background is not. A video's frames are judged in short windows:
    // "together" means the chosen people all show up within a couple of seconds of each other.

    class MediaHit(
        val uri: String,
        val key: Long,
        val isVideo: Boolean,
        val tsMs: Long,
        val rank: Float,
        val any: Boolean,
        val together: Boolean,
        val only: Boolean,
    )

    private class FrameRow(
        val uri: String,
        val hash: Long,
        val videoHash: Long?,
        val tsMs: Long,
        val chosen: Set<Long>,
        val others: Int,
        val rank: Float,
    )

    private fun frameRows(people: List<Long>): List<FrameRow> {
        if (people.isEmpty()) return emptyList()
        val marks = people.joinToString(",") { "?" }
        val args = people.map { it.toString() }.toTypedArray()
        val out = ArrayList<FrameRow>()
        readableDatabase.rawQuery(
            """SELECT ph.uri, ph.hash, ph.video_hash, ph.ts_ms,
                      GROUP_CONCAT(DISTINCT CASE WHEN f.person_id IN ($marks) THEN f.person_id END),
                      SUM(CASE WHEN f.good = 1 AND length(f.embedding) > 0
                                AND (f.person_id IS NULL OR f.person_id NOT IN ($marks)) THEN 1 ELSE 0 END),
                      MAX(f.rank)
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE f.photo_hash IN (SELECT photo_hash FROM faces WHERE person_id IN ($marks))
               GROUP BY ph.hash""",
            args + args + args
        ).use {
            while (it.moveToNext()) {
                val chosen = (it.getString(4) ?: "").split(",").mapNotNull { s -> s.trim().toLongOrNull() }.toSet()
                out += FrameRow(
                    uri = it.getString(0), hash = it.getLong(1),
                    videoHash = if (it.isNull(2)) null else it.getLong(2),
                    tsMs = it.getLong(3), chosen = chosen, others = it.getInt(5), rank = it.getFloat(6),
                )
            }
        }
        return out
    }

    private fun mediaHits(people: List<Long>): List<MediaHit> {
        val rows = frameRows(people)
        val count = people.size
        val out = ArrayList<MediaHit>()
        val videos = LinkedHashMap<Long, ArrayList<FrameRow>>()

        for (r in rows) {
            val video = r.videoHash
            if (video == null) {
                out += MediaHit(
                    r.uri, r.hash, false, 0L, r.rank,
                    any = r.chosen.isNotEmpty(),
                    together = r.chosen.size == count,
                    only = r.chosen.size == count && r.others == 0,
                )
            } else {
                videos.getOrPut(video) { ArrayList() } += r
            }
        }

        for ((key, frames) in videos) {
            frames.sortBy { it.tsMs }
            var together = false
            var only = false
            var togetherTs = -1L
            for (i in frames.indices) {
                val union = HashSet<Long>()
                var othersMax = 0
                var j = i
                while (j < frames.size && frames[j].tsMs - frames[i].tsMs <= VIDEO_TOGETHER_MS) {
                    union += frames[j].chosen
                    othersMax = maxOf(othersMax, frames[j].others)
                    j++
                }
                if (union.size == count) {
                    if (!together) togetherTs = frames[i].tsMs
                    together = true
                    if (othersMax == 0) only = true
                }
            }
            val bestFrame = frames.maxByOrNull { it.rank } ?: continue
            out += MediaHit(
                frames.first().uri, key, true,
                if (togetherTs >= 0) togetherTs else bestFrame.tsMs,
                bestFrame.rank,
                any = frames.any { it.chosen.isNotEmpty() },
                together = together, only = only,
            )
        }
        return out
    }

    /**
     * Which photos and videos match, for one way of combining [people]:
     *  - "any":      at least one of them
     *  - "together": all of them, with or without other people
     *  - "only":     all of them and nobody else
     */
    private fun matches(hit: MediaHit, mode: String): Boolean = when (mode) {
        MODE_ANY -> hit.any
        MODE_TOGETHER -> hit.together
        MODE_ONLY -> hit.only
        else -> false
    }

    /** Matching photos and videos, clearest first. */
    fun peopleMedia(people: List<Long>, mode: String): List<MediaItem> =
        mediaHits(people)
            .filter { matches(it, mode) }
            .sortedByDescending { it.rank }
            .map { MediaItem(it.uri, it.key, it.isVideo, it.tsMs) }

    /** How many photos and videos each way of combining would give (so the choices can show it). */
    fun peopleCounts(people: List<Long>): Map<String, Int> {
        val hits = mediaHits(people)
        return listOf(MODE_ANY, MODE_TOGETHER, MODE_ONLY).associateWith { mode -> hits.count { matches(it, mode) } }
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
               WHERE ph.uri = ? AND ph.video_hash IS NULL AND f.person_id IS NOT NULL AND length(f.embedding) > 0""",
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
            """SELECT f.id, ph.uri, f.box_l, f.box_t, f.box_r, f.box_b, f.good, f.person_id, ph.width, ph.height,
                      ph.video_hash IS NOT NULL
               FROM faces f JOIN photos ph ON ph.hash = f.photo_hash
               WHERE f.person_id = ? ORDER BY f.rank DESC""",
            arrayOf(personId.toString())
        ).use { while (it.moveToNext()) out += location(it) }
        return out
    }

    fun faceLocation(faceId: Long): FaceLocation? = readableDatabase.rawQuery(
        """SELECT f.id, ph.uri, f.box_l, f.box_t, f.box_r, f.box_b, f.good, f.person_id, ph.width, ph.height,
                  ph.video_hash IS NOT NULL
           FROM faces f JOIN photos ph ON ph.hash = f.photo_hash WHERE f.id = ?""",
        arrayOf(faceId.toString())
    ).use { if (it.moveToFirst()) location(it) else null }

    private fun location(c: Cursor) = FaceLocation(
        faceId = c.getLong(0), photoUri = c.getString(1),
        boxL = c.getFloat(2), boxT = c.getFloat(3), boxR = c.getFloat(4), boxB = c.getFloat(5),
        good = c.getInt(6) == 1, personId = if (c.isNull(7)) null else c.getLong(7),
        photoW = c.getInt(8), photoH = c.getInt(9), isVideo = c.getInt(10) == 1,
    )

    companion object {
        /** A person needs this many different photos or videos to be listed. */
        const val MIN_PHOTOS_TO_SHOW = 2

        /** In a video, people "together" show up within this many ms of each other. */
        private const val VIDEO_TOGETHER_MS = 3000L

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
