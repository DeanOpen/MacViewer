package io.github.whooslizi.androidviewer

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File

data class Transfer(val id: String, val name: String, val size: Long, val incoming: Boolean, val file: File, val bytes: Long = 0)

fun transferRoot(context: Context) = File(context.cacheDir, "transfers")

/** Offered names come from the remote computer: never let one be a path. */
fun safeFileName(name: String): String =
    name.substringAfterLast('/').substringAfterLast('\\').takeUnless { it.isBlank() || it == "." || it == ".." } ?: "file"

/** The core sends from a file path, so a picked document is copied into [dir] first. */
fun copyToCache(context: Context, uri: Uri, dir: File): File {
    val resolver = context.contentResolver
    val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { if (it.moveToFirst()) it.getString(0) else null }
    dir.mkdirs()
    val file = File(dir, safeFileName(name ?: "file"))
    val input = resolver.openInputStream(uri) ?: error("the file could not be opened")
    input.use { i -> file.outputStream().use { i.copyTo(it) } }
    return file
}

fun saveToDownloads(context: Context, file: File) {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, file.name)
        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/AndroidViewer")
        put(MediaStore.Downloads.IS_PENDING, 1)
    }
    val target = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        ?: error("the Downloads folder is unavailable")
    try {
        resolver.openOutputStream(target).use { out ->
            checkNotNull(out) { "could not write the file" }
            file.inputStream().use { it.copyTo(out) }
        }
        resolver.update(target, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
    } catch (e: Exception) {
        resolver.delete(target, null, null)
        throw e
    }
}
