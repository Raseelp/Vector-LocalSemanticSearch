package dev.twentyonevision.app.embedder

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors

// A single classified document found under a picked SAF folder tree -
// carries everything ImageSource/VideoSource need, already resolved from
// the same cursor row that found it (see listOneDirectory). Deliberately
// not DocumentFile: DocumentFile.listFiles() only fetches each child's id
// up front, so every later access to .isDirectory/.name/.type/.length/
// .lastModified is its own separate query to the document provider - for
// a folder with hundreds of files that's hundreds of extra IPC round
// trips just to classify them, on top of whatever it takes to list them
// in the first place. Querying DocumentsContract directly with a full
// projection gets every attribute for every child of a directory in ONE
// query, and this type carries that data along so nothing downstream
// re-queries it either.
data class SafDocument(
    val uri: Uri,
    val name: String,
    val mimeType: String,
    val size: Long,
    val lastModified: Long
)

object SafUtils {

    private const val TAG = "SafUtils"

    // I/O-bound (waiting on the document provider, not on CPU), so a
    // decent thread count is worth it for a folder with many sibling
    // subdirectories - still conservative enough not to flood a provider
    // that serializes requests anyway.
    private const val TRAVERSE_THREAD_COUNT = 12

    private val PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED
    )

    fun listImageFiles(
        context: Context,
        treeUri: Uri,
        isCancelled: () -> Boolean = { false },
        onFileFound: () -> Unit = {}
    ): List<SafDocument> = traverse(
        context, treeUri,
        matches = { name, _ -> isImageName(name) },
        isCancelled = isCancelled,
        onFileFound = onFileFound
    )

    fun listVideoFiles(
        context: Context,
        treeUri: Uri,
        isCancelled: () -> Boolean = { false },
        onFileFound: () -> Unit = {}
    ): List<SafDocument> = traverse(
        context, treeUri,
        matches = { _, mimeType -> mimeType.startsWith("video/") },
        isCancelled = isCancelled,
        onFileFound = onFileFound
    )

    private fun isImageName(name: String): Boolean {
        val lower = name.lowercase()
        return lower.endsWith(".jpg") || lower.endsWith(".jpeg") ||
            lower.endsWith(".png") || lower.endsWith(".webp")
    }

    // Driven by completion order, not level by level: the root is
    // submitted, and every time ANY submitted directory finishes, its
    // files are reported (onFileFound fires per match, right away) and
    // its subdirectories are immediately submitted too - so the pool
    // stays continuously full of in-flight queries across the whole tree,
    // and progress advances the moment each one lands instead of only
    // once an entire depth's worth of them all finish together (which is
    // what caused progress to look stalled, then jump - a directory whose
    // level happens to contain hundreds of siblings would previously hold
    // every one of them back until the last straggler finished).
    //
    // take() below is only ever called from this one orchestrating
    // thread, never from inside a pool worker - so no worker thread is
    // ever blocked waiting on another worker thread's result, which is
    // what would risk a thread-pool deadlock with a fixed-size pool (a
    // naive "recurse and submit more work from inside a pool thread"
    // version of this can starve itself that way on a deep tree).
    // onFileFound is likewise only ever called from this same single
    // thread, since it closes over mutable state (a counter, a last-emit
    // timestamp) on the caller's side that isn't set up to be touched
    // from multiple threads at once.
    private fun traverse(
        context: Context,
        treeUri: Uri,
        matches: (name: String, mimeType: String) -> Boolean,
        isCancelled: () -> Boolean,
        onFileFound: () -> Unit
    ): List<SafDocument> {
        val rootDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            Log.w(TAG, "traverse: couldn't resolve tree document id: ${e.message}")
            return emptyList()
        }

        val results = mutableListOf<SafDocument>()
        val pool = Executors.newFixedThreadPool(TRAVERSE_THREAD_COUNT)
        val completionService = ExecutorCompletionService<Pair<List<SafDocument>, List<String>>>(pool)

        fun submit(docId: String) {
            completionService.submit(Callable { listOneDirectory(context, treeUri, docId, matches) })
        }

        try {
            var pending = 1
            submit(rootDocId)

            while (pending > 0 && !isCancelled()) {
                val future = try {
                    completionService.take()
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
                pending--

                val (files, subdirIds) = try {
                    future.get()
                } catch (e: Exception) {
                    // One directory failing to list (revoked access, a
                    // transient provider error) shouldn't take the rest
                    // of the tree down with it.
                    Log.w(TAG, "traverse: a directory failed to list: ${e.message}")
                    continue
                }

                for (file in files) {
                    results.add(file)
                    onFileFound()
                }

                if (!isCancelled()) {
                    for (docId in subdirIds) {
                        pending++
                        submit(docId)
                    }
                }
            }
        } finally {
            pool.shutdownNow()
        }

        return results
    }

    // One retry before giving up on a directory - a transient provider
    // hiccup (a momentary timeout, a busy binder queue under concurrent
    // load) shouldn't cost an entire subtree of files just because the
    // first attempt happened to fail. Only a genuine, repeated failure
    // (permission actually revoked, directory actually gone) gives up.
    private fun listOneDirectory(
        context: Context,
        treeUri: Uri,
        parentDocId: String,
        matches: (name: String, mimeType: String) -> Boolean
    ): Pair<List<SafDocument>, List<String>> {
        queryOneDirectory(context, treeUri, parentDocId, matches)?.let { return it }

        try {
            Thread.sleep(50)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            return emptyList<SafDocument>() to emptyList()
        }

        queryOneDirectory(context, treeUri, parentDocId, matches)?.let { return it }

        Log.w(TAG, "listOneDirectory: giving up on $parentDocId after a retry")
        return emptyList<SafDocument>() to emptyList()
    }

    // Null (not an empty pair) specifically means "the query itself
    // failed" - lets listOneDirectory tell that apart from "the query
    // succeeded and this directory is genuinely empty", which must never
    // trigger a retry.
    private fun queryOneDirectory(
        context: Context,
        treeUri: Uri,
        parentDocId: String,
        matches: (name: String, mimeType: String) -> Boolean
    ): Pair<List<SafDocument>, List<String>>? {
        val files = mutableListOf<SafDocument>()
        val subdirIds = mutableListOf<String>()

        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        var cursor: Cursor? = null
        try {
            cursor = context.contentResolver.query(childrenUri, PROJECTION, null, null, null)
            cursor?.let { c ->
                val idCol = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeCol = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeCol = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val modCol = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)

                while (c.moveToNext()) {
                    val docId = (if (idCol >= 0) c.getString(idCol) else null) ?: continue
                    val name = (if (nameCol >= 0) c.getString(nameCol) else null) ?: ""
                    val mimeType = (if (mimeCol >= 0) c.getString(mimeCol) else null) ?: ""
                    val size = if (sizeCol >= 0) c.getLong(sizeCol) else 0L
                    val lastModified = if (modCol >= 0) c.getLong(modCol) else 0L

                    if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                        subdirIds.add(docId)
                    } else if (matches(name, mimeType)) {
                        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                        files.add(SafDocument(uri, name, mimeType, size, lastModified))
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "queryOneDirectory: query failed for $parentDocId: ${e.message}")
            return null
        } finally {
            try { cursor?.close() } catch (_: Exception) {}
        }

        return files to subdirIds
    }
}
