package io.github.whooslizi.androidviewer

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.roundToInt

/** Pixels of two-finger movement per wheel step. */
private const val SCROLL_STEP_PX = 40f

/** Sticky modifiers on the key row: one tap holds it for the next key or typed letter. */
private val MODIFIERS = listOf("Ctrl" to "ControlLeft", "Alt" to "AltLeft", "Win" to "SuperLeft", "Shift" to "ShiftLeft")
private val KEYS = listOf(
    "Esc" to "Escape", "Tab" to "Tab", "←" to "ArrowLeft", "↑" to "ArrowUp", "↓" to "ArrowDown", "→" to "ArrowRight",
    "Del" to "Delete", "Home" to "Home", "End" to "End", "PgUp" to "PageUp", "PgDn" to "PageDown",
) + (1..12).map { "F$it" to "F$it" }

/** The hidden field always starts with this, so Backspace on an "empty" field is still seen. */
private const val SENTINEL = " "

@Composable
fun ViewerScreen(session: RemoteSession) {
    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var keyboard by remember { mutableStateOf(false) }
    val held = remember { mutableStateMapOf<String, Boolean>() }
    val bitmap = session.bitmap

    // Window-to-remote mapping: the screen fits the view, then the user's zoom and pan.
    fun scale(): Float {
        val b = bitmap ?: return 1f
        return minOf(viewSize.width / b.width.toFloat(), viewSize.height / b.height.toFloat()) * zoom
    }
    fun topLeft(): Offset {
        val b = bitmap ?: return Offset.Zero
        val s = scale()
        return Offset((viewSize.width - b.width * s) / 2f, (viewSize.height - b.height * s) / 2f) + pan
    }
    fun remote(p: Offset): IntOffset {
        val b = bitmap ?: return IntOffset.Zero
        val q = (p - topLeft()) / scale()
        return IntOffset(
            q.x.roundToInt().coerceIn(0, b.width - 1) + session.originX,
            q.y.roundToInt().coerceIn(0, b.height - 1) + session.originY,
        )
    }
    fun releaseModifiers() {
        for ((name, on) in held.toMap()) if (on) {
            session.key(name, false)
            held[name] = false
        }
    }

    Column(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding().imePadding()) {
        Row(
            Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(horizontal = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                if (session.viewOnly) "View only" else session.status,
                Modifier.weight(1f).padding(vertical = 12.dp), maxLines = 1,
                style = MaterialTheme.typography.bodyMedium,
            )
            TextButton(onClick = { keyboard = !keyboard }) { Text(if (keyboard) "Hide keys" else "Keyboard") }
            TextButton(onClick = { zoom = 1f; pan = Offset.Zero }) { Text("Fit") }
            TextButton(onClick = { session.disconnect() }) { Text("Disconnect") }
        }

        Box(
            Modifier.weight(1f).fillMaxWidth()
                .pointerInput(bitmap) { viewSize = size; touchGestures(session, ::remote, onZoom = { factor, centroid, move ->
                    val newZoom = (zoom * factor).coerceIn(1f, 8f)
                    // Zoom around the fingers, then follow them.
                    val s = newZoom / zoom
                    val c = centroid - Offset(viewSize.width / 2f, viewSize.height / 2f)
                    pan = (pan - c) * s + c + move
                    zoom = newZoom
                    if (zoom == 1f) pan = Offset.Zero
                }, isZoomed = { zoom > 1f }) },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                viewSize = IntSize(size.width.roundToInt(), size.height.roundToInt())
                session.frameVersion // read so every frame redraws
                val b = bitmap ?: return@Canvas
                val s = scale()
                val tl = topLeft()
                drawImage(
                    b.asImageBitmap(),
                    dstOffset = IntOffset(tl.x.roundToInt(), tl.y.roundToInt()),
                    dstSize = IntSize((b.width * s).roundToInt(), (b.height * s).roundToInt()),
                    filterQuality = if (s < 1f) FilterQuality.Medium else FilterQuality.None,
                )
            }
            if (bitmap == null) {
                Text(session.status, Modifier.padding(24.dp), color = Color.White)
            }
        }

        if (keyboard) {
            Row(
                Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)
                    .horizontalScroll(rememberScrollState()).padding(4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                for ((label, name) in MODIFIERS) {
                    FilterChip(selected = held[name] == true, label = { Text(label) }, onClick = {
                        val on = held[name] != true
                        session.key(name, on)
                        held[name] = on
                    })
                }
                for ((label, name) in KEYS) {
                    FilledTonalButton(onClick = { session.tap(name); releaseModifiers() }) { Text(label) }
                }
            }
            SoftKeyboardInput(session, modifiersHeld = { held.values.any { it } }, afterKey = ::releaseModifiers)
        }
    }
}

/**
 * The phone keyboard types into an invisible field; each edit is diffed and
 * sent: removed characters as Backspace, added ones as Unicode text (so any
 * language and IME works), newlines as Enter. With a sticky modifier held,
 * a letter or digit goes as its physical key instead, so Ctrl+C works.
 */
