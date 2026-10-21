package io.github.whooslizi.androidviewer

/** The Rust bridge in core/src/lib.rs (LinuxViewer's UltraViewer protocol core). */
object Native {
    init {
        System.loadLibrary("androidviewer")
    }

    /** Starts connecting; throws IllegalStateException with a readable message on bad input. */
    external fun connect(configDir: String, id: String, password: String, width: Int, height: Int): Long

    /** Next event as tab-separated text, or null after [timeoutMs]. See lib.rs for the formats. */
    external fun nextEvent(handle: Long, timeoutMs: Int): String?

    /** Copies the screen as ARGB into [pixels] (width*height); false if the size differs. */
    external fun copyFrame(handle: Long, pixels: IntArray): Boolean

    external fun pointer(handle: Long, x: Int, y: Int)

    /** [button]: 0 left, 1 right, 2 middle. */
    external fun button(handle: Long, button: Int, pressed: Boolean, x: Int, y: Int)

    /** Wheel steps, positive = up. */
    external fun scroll(handle: Long, lines: Double)

    external fun text(handle: Long, text: String)

    /** [name] is a physical key such as "Escape", "ControlLeft" or "ArrowUp". */
    external fun key(handle: Long, name: String, pressed: Boolean)

    external fun disconnect(handle: Long)

    external fun free(handle: Long)
}
