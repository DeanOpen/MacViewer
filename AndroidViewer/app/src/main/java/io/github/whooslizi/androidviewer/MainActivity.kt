package io.github.whooslizi.androidviewer

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlin.concurrent.thread

class MainActivity : ComponentActivity() {
    private var session by mutableStateOf<RemoteSession?>(null)
    private var message by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(Modifier.fillMaxSize()) {
                    val s = session
                    if (s == null) {
                        ConnectScreen(message, ::connect)
                    } else {
                        BackHandler { s.disconnect() }
                        ViewerScreen(s)
                    }
                }
            }
        }
    }

    private fun connect(id: String, password: String) {
        getPreferences(Context.MODE_PRIVATE).edit().putString("id", id).apply()
        message = "Connecting…"
        val metrics = resources.displayMetrics
        val dir = filesDir.path
        thread {
            val result = runCatching { Native.connect(dir, id, password, metrics.widthPixels, metrics.heightPixels) }
            runOnUiThread {
                result.onSuccess { handle ->
                    message = null
                    session = RemoteSession(handle) { reason ->
                        session = null
                        message = reason
                    }.also { it.start() }
                }.onFailure { message = it.message ?: "Could not connect." }
            }
        }
    }

    override fun onDestroy() {
        session?.disconnect()
        super.onDestroy()
    }

    @Composable
    private fun ConnectScreen(message: String?, onConnect: (String, String) -> Unit) {
        val prefs = remember { getPreferences(Context.MODE_PRIVATE) }
        var id by remember { mutableStateOf(prefs.getString("id", "") ?: "") }
        var password by remember { mutableStateOf("") }
        val submit = { onConnect(id.filter(Char::isDigit), password) }
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(24.dp),
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
            Button(onClick = submit, enabled = id.any(Char::isDigit) && password.isNotEmpty(), modifier = Modifier.fillMaxWidth()) {
                Text("Connect")
            }
            message?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
        }
    }
}
