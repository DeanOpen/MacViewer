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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
fun SessionMenu(
    session: RemoteSession,
    showPointer: Boolean,
    onShowPointer: (Boolean) -> Unit,
    trackpad: Boolean,
    onTrackpad: (Boolean) -> Unit,
    onScreenshot: () -> Unit,
    onSendFile: () -> Unit,
) {
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
        IconButton(onClick = { open = true }) { Icon(Icons.Default.MoreVert, contentDescription = stringResource(R.string.more)) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            heading(stringResource(R.string.actions))
            item(stringResource(R.string.send_ctrl_alt_delete), enabled = control) { session.command(RemoteCommand.CtrlAltDelete) }
            item(stringResource(R.string.lock_remote_screen), enabled = control) { session.command(RemoteCommand.Lock) }
            item(stringResource(R.string.restart_remote_computer), enabled = control) { confirmRestart = true }
            item(stringResource(R.string.release_all), enabled = control) { session.releaseAll() }
            item(stringResource(R.string.save_screenshot)) { onScreenshot() }

            HorizontalDivider()
            heading(stringResource(R.string.share))
            val unread = session.unreadChat
            item(if (unread > 0) stringResource(R.string.chat_unread, unread) else stringResource(R.string.chat)) {
                session.showChat(true)
            }
            item(stringResource(R.string.send_file)) { onSendFile() }
            item(stringResource(R.string.send_clipboard)) { session.sendPhoneClipboard() }
            item(stringResource(R.string.receive_clipboard), checked = session.clipboardSharing) {
                session.toggleClipboardSharing()
            }
            item(stringResource(R.string.play_sound), checked = session.sound) { session.toggleSound() }

            if (session.monitors.size > 1) {
                HorizontalDivider()
                heading(stringResource(R.string.monitor))
                item(stringResource(R.string.all_monitors), checked = session.monitor == -1) { session.monitor = -1 }
                session.monitors.forEachIndexed { i, m ->
                    item(stringResource(R.string.monitor_size, i + 1, m.width, m.height), checked = session.monitor == i) { session.monitor = i }
                }
            }

            HorizontalDivider()
            heading(stringResource(R.string.image_quality))
            for ((label, c) in listOf(R.string.quality_automatic to RemoteCommand.QualityAutomatic,
                                      R.string.quality_speed to RemoteCommand.QualitySpeed,
                                      R.string.quality_best to RemoteCommand.QualityBest)) {
                item(stringResource(label), checked = quality == c) { quality = c; session.command(c) }
            }

            HorizontalDivider()
            item(stringResource(R.string.show_wallpaper), checked = wallpaper, enabled = control) {
                wallpaper = !wallpaper
                session.command(RemoteCommand.Wallpaper, if (wallpaper) 1 else 0)
            }
            item(stringResource(R.string.show_pointer), checked = showPointer) { onShowPointer(!showPointer) }
            item(stringResource(R.string.trackpad_mode), checked = trackpad, enabled = control) { onTrackpad(!trackpad) }
        }
    }

    if (confirmRestart) {
        AlertDialog(
            onDismissRequest = { confirmRestart = false },
            title = { Text(stringResource(R.string.restart_title)) },
            text = { Text(stringResource(R.string.restart_message)) },
            confirmButton = {
                TextButton(onClick = { confirmRestart = false; session.command(RemoteCommand.Restart) }) { Text(stringResource(R.string.restart)) }
            },
            dismissButton = { TextButton(onClick = { confirmRestart = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
