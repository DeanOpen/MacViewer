package io.github.whooslizi.androidviewer

/** A monitor in Windows virtual-desktop coordinates. */
data class Monitor(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width get() = right - left
    val height get() = bottom - top
}

/** Events from Native.nextEvent; the text format is documented in core/src/lib.rs. */
sealed interface SessionEvent {
    data class Status(val text: String) : SessionEvent
    data class Connected(val width: Int, val height: Int, val originX: Int, val originY: Int,
                         val monitors: List<Monitor>) : SessionEvent
    data object Frame : SessionEvent
    /** Position in virtual-desktop coordinates (null until the host sends one); [shape] null = arrow. */
    data class Cursor(val x: Int?, val y: Int?, val shape: String?) : SessionEvent
    data class ViewOnly(val on: Boolean) : SessionEvent
    data object Audio : SessionEvent
    data class Chat(val text: String) : SessionEvent
    data class Typing(val on: Boolean) : SessionEvent
    data class Clipboard(val text: String) : SessionEvent
    data class FileOffer(val id: String, val size: Long, val name: String) : SessionEvent
    data class FileProgress(val id: String, val bytes: Long) : SessionEvent
    data class FileDone(val id: String) : SessionEvent
    data class FileCanceled(val id: String) : SessionEvent
    data class FileFailed(val id: String, val reason: String) : SessionEvent
    data class Closed(val reason: String) : SessionEvent

    companion object {
        fun parse(line: String): SessionEvent? {
            val f = line.split('\t')
            fun at(i: Int) = f.getOrElse(i) { "" }
            fun rest(i: Int) = f.drop(i).joinToString("\t")
            return when (f[0]) {
                "status" -> Status(at(1))
                "connected" -> Connected(
                    at(1).toInt(), at(2).toInt(), at(3).toInt(), at(4).toInt(),
                    at(5).split(';').mapNotNull { m ->
                        m.split(',').mapNotNull(String::toIntOrNull).takeIf { it.size == 4 }
                            ?.let { (l, t, r, b) -> Monitor(l, t, r, b) }
                    },
                )
                "frame" -> Frame
                "cursor" -> Cursor(at(1).toIntOrNull(), at(2).toIntOrNull(), at(3).takeIf { it != "-" && it.isNotEmpty() })
                "viewonly" -> ViewOnly(at(1) == "1")
                "audio" -> Audio
                "chat" -> Chat(rest(1))
                "typing" -> Typing(at(1) == "1")
                "clipboard" -> Clipboard(rest(1))
                "fileoffer" -> FileOffer(at(1), at(2).toLongOrNull() ?: 0, rest(3))
                "fileprogress" -> FileProgress(at(1), at(2).toLongOrNull() ?: 0)
                "filedone" -> FileDone(at(1))
                "filecanceled" -> FileCanceled(at(1))
                "filefailed" -> FileFailed(at(1), rest(2))
                "closed" -> Closed(at(1))
                else -> null
            }
        }
    }
}
