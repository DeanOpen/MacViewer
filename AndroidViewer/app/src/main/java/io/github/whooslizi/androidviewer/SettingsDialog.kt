package io.github.whooslizi.androidviewer

import android.app.Activity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp

@Composable
fun SettingsDialog(onDismiss: () -> Unit) {
    val activity = LocalContext.current as Activity
    val current = remember { AppLanguage.get(activity) }
    // Each language is named in itself, so it can be found from any language.
    val choices = listOf("" to stringResource(R.string.system_language), "en" to "English", "vi" to "Tiếng Việt")

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.settings)) },
        text = {
            Column(Modifier.selectableGroup()) {
                Text(stringResource(R.string.language), style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary)
                for ((tag, label) in choices) {
                    Row(
                        Modifier.fillMaxWidth().selectable(selected = tag == current, role = Role.RadioButton) {
                            if (tag != current) {
                                AppLanguage.set(activity, tag)
                                activity.recreate() // reloads every string; the session lives in the ViewModel
                            }
                        }.padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = tag == current, onClick = null)
                        Text(label, Modifier.padding(start = 12.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
    )
}
