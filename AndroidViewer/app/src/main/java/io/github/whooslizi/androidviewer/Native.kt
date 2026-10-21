package io.github.whooslizi.androidviewer

import android.graphics.Bitmap

/** The Rust bridge in core/src/lib.rs. */
object Native {
    init {
        System.loadLibrary("androidviewer")
    }

    /**
     * Starts connecting; throws IllegalStateException with a readable message on bad input.
     * [name] is what the Windows side shows for this phone; [width]×[height] is its screen.
     */
    external fun connect(configDir: String, name: String, id: String, password: String, width: Int, height: Int): Long

    /** Next event as tab-separated text (see [SessionEvent.parse]), or null after [timeoutMs]. */
    external fun nextEvent(handle: Long, timeoutMs: Int): String?

    /** Draws the screen into [target], a mutable ARGB_8888 bitmap of its size; false if not possible. */
    external fun copyFrame(handle: Long, target: Bitmap): Boolean

    /** The pointer shape as [width, height, hotX, hotY, ARGB pixels…]. */
    external fun cursorShape(handle: Long): IntArray?

    external fun pointer(handle: Long, x: Int, y: Int)

    /** [button]: 0 left, 1 right, 2 middle. */
    external fun button(handle: Long, button: Int, pressed: Boolean, x: Int, y: Int)

    /** Wheel steps, positive = up. */
    external fun scroll(handle: Long, lines: Double)

    external fun text(handle: Long, text: String)

    /** [name] is a physical key such as "Escape", "ControlLeft" or "ArrowUp". */
    external fun key(handle: Long, name: String, pressed: Boolean)

    external fun releaseAll(handle: Long)

    external fun command(handle: Long, name: String, value: Int)

    external fun disconnect(handle: Long)

    external fun free(handle: Long)
}

/** Actions need control; image quality also works view-only. */
enum class RemoteCommand(val wire: String, val needsControl: Boolean) {
    CtrlAltDelete("ctrl-alt-delete", true),
    Lock("lock", true),
    Restart("restart", true),
    QualityAutomatic("quality-automatic", false),
    QualitySpeed("quality-speed", false),
    QualityBest("quality-quality", false),
    Wallpaper("wallpaper", true),
}
