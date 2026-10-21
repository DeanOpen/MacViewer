package io.github.whooslizi.androidviewer

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * One connection. Events are read on a background thread; every other native
 * call, and the final free, happens on the main thread, so input can never
 * touch a freed handle.
 */
class RemoteSession(private val handle: Long, private val onClosed: (String) -> Unit) {
    var status by mutableStateOf("Connecting…")
        private set
    var viewOnly by mutableStateOf(false)
        private set
    var bitmap by mutableStateOf<Bitmap?>(null)
        private set
    /** Bumped on every frame so the canvas redraws. */
    var frameVersion by mutableIntStateOf(0)
        private set
    /** Top-left of the remote desktop in Windows coordinates (multi-monitor). */
    var originX = 0
        private set
    var originY = 0
        private set

    private val main = Handler(Looper.getMainLooper())
    private val framePending = AtomicBoolean(false)
    private var pixels = IntArray(0)
    private var freed = false

    fun start() {
        thread(name = "uv-events", isDaemon = true) {
            while (true) {
                val event = Native.nextEvent(handle, 250) ?: continue
                val f = event.split('\t')
                when (f[0]) {
                    "status" -> main.post { status = f.getOrElse(1) { "" } }
                    "connected" -> main.post {
                        val (w, h) = f[1].toInt() to f[2].toInt()
                        originX = f[3].toInt()
                        originY = f[4].toInt()
                        if (bitmap?.width != w || bitmap?.height != h) {
                            bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            pixels = IntArray(w * h)
                        }
                        status = "Connected ${w}×$h"
                        copyFrame()
                    }
                    // Frames arrive faster than the screen redraws: copy at most one per main-loop turn.
                    "frame" -> if (framePending.compareAndSet(false, true)) main.post {
                        framePending.set(false)
                        copyFrame()
                    }
                    "viewonly" -> main.post { viewOnly = f.getOrElse(1) { "0" } == "1" }
                    "closed" -> {
                        main.post {
                            freed = true
                            Native.free(handle)
                            onClosed(f.getOrElse(1) { "The session ended." })
                        }
                        return@thread
                    }
                }
            }
        }
    }

    private fun copyFrame() {
        val b = bitmap ?: return
        if (freed || !Native.copyFrame(handle, pixels)) return
        b.setPixels(pixels, 0, b.width, 0, 0, b.width, b.height)
        frameVersion++
    }

    private inline fun send(block: (Long) -> Unit) {
        if (!freed && !viewOnly) block(handle)
    }

    fun pointer(x: Int, y: Int) = send { Native.pointer(it, x, y) }
    fun button(button: Int, pressed: Boolean, x: Int, y: Int) = send { Native.button(it, button, pressed, x, y) }
    fun click(button: Int, x: Int, y: Int) {
        this.button(button, true, x, y)
        this.button(button, false, x, y)
    }
    fun scroll(lines: Double) = send { Native.scroll(it, lines) }
    fun text(text: String) = send { Native.text(it, text) }
    fun key(name: String, pressed: Boolean) = send { Native.key(it, name, pressed) }
    fun tap(name: String) {
        key(name, true)
        key(name, false)
    }

    fun disconnect() {
        if (!freed) Native.disconnect(handle)
    }
}