@Composable
private fun SoftKeyboardInput(session: RemoteSession, modifiersHeld: () -> Boolean, afterKey: () -> Unit) {
    var value by remember { mutableStateOf(TextFieldValue(SENTINEL, TextRange(SENTINEL.length))) }
    val focus = remember { FocusRequester() }
    val controller = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) {
        focus.requestFocus()
        controller?.show()
    }
    BasicTextField(
        value = value,
        onValueChange = { next ->
            val old = value.text
            val new = next.text
            val common = old.commonPrefixWith(new).length
            repeat(old.length - common) { session.tap("Backspace") }
            for (ch in new.substring(common)) when {
                ch == '\n' -> session.tap("Enter")
                modifiersHeld() && ch.isLetterOrDigit() && ch.code < 128 ->
                    session.tap(if (ch.isDigit()) "Digit$ch" else "Key${ch.uppercaseChar()}")
                else -> session.text(ch.toString())
            }
            if (old.length != common || new.length != common) afterKey()
            // Start over once nothing is being composed, keeping the sentinel.
            value = if (next.composition == null && (!new.startsWith(SENTINEL) || '\n' in new || new.length > 64)) {
                TextFieldValue(SENTINEL, TextRange(SENTINEL.length))
            } else {
                next
            }
        },
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
        modifier = Modifier.size(1.dp).focusRequester(focus),
    )
}

/**
 * Tap = left click (a quick second tap reuses the first spot, so Windows sees
 * a double-click), long press = right click, one-finger drag = left drag.
 * Two fingers pinch-zoom and pan; when not zoomed they scroll the wheel.
 */
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.touchGestures(
    session: RemoteSession,
    remote: (Offset) -> IntOffset,
    onZoom: (factor: Float, centroid: Offset, move: Offset) -> Unit,
    isZoomed: () -> Boolean,
) {
    var lastTap = 0L
    var lastTapAt = IntOffset.Zero
    awaitEachGesture {
        val down = awaitFirstDown()
        val slop = viewConfiguration.touchSlop
        val kind = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            while (true) {
                val e = awaitPointerEvent()
                if (e.changes.count { it.pressed } >= 2) return@withTimeoutOrNull "multi"
                val c = e.changes.firstOrNull { it.id == down.id } ?: return@withTimeoutOrNull "tap"
                if (!c.pressed) return@withTimeoutOrNull "tap"
                if ((c.position - down.position).getDistance() > slop) return@withTimeoutOrNull "drag"
            }
            @Suppress("UNREACHABLE_CODE")
            null
        } ?: "long"
        when (kind) {
            "tap" -> {
                val now = down.uptimeMillis
                val at = remote(down.position)
                val spot = if (now - lastTap < viewConfiguration.doubleTapTimeoutMillis) lastTapAt else at
                session.click(0, spot.x, spot.y)
                lastTap = now
                lastTapAt = spot
            }
            "long" -> {
                val at = remote(down.position)
                session.click(1, at.x, at.y)
                waitForAllUp()
            }
            "drag" -> {
                val start = remote(down.position)
                session.button(0, true, start.x, start.y)
                var last = start
                while (true) {
                    val e = awaitPointerEvent()
                    val c = e.changes.firstOrNull { it.id == down.id }
                    if (c == null || !c.pressed) break
                    last = remote(c.position)
                    session.pointer(last.x, last.y)
                    c.consume()
                }
                session.button(0, false, last.x, last.y)
            }
            "multi" -> {
                var prev: List<PointerInputChange>? = null
                var scrollCarry = 0f
                while (true) {
                    val e = awaitPointerEvent()
                    val pressed = e.changes.filter { it.pressed }
                    if (pressed.size < 2) {
                        if (pressed.isEmpty()) break
                        prev = null
                        continue
                    }
                    val centroid = pressed.fold(Offset.Zero) { a, c -> a + c.position } / pressed.size.toFloat()
                    val span = pressed.map { (it.position - centroid).getDistance() }.average().toFloat()
                    val p = prev
                    if (p != null && p.size == pressed.size) {
                        val pc = p.fold(Offset.Zero) { a, c -> a + c.position } / p.size.toFloat()
                        val ps = p.map { (it.position - pc).getDistance() }.average().toFloat()
                        val factor = if (ps > 0f) span / ps else 1f
                        val move = centroid - pc
                        if (!isZoomed() && abs(factor - 1f) < 0.02f) {
                            // Not zoomed and not pinching: two-finger swipe scrolls.
                            scrollCarry += move.y
                            val steps = (scrollCarry / SCROLL_STEP_PX).toInt()
                            if (steps != 0) {
                                session.scroll(steps.toDouble())
                                scrollCarry -= steps * SCROLL_STEP_PX
                            }
                        } else {
                            onZoom(factor, centroid, move)
                        }
                    }
                    prev = pressed.map { it }
                    pressed.forEach { it.consume() }
                }
            }
        }
    }
}

private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.waitForAllUp() {
    while (awaitPointerEvent().changes.any { it.pressed }) Unit
}
