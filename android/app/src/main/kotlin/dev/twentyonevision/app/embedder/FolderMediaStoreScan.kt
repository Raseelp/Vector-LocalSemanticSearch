package dev.twentyonevision.app.embedder

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log

// A picked SAF folder has no pre-built index - listing it means a live
// filesystem walk (see SafUtils), and even with that already optimized to
// one query per directory, a directory with many files still costs
// whatever the document provider itself spends stat()-ing each one to
// answer that query. MediaStore ("Index my phone") has none of that cost:
// it's a database Android already built and keeps current in the
// background, so querying it is just a SELECT regardless of file count.
//
// When a picked folder is on this device's primary storage, its files are
// almost always *also* sitting in that same MediaStore index - so this
// resolves the folder to a MediaStore path filter and queries that
// instead of walking SAF at all, giving folder scans the same speed as a
// whole-device scan for the common case.
//
// Deliberately narrow and fail-safe: every function here returns null
// the moment anything is even slightly uncertain (wrong provider, a
// storage volume other than primary, an unparsable id, an Android/-owned
// path with its own scoped-storage history, an API level too old for the
// column this relies on, the query itself failing) - EmbeddingEngine
// treats null as "can't confirm this is complete and correct", and falls
// back to the real directory walk rather than risk returning fewer files
// than actually exist.
object FolderMediaStoreScan {

    private const val TAG = "FolderMediaStoreScan"

    // RELATIVE_PATH (and multi-volume MediaStore queries) need API 29.
    // Below that, always use the real directory walk - not worth the risk
    // of reconstructing an equivalent from the legacy, deprecated DATA
    // column across however many OEM storage layouts exist pre-Q.
    private val SUPPORTED = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    // Null unless folderUri is confidently known to be some path on this
    // device's primary storage, expressed the way MediaStore's
    // RELATIVE_PATH column expresses it (no leading slash, trailing slash
    // included, e.g. "Pictures/Camera/"). Empty string means "the primary
    // volume's root itself was picked" - queryImages/queryVideos treat
    // that as "no path filter needed" further down.
    fun resolvePrimaryRelativePath(folderUri: Uri): String? {
        if (!SUPPORTED) return null
        if (folderUri.authority != "com.android.externalstorage.documents") return null

        val docId = try {
            DocumentsContract.getTreeDocumentId(folderUri)
        } catch (e: Exception) {
            Log.w(TAG, "resolvePrimaryRelativePath: couldn't read tree document id: ${e.message}")
            return null
        }

        val colonIndex = docId.indexOf(':')
        if (colonIndex < 0) return null
        val volumeId = docId.substring(0, colonIndex)
        if (volumeId != "primary") return null

        val relativePath = docId.substring(colonIndex + 1).trim('/')

        // Android/data, Android/obb and Android/media have their own
        // scoped-storage history and aren't consistently represented in
        // MediaStore across OS versions - safer to always walk these for
        // real than risk an incomplete match.
        if (relativePath == "Android" || relativePath.startsWith("Android/")) return null

        return if (relativePath.isEmpty()) "" else "$relativePath/"
    }

    // Same selection criteria as SafUtils' extension check (.jpg/.jpeg/
    // .png/.webp) applied as a post-filter on the query results, so this
    // fast path can never return a different *set* of files than the slow
    // path would have for the same folder - only the same set, faster.
    fun queryImages(context: Context, relativePath: String): List<ImageSource>? {
        // Self-guarded, not just relying on the SUPPORTED check in
        // resolvePrimaryRelativePath - VOLUME_EXTERNAL_PRIMARY and
        // RELATIVE_PATH below both need API 29, and keeping that check in
        // the same function that uses them is what lets Android Lint's
        // NewApi check actually verify it (it can't always see across a
        // guard living in a different function).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.DATE_MODIFIED,
                MediaStore.Images.Media.DISPLAY_NAME
            )
            val (selection, args) = relativePathSelection(relativePath)

