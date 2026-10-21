package io.github.whooslizi.androidviewer

import android.content.res.Resources
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.IntRect
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** The remote pointer: its shape and where its tip is, in canvas pixels. */
data class RemotePointer(val bitmap: Bitmap, val hotX: Int, val hotY: Int, val x: Int, val y: Int)

/**
 * One connection. Events are read on a background thread; every other native
 * call, and the final free, happens on the main thread, so input can never
 * touch a freed handle.
 */
class RemoteSession(
    private val handle: Long,
    /** In the app language, for the status line. */
    private val text: Resources,
    private val onConnected: () -> Unit,
    private val onClosed: (String) -> Unit,
) {
    var status by mutableStateOf(text.getString(R.string.connecting))
        private set
    var viewOnly by mutableStateOf(false)
        private set
    var bitmap by mutableStateOf<Bitmap?>(null)
        private set
    /** Bumped on every frame so the canvas redraws. */
    var frameVersion by mutableIntStateOf(0)
        private set
    var monitors by mutableStateOf(emptyList<Monitor>())
        private set
    /** Index into [monitors], or -1 for all of them. */
    var monitor by mutableIntStateOf(-1)
    var pointer by mutableStateOf<RemotePointer?>(null)
        private set

    /** Top-left of the remote desktop in Windows coordinates (multi-monitor). */
    private var originX = 0
    private var originY = 0
    private var shapeBitmap: Bitmap? = null
    private var shapeKey: String? = null
    private var hotX = 0
    private var hotY = 0
    private var connectedOnce = false

    private val main = Handler(Looper.getMainLooper())
    private val framePending = AtomicBoolean(false)
    private var freed = false

    fun start() {
        thread(name = "uv-events", isDaemon = true) {
            while (true) {
                val event = SessionEvent.parse(Native.nextEvent(handle, 250) ?: continue) ?: continue
                when (event) {
                    // Frames arrive faster than the screen redraws: copy at most one per main-loop turn.
                    SessionEvent.Frame -> if (framePending.compareAndSet(false, true)) main.post {
                        framePending.set(false)
                        copyFrame()
                    }
                    is SessionEvent.Closed -> {
                        main.post {
                            freed = true
                            Native.free(handle)
                            onClosed(event.reason)
                        }
                        return@thread
                    }
                    else -> main.post { apply(event) }
                }
            }
        }
    }

    private fun apply(event: SessionEvent) {
        when (event) {
            is SessionEvent.Status -> status = event.text
            is SessionEvent.Connected -> {
                originX = event.originX
                originY = event.originY
                if (bitmap?.width != event.width || bitmap?.height != event.height) {
                    bitmap = Bitmap.createBitmap(event.width, event.height, Bitmap.Config.ARGB_8888)
                }
                // A re-init without monitor metadata keeps the previous list.
                if (event.monitors.isNotEmpty()) monitors = event.monitors
                if (monitor >= monitors.size) monitor = -1
                status = text.getString(R.string.connected_size, event.width, event.height)
                copyFrame()
                if (!connectedOnce) {
                    connectedOnce = true
                    onConnected()
                }
            }
            is SessionEvent.Cursor -> updatePointer(event)
            is SessionEvent.ViewOnly -> {
                // Forget held keys and buttons, so the encoder matches Windows again.
                if (event.on && !freed) Native.releaseAll(handle)
                viewOnly = event.on
            }
            SessionEvent.Frame, is SessionEvent.Closed -> Unit
        }
    }

    private fun updatePointer(event: SessionEvent.Cursor) {
        if (freed) return
        // The key changes when a new shape is selected or its image arrives.
        if (shapeBitmap == null || event.shape != shapeKey) {
            shapeKey = event.shape
            val s = Native.cursorShape(handle)
            if (s != null && s.size >= 4 && s[0] > 0 && s[1] > 0 && s.size >= 4 + s[0] * s[1]) {
                shapeBitmap = Bitmap.createBitmap(s, 4, s[0], s[0], s[1], Bitmap.Config.ARGB_8888)
                hotX = s[2]
                hotY = s[3]
            }
        }
        val b = shapeBitmap ?: return
        val (x, y) = (event.x ?: return) to (event.y ?: return)
        pointer = RemotePointer(b, hotX, hotY, x - originX, y - originY)
    }

    private fun copyFrame() {
        val b = bitmap ?: return
        if (!freed && Native.copyFrame(handle, b)) frameVersion++
    }

    /** The canvas region to show: everything, or the selected monitor. */
    fun viewRect(): IntRect? {
        val b = bitmap ?: return null
        val all = IntRect(0, 0, b.width, b.height)
        val m = monitors.getOrNull(monitor) ?: return all
        val r = IntRect(m.left - originX, m.top - originY, m.right - originX, m.bottom - originY)
        // A monitor outside the received image falls back to all monitors.
        return if (r.left >= 0 && r.top >= 0 && r.right <= b.width && r.bottom <= b.height) r else all
    }

    private inline fun send(block: (Long) -> Unit) {
        if (!freed && !viewOnly) block(handle)
    }

    // Input takes canvas coordinates; the wire uses virtual-desktop ones.
    fun pointer(x: Int, y: Int) = send { Native.pointer(it, x + originX, y + originY) }
    fun button(button: Int, pressed: Boolean, x: Int, y: Int) =
        send { Native.button(it, button, pressed, x + originX, y + originY) }
    fun click(button: Int, x: Int, y: Int) {
        button(button, true, x, y)
        button(button, false, x, y)
    }
    fun scroll(lines: Double) = send { Native.scroll(it, lines) }
    fun text(text: String) = send { Native.text(it, text) }
    fun key(name: String, pressed: Boolean) = send { Native.key(it, name, pressed) }
    fun tap(name: String) {
        key(name, true)
        key(name, false)
    }
    fun releaseAll() = send { Native.releaseAll(it) }
    fun command(c: RemoteCommand, value: Int = 0) {
        if (!freed && !(c.needsControl && viewOnly)) Native.command(handle, c.wire, value)
    }

    fun disconnect() {
        if (!freed) Native.disconnect(handle)
    }
}
