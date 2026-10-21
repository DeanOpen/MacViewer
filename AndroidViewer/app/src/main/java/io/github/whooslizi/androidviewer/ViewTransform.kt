package io.github.whooslizi.androidviewer

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import kotlin.math.roundToInt

/**
 * Places [view] (a region of the remote canvas: everything, or one monitor) in a
 * [windowW]×[windowH] area: fitted and centred, then the user's [zoom] and [pan].
 */
data class ViewTransform(
    val windowW: Float,
    val windowH: Float,
    val view: IntRect,
    val zoom: Float = 1f,
    val pan: Offset = Offset.Zero,
) {
    val scale: Float get() = minOf(windowW / view.width, windowH / view.height) * zoom

    val topLeft: Offset get() =
        Offset((windowW - view.width * scale) / 2f, (windowH - view.height * scale) / 2f) + pan

    /** Window point to a canvas pixel inside [view]. */
    fun toCanvas(p: Offset): IntOffset {
        val q = (p - topLeft) / scale
        return IntOffset(
            (q.x.roundToInt() + view.left).coerceIn(view.left, view.right - 1),
            (q.y.roundToInt() + view.top).coerceIn(view.top, view.bottom - 1),
        )
    }

    /** Canvas point to window coordinates. */
    fun toWindow(x: Float, y: Float): Offset = Offset(x - view.left, y - view.top) * scale + topLeft

    /**
     * Pinch by [factor] around [centroid] and move by [move]; the point under the
     * fingers stays put, but the screen never leaves the window.
     */
    fun pinched(factor: Float, centroid: Offset, move: Offset): ViewTransform {
        val newZoom = (zoom * factor).coerceIn(1f, MAX_ZOOM)
        val c = centroid - Offset(windowW / 2f, windowH / 2f)
        return copy(zoom = newZoom, pan = (pan - c) * (newZoom / zoom) + c + move).clamped()
    }

    /** Pan limited so a zoomed screen still covers the window (and a smaller one stays centred). */
    private fun clamped(): ViewTransform {
        val limitX = maxOf(0f, (view.width * scale - windowW) / 2f)
        val limitY = maxOf(0f, (view.height * scale - windowH) / 2f)
        return copy(pan = Offset(pan.x.coerceIn(-limitX, limitX), pan.y.coerceIn(-limitY, limitY)))
    }

    companion object {
        const val MAX_ZOOM = 8f
    }
}
