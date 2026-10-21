package io.github.whooslizi.androidviewer

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

/** "123456789" → "123 456 789", as UltraViewer shows IDs. */
fun groupId(id: String): String = id.reversed().chunked(3).joinToString(" ").reversed()

@Composable
fun ConnectScreen(model: ViewerViewModel) {
    val credentials = model.credentials
    val recents = model.recents
    var id by rememberSaveable { mutableStateOf(recents.firstOrNull().orEmpty()) }
    var password by remember { mutableStateOf(credentials.password(id).orEmpty()) }
    var rememberPassword by rememberSaveable { mutableStateOf(true) }
    val digits = id.filter(Char::isDigit)

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("AndroidViewer", style = MaterialTheme.typography.headlineMedium)
        Text("Control a computer running UltraViewer.", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = id, onValueChange = { v -> id = v.filter { it.isDigit() || it == ' ' } },
            label = { Text("Partner ID") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        )
        OutlinedTextField(
            value = password, onValueChange = { password = it },
            label = { Text("Password") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        )
        Row(
            Modifier.fillMaxWidth().clickable { rememberPassword = !rememberPassword },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(checked = rememberPassword, onCheckedChange = { rememberPassword = it })
            Text("Remember password on this phone")
        }
        Button(
            onClick = { model.connect(digits, password, rememberPassword) },
            enabled = !model.connecting && digits.isNotEmpty() && password.isNotEmpty(),
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Connect") }
        model.message?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }

        if (recents.isNotEmpty()) {
            HorizontalDivider()
            Text("Recent", style = MaterialTheme.typography.titleSmall)
            for (recent in recents) {
                TextButton(onClick = {
                    id = recent
                    password = credentials.password(recent).orEmpty()
                }) { Text(groupId(recent)) }
            }
        }
    }
}
