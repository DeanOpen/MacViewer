package io.github.whooslizi.androidviewer

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** MacViewer's Actions and Configuration menus, as one overflow menu. */
@Composable
fun SessionMenu(session: RemoteSession, showPointer: Boolean, onShowPointer: (Boolean) -> Unit, onScreenshot: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    var confirmRestart by remember { mutableStateOf(false) }
    var quality by rememberSaveable { mutableStateOf<RemoteCommand?>(null) }
    var wallpaper by rememberSaveable { mutableStateOf(true) }
    val control = !session.viewOnly

    @Composable
    fun item(label: String, checked: Boolean = false, enabled: Boolean = true, action: () -> Unit) =
        DropdownMenuItem(
            text = { Text(label) }, enabled = enabled,
            leadingIcon = { if (checked) Icon(Icons.Default.Check, contentDescription = null) },
            onClick = { open = false; action() },
        )

    @Composable
    fun heading(text: String) = Text(text, style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 8.dp))

    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Default.MoreVert, contentDescription = "More") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            heading("Actions")
            item("Send Ctrl-Alt-Delete", enabled = control) { session.command(RemoteCommand.CtrlAltDelete) }
            item("Lock remote screen", enabled = control) { session.command(RemoteCommand.Lock) }
            item("Restart remote computer…", enabled = control) { confirmRestart = true }
            item("Release pressed keys and buttons", enabled = control) { session.releaseAll() }
            item("Save screenshot") { onScreenshot() }

            if (session.monitors.size > 1) {
                HorizontalDivider()
                heading("Monitor")
                item("All monitors", checked = session.monitor == -1) { session.monitor = -1 }
                session.monitors.forEachIndexed { i, m ->
                    item("Monitor ${i + 1} · ${m.width} × ${m.height}", checked = session.monitor == i) { session.monitor = i }
                }
            }

            HorizontalDivider()
            heading("Image quality")
            for ((label, c) in listOf("Automatic" to RemoteCommand.QualityAutomatic,
                                      "Prefer speed" to RemoteCommand.QualitySpeed,
                                      "Prefer image quality" to RemoteCommand.QualityBest)) {
                item(label, checked = quality == c) { quality = c; session.command(c) }
            }

            HorizontalDivider()
            item("Show remote wallpaper", checked = wallpaper, enabled = control) {
                wallpaper = !wallpaper
                session.command(RemoteCommand.Wallpaper, if (wallpaper) 1 else 0)
            }
            item("Show remote pointer", checked = showPointer) { onShowPointer(!showPointer) }
        }
    }

    if (confirmRestart) {
        AlertDialog(
            onDismissRequest = { confirmRestart = false },
            title = { Text("Restart the remote computer?") },
            text = { Text("Unsaved work on it may be lost, and this session will end.") },
            confirmButton = {
                TextButton(onClick = { confirmRestart = false; session.command(RemoteCommand.Restart) }) { Text("Restart") }
            },
            dismissButton = { TextButton(onClick = { confirmRestart = false }) { Text("Cancel") } },
        )
    }
}
