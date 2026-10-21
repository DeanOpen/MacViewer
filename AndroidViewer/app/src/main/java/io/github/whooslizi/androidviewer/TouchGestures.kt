package io.github.whooslizi.androidviewer

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.unit.IntOffset
import kotlin.math.abs

/** Pixels of two-finger movement per wheel step. */
private const val SCROLL_STEP_PX = 40f

/** A spread change beyond this (8 %) makes a two-finger gesture a pinch. */
private const val PINCH_THRESHOLD = 0.08f

/** A second tap this many touch slops from the first still counts as its double-click. */
private const val DOUBLE_TAP_SLOP = 3

/**
 * Tap = left click (a quick second tap reuses the first spot, so Windows sees
 * a double-click), long press = right click, one-finger drag = left drag.
 * Two fingers pinch-zoom and pan; when not zoomed they scroll the wheel.
 * [toCanvas] maps a touch to remote canvas pixels.
 */
suspend fun PointerInputScope.remoteTouchGestures(
    session: RemoteSession,
    toCanvas: (Offset) -> IntOffset,
    onPinch: (factor: Float, centroid: Offset, move: Offset) -> Unit,
    isZoomed: () -> Boolean,
) {
    var lastTap = 0L
    var lastTapTouch = Offset.Zero
    var lastTapAt = IntOffset.Zero
    awaitEachGesture {
        val down = awaitFirstDown()
        when (classify(down)) {
            Gesture.Tap -> {
                // Windows needs both clicks of a double-click within a few pixels; fingers aren't that exact.
                val again = down.uptimeMillis - lastTap < viewConfiguration.doubleTapTimeoutMillis &&
                    (down.position - lastTapTouch).getDistance() < viewConfiguration.touchSlop * DOUBLE_TAP_SLOP
                val spot = if (again) lastTapAt else toCanvas(down.position)
                session.click(0, spot.x, spot.y)
                lastTap = down.uptimeMillis
                lastTapTouch = down.position
                lastTapAt = spot
            }
            Gesture.LongPress -> {
                val at = toCanvas(down.position)
                session.click(1, at.x, at.y)
                while (awaitPointerEvent().changes.any { it.pressed }) Unit
            }
            Gesture.Drag -> {
                var last = toCanvas(down.position)
                session.button(0, true, last.x, last.y)
                while (true) {
                    val c = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                    if (c == null || !c.pressed) break
                    last = toCanvas(c.position)
                    session.pointer(last.x, last.y)
                    c.consume()
                }
                session.button(0, false, last.x, last.y)
            }
            Gesture.TwoFingers -> twoFingers(session, onPinch, isZoomed)
        }
    }
}

private enum class Gesture { Tap, LongPress, Drag, TwoFingers }

/** Watches the first finger until it lifts, moves, holds or a second one lands. */
private suspend fun AwaitPointerEventScope.classify(down: PointerInputChange): Gesture =
    withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
        while (true) {
            val e = awaitPointerEvent()
            if (e.changes.count { it.pressed } >= 2) return@withTimeoutOrNull Gesture.TwoFingers
            val c = e.changes.firstOrNull { it.id == down.id }
            if (c == null || !c.pressed) return@withTimeoutOrNull Gesture.Tap
            if ((c.position - down.position).getDistance() > viewConfiguration.touchSlop) return@withTimeoutOrNull Gesture.Drag
        }
        @Suppress("UNREACHABLE_CODE")
        null
    } ?: Gesture.LongPress

enum class TwoFingerMode { Pinch, Scroll }

/**
 * Decides once per gesture what two fingers do, from the spread change and
 * travel so far; null while undecided. When zoomed, moving pans (a pinch).
 */
fun twoFingerMode(spreadRatio: Float, travel: Offset, zoomed: Boolean, slop: Float): TwoFingerMode? = when {
    abs(spreadRatio - 1f) > PINCH_THRESHOLD -> TwoFingerMode.Pinch
    travel.getDistance() > slop -> if (zoomed) TwoFingerMode.Pinch else TwoFingerMode.Scroll
    else -> null
}

private suspend fun AwaitPointerEventScope.twoFingers(
    session: RemoteSession,
    onPinch: (factor: Float, centroid: Offset, move: Offset) -> Unit,
    isZoomed: () -> Boolean,
) {
    var prev: List<Offset>? = null
    var mode: TwoFingerMode? = null
    var startSpread = 0f
    var travel = Offset.Zero
    var scrollCarry = 0f
    while (true) {
        val pressed = awaitPointerEvent().changes.filter { it.pressed }
        if (pressed.isEmpty()) break
        val points = pressed.map { it.position }
        val p = prev
        if (points.size >= 2 && p != null && p.size == points.size) {
            val (centroid, spread) = centroidAndSpread(points)
            val (prevCentroid, prevSpread) = centroidAndSpread(p)
            val move = centroid - prevCentroid
            if (mode == null) {
                if (startSpread == 0f) startSpread = prevSpread
                travel += move
                mode = twoFingerMode(if (startSpread > 0f) spread / startSpread else 1f, travel, isZoomed(),
                                     viewConfiguration.touchSlop)
            }
            when (mode) {
                TwoFingerMode.Pinch -> onPinch(if (prevSpread > 0f) spread / prevSpread else 1f, centroid, move)
                TwoFingerMode.Scroll -> {
                    // Fingers down = content down = wheel up, as on a touchscreen.
                    scrollCarry += move.y
                    val steps = (scrollCarry / SCROLL_STEP_PX).toInt()
                    if (steps != 0) {
                        session.scroll(steps.toDouble())
                        scrollCarry -= steps * SCROLL_STEP_PX
                    }
                }
                null -> Unit
            }
        }
        prev = points.takeIf { it.size >= 2 }
        pressed.forEach { it.consume() }
    }
}

private fun centroidAndSpread(points: List<Offset>): Pair<Offset, Float> {
    val c = points.fold(Offset.Zero) { a, p -> a + p } / points.size.toFloat()
    return c to points.map { (it - c).getDistance() }.average().toFloat()
}
