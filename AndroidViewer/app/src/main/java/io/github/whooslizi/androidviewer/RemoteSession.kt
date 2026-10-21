package io.github.whooslizi.androidviewer

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.Resources
import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.IntRect
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** The remote pointer: its shape and where its tip is, in canvas pixels. */
data class RemotePointer(val bitmap: Bitmap, val hotX: Int, val hotY: Int, val x: Int, val y: Int)

data class ChatLine(val mine: Boolean, val text: String)

private const val AUDIO_RATE = 48_000

/**
 * One connection. Events are read on a background thread; every other native
 * call, and the final free, happens on the main thread, so input can never
 * touch a freed handle.
 */
class RemoteSession(
    private val handle: Long,
    private val app: Context,
    /** In the app language, for the status line and messages. */
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
    /** Read by the poll thread too. */
    var sound by mutableStateOf(false)
        private set
    var clipboardSharing by mutableStateOf(false)
        private set
    val chat = mutableStateListOf<ChatLine>()
    var partnerTyping by mutableStateOf(false)
        private set
    var unreadChat by mutableIntStateOf(0)
        private set
    var chatOpen by mutableStateOf(false)
        private set
    val transfers = mutableStateListOf<Transfer>()
    val offers = mutableStateListOf<SessionEvent.FileOffer>()

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
            // Sound plays on this thread: it may call the core for as long as the handle lives.
            var track: AudioTrack? = null
            val pcm = ShortArray(AUDIO_RATE / 10)
            while (true) {
                val event = Native.nextEvent(handle, 250)?.let(SessionEvent::parse)
                if (!sound && track != null) {
                    track.release()
                    track = null
                }
                when (event) {
                    null -> Unit
                    SessionEvent.Audio -> if (sound) {
                        val t = track ?: newAudioTrack().also { track = it }
                        while (true) {
                            val n = Native.readAudio(handle, pcm)
                            if (n == 0) break
                            t.write(pcm, 0, n, AudioTrack.WRITE_NON_BLOCKING)
                        }
                    }
                    // Frames arrive faster than the screen redraws: copy at most one per main-loop turn.
                    SessionEvent.Frame -> if (framePending.compareAndSet(false, true)) main.post {
                        framePending.set(false)
                        copyFrame()
                    }
                    is SessionEvent.Closed -> {
                        track?.release()
                        main.post {
                            freed = true
                            Native.free(handle)
                            transfers.forEach { it.file.parentFile?.deleteRecursively() }
                            onClosed(event.reason)
                        }
                        return@thread
                    }
                    else -> main.post { apply(event) }
                }
            }
        }
    }

    private fun newAudioTrack(): AudioTrack {
        val format = AudioFormat.Builder().setSampleRate(AUDIO_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
        val min = AudioTrack.getMinBufferSize(AUDIO_RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(format)
            .setBufferSizeInBytes(maxOf(min, AUDIO_RATE)) // 250 ms, like the core's queue
            .build()
            .apply { play() }
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
            is SessionEvent.Chat -> {
                chat += ChatLine(mine = false, event.text)
                partnerTyping = false
                if (!chatOpen) {
                    unreadChat++
                    toast(text.getString(R.string.chat_from_partner, event.text))
                }
            }
            is SessionEvent.Typing -> partnerTyping = event.on
            is SessionEvent.Clipboard -> clipboard().setPrimaryClip(ClipData.newPlainText("UltraViewer", event.text))
            is SessionEvent.FileOffer -> offers += event
            is SessionEvent.FileProgress -> {
                val i = transfers.indexOfFirst { it.id == event.id }
                if (i >= 0) transfers[i] = transfers[i].copy(bytes = event.bytes)
            }
            is SessionEvent.FileDone -> finished(event.id)?.let { t ->
                if (!t.incoming) {
                    t.file.parentFile?.deleteRecursively()
                    toast(text.getString(R.string.file_sent, t.name))
                } else thread {
                    val message = runCatching { saveToDownloads(app, t.file) }.fold(
                        { text.getString(R.string.file_saved, t.name) },
                        { text.getString(R.string.file_failed, t.name, it.message) },
                    )
                    t.file.parentFile?.deleteRecursively()
                    main.post { toast(message) }
                }
            }
            is SessionEvent.FileCanceled -> {
                offers.removeAll { it.id == event.id }
                finished(event.id)?.let {
                    it.file.parentFile?.deleteRecursively()
                    toast(text.getString(R.string.file_canceled, it.name))
                }
            }
            is SessionEvent.FileFailed -> {
                offers.removeAll { it.id == event.id }
                finished(event.id)?.let {
                    it.file.parentFile?.deleteRecursively()
                    toast(text.getString(R.string.file_failed, it.name, event.reason))
                }
            }
            SessionEvent.Frame, SessionEvent.Audio, is SessionEvent.Closed -> Unit
        }
    }

    private fun finished(id: String): Transfer? =
        transfers.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.let { transfers.removeAt(it) }

    private fun clipboard() = app.getSystemService(ClipboardManager::class.java)

    private fun toast(message: String) = Toast.makeText(app, message, Toast.LENGTH_SHORT).show()

    /** Runs a core call that may throw; its message is shown and null returned. */
    private inline fun <T> attempt(block: () -> T): T? {
        if (freed) return null
        return try {
            block()
        } catch (e: IllegalStateException) {
            toast(e.message.orEmpty())
            null
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

    fun toggleSound() {
        sound = !sound
        command(RemoteCommand.Sound, if (sound) 1 else 0)
    }

    fun toggleClipboardSharing() {
        clipboardSharing = !clipboardSharing
        command(RemoteCommand.ClipboardSharing, if (clipboardSharing) 1 else 0)
    }

    fun showChat(show: Boolean) {
        chatOpen = show
        if (show) unreadChat = 0
    }

    fun sendChat(message: String) {
        if (attempt { Native.sendChat(handle, message) } != null) chat += ChatLine(mine = true, message)
    }

    fun sendPhoneClipboard() {
        val clip = clipboard().primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(app)?.toString()
        if (clip.isNullOrEmpty()) return toast(text.getString(R.string.clipboard_empty))
        if (attempt { Native.sendClipboard(handle, clip) } != null) toast(text.getString(R.string.clipboard_sent))
    }

    fun sendFile(uri: Uri) {
        val dir = File(transferRoot(app), UUID.randomUUID().toString())
        thread {
            val copied = runCatching { copyToCache(app, uri, dir) }
            main.post {
                val file = copied.getOrNull()
                val id = file?.let { attempt { Native.sendFile(handle, it.path) } }
                if (file != null && id != null) {
                    transfers += Transfer(id, file.name, file.length(), incoming = false, file)
                } else {
                    dir.deleteRecursively()
                    copied.exceptionOrNull()?.let { toast(text.getString(R.string.file_failed, uri.lastPathSegment, it.message)) }
                }
            }
        }
    }

    fun accept(offer: SessionEvent.FileOffer) {
        offers.remove(offer)
        val dir = File(transferRoot(app), offer.id).apply { deleteRecursively(); mkdirs() }
        val file = File(dir, safeFileName(offer.name))
        if (attempt { Native.acceptFile(handle, offer.id, file.path) } != null) {
            transfers += Transfer(offer.id, offer.name, offer.size, incoming = true, file)
        } else {
            dir.deleteRecursively()
        }
    }

    fun decline(offer: SessionEvent.FileOffer) {
        offers.remove(offer)
        attempt { Native.cancelFile(handle, offer.id) }
    }

    /** The core reports no event for a cancel from this side, so the transfer is dropped here. */
    fun cancel(transfer: Transfer) {
        attempt { Native.cancelFile(handle, transfer.id) }
        finished(transfer.id)?.file?.parentFile?.deleteRecursively()
    }

    fun disconnect() {
        if (!freed) Native.disconnect(handle)
    }
}
