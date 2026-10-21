package io.github.whooslizi.androidviewer

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.provider.MediaStore
import androidx.compose.ui.unit.IntRect
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

/**
 * Saves [region] of the remote screen as a PNG in Pictures/AndroidViewer. The copy
 * is taken now, on the main thread; encoding runs in the background and [done] gets a message.
 */
fun saveScreenshot(context: Context, screen: Bitmap, region: IntRect, done: (String) -> Unit) {
    val copy = Bitmap.createBitmap(screen, region.left, region.top, region.width, region.height)
    val name = "AndroidViewer " + SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date()) + ".png"
    // The application context: the Activity may be gone before encoding finishes.
    val app = context.applicationContext
    val text = app.localized()
    val resolver = app.contentResolver
    thread {
        var uri: Uri? = null
        val message = runCatching {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/AndroidViewer")
                put(MediaStore.Images.Media.IS_PENDING, 1) // hidden from the gallery until written
            }
            val target = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: error("the photo library is unavailable")
            uri = target
            resolver.openOutputStream(target).use { out ->
                check(out != null && copy.compress(Bitmap.CompressFormat.PNG, 100, out)) { "could not write the image" }
            }
            resolver.update(target, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            text.getString(R.string.screenshot_saved)
        }.getOrElse { error ->
            uri?.let { resolver.delete(it, null, null) }
            text.getString(R.string.screenshot_failed, error.message)
        }
        if (copy !== screen) copy.recycle()
        Handler(app.mainLooper).post { done(message) }
    }
}