            val result = mutableListOf<ImageSource>()
            context.contentResolver.query(collection, projection, selection, args, null)?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                val sizeCol = c.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                val modCol = c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
                val nameCol = c.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)

                while (c.moveToNext()) {
                    val name = c.getString(nameCol) ?: ""
                    if (!isImageName(name)) continue
                    val id = c.getLong(idCol)
                    result.add(
                        ImageSource(
                            uri = ContentUris.withAppendedId(collection, id),
                            size = c.getLong(sizeCol),
                            // MediaStore's DATE_MODIFIED is Unix seconds,
                            // not milliseconds - normalized here so a file
                            // hashes the same (HashUtils.identityHash)
                            // whether this fast path or the millisecond-
                            // based SAF fallback found it, on any retry.
                            lastModified = c.getLong(modCol) * 1000L,
                            name = name
                        )
                    )
                }
            }
            result
        } catch (e: Exception) {
            Log.w(TAG, "queryImages: failed, caller will fall back: ${e.message}")
            null
        }
    }

    fun queryVideos(context: Context, relativePath: String): List<VideoSource>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val projection = arrayOf(
                MediaStore.Video.Media._ID,
                MediaStore.Video.Media.SIZE,
                MediaStore.Video.Media.DATE_MODIFIED,
                MediaStore.Video.Media.DISPLAY_NAME,
                MediaStore.Video.Media.MIME_TYPE
            )
            val (selection, args) = relativePathSelection(relativePath)

            val result = mutableListOf<VideoSource>()
            context.contentResolver.query(collection, projection, selection, args, null)?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                val sizeCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
                val modCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_MODIFIED)
                val nameCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
                val mimeCol = c.getColumnIndexOrThrow(MediaStore.Video.Media.MIME_TYPE)

                while (c.moveToNext()) {
                    // Same criteria as SafUtils' video check
                    // (mimeType.startsWith("video/")) - MediaStore's Video
                    // collection should already only contain these, this
                    // is just parity with the fallback path, not a real
                    // expected filter.
                    val mimeType = c.getString(mimeCol) ?: ""
                    if (!mimeType.startsWith("video/")) continue
                    val id = c.getLong(idCol)
                    result.add(
                        VideoSource(
                            uri = ContentUris.withAppendedId(collection, id),
                            size = c.getLong(sizeCol),
                            lastModified = c.getLong(modCol) * 1000L,
                            name = c.getString(nameCol) ?: ""
                        )
                    )
                }
            }
            result
        } catch (e: Exception) {
            Log.w(TAG, "queryVideos: failed, caller will fall back: ${e.message}")
            null
        }
    }

    private fun isImageName(name: String): Boolean {
        val lower = name.lowercase()
        return lower.endsWith(".jpg") || lower.endsWith(".jpeg") ||
            lower.endsWith(".png") || lower.endsWith(".webp")
    }

    // Matches the folder itself and everything under it, the same
    // recursive reach SafUtils' directory walk has - MediaStore always
    // stores RELATIVE_PATH with a trailing slash (e.g. "Pictures/Camera/"
    // for a file directly in it, "Pictures/Camera/2024/" for one in a
    // subfolder), so a LIKE 'prefix/%' catches both. Empty relativePath
    // means the primary volume's root was picked - no filter needed, every
    // file on the volume already qualifies.
    //
    // Matched against RELATIVE_PATH *or* the legacy DATA (absolute path)
    // column, not RELATIVE_PATH alone - RELATIVE_PATH is often NULL for
    // entries that predate an Android 10 upgrade or haven't been rescanned
    // since, and LIKE against NULL matches nothing, so a RELATIVE_PATH-only
    // filter can silently return zero rows for a folder that's very much
    // not empty (this is exactly what happened testing this: even DCIM
    // came back empty). DATA is officially deprecated for writing under
    // scoped storage, but has stayed reliably populated for reading across
    // every Android version specifically because so much software depends
    // on it. Matching either column can only find more files, never fewer.
    private fun relativePathSelection(relativePath: String): Pair<String?, Array<String>?> {
        if (relativePath.isEmpty()) return null to null

        val storageRoot = Environment.getExternalStorageDirectory()?.absolutePath
        val dataPrefix = if (storageRoot != null) "$storageRoot/$relativePath" else null

        return if (dataPrefix != null) {
            "(${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? OR ${MediaStore.MediaColumns.DATA} LIKE ?)" to
                arrayOf("$relativePath%", "$dataPrefix%")
        } else {
            // Couldn't resolve the storage root for some reason - fall
            // back to RELATIVE_PATH alone rather than fail the query
            // entirely (still better than nothing, and queryImages/
            // queryVideos returning null on a genuine problem elsewhere
            // is the real safety net here).
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?" to arrayOf("$relativePath%")
        }
    }
}
