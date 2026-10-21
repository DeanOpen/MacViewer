package io.github.whooslizi.androidviewer

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

/** Sticky modifiers: one tap holds it for the next key or typed letter. */
private val MODIFIERS = listOf("Ctrl" to "ControlLeft", "Alt" to "AltLeft", "Win" to "SuperLeft", "Shift" to "ShiftLeft")
private val KEYS = listOf(
    "Esc" to "Escape", "Tab" to "Tab", "←" to "ArrowLeft", "↑" to "ArrowUp", "↓" to "ArrowDown", "→" to "ArrowRight",
    "Del" to "Delete", "Home" to "Home", "End" to "End", "PgUp" to "PageUp", "PgDn" to "PageDown",
) + (1..12).map { "F$it" to "F$it" }

/** The hidden field always starts with this, so Backspace on an "empty" field is still seen. */
private const val SENTINEL = " "

/** The key row plus the phone keyboard, which opens with it. */
@Composable
fun KeyboardBar(session: RemoteSession) {
    val held = remember { mutableStateMapOf<String, Boolean>() }
    fun releaseModifiers() {
        for ((name, on) in held.toMap()) if (on) {
            session.key(name, false)
            held[name] = false
        }
    }
    // Closing the bar must not leave Ctrl, Alt, Win or Shift held down on Windows.
    DisposableEffect(session) { onDispose(::releaseModifiers) }
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface)) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(4.dp),
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
            val edit = TextEdit.between(value.text, next.text)
            repeat(edit.deleted) { session.tap("Backspace") }
            for (ch in edit.inserted) when {
                ch == '\n' -> session.tap("Enter")
                modifiersHeld() && ch.isLetterOrDigit() && ch.code < 128 ->
                    session.tap(if (ch.isDigit()) "Digit$ch" else "Key${ch.uppercaseChar()}")
                else -> session.text(ch.toString())
            }
            if (edit.deleted > 0 || edit.inserted.isNotEmpty()) afterKey()
            // Start over once nothing is being composed, keeping the sentinel.
            val n = next.text
            value = if (next.composition == null && (!n.startsWith(SENTINEL) || '\n' in n || n.length > 64)) {
                TextFieldValue(SENTINEL, TextRange(SENTINEL.length))
            } else {
                next
            }
        },
        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
        modifier = Modifier.size(1.dp).focusRequester(focus),
    )
}

/** An edit as "delete this many characters from the end, then type this". */
data class TextEdit(val deleted: Int, val inserted: String) {
    companion object {
        fun between(old: String, new: String): TextEdit {
            val common = old.commonPrefixWith(new).length
            return TextEdit(old.length - common, new.substring(common))
        }
    }
}
