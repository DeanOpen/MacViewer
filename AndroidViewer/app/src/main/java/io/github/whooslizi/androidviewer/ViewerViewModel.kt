package io.github.whooslizi.androidviewer

import android.app.Application
import android.os.Build
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.concurrent.thread

/**
 * Owns the connection, so it survives Activity recreation (rotation, dark mode,
 * multi-window); it ends when the user disconnects or the app is closed.
 */
class ViewerViewModel(app: Application) : AndroidViewModel(app) {
    val credentials = CredentialStore(app)

    init {
        // Leftovers of transfers cut off by a crash or a killed process.
        thread { transferRoot(app).deleteRecursively() }
    }

    var session by mutableStateOf<RemoteSession?>(null)
        private set
    /** Progress or the reason the last connection ended. */
    var message by mutableStateOf<String?>(null)
        private set
    var connecting by mutableStateOf(false)
        private set
    var recents by mutableStateOf(credentials.recents)
        private set

    fun connect(id: String, password: String, remember: Boolean) {
        if (connecting || session != null) return
        connecting = true
        val app = getApplication<Application>()
        val text = app.localized().resources
        message = text.getString(R.string.connecting)
        val metrics = app.resources.displayMetrics
        viewModelScope.launch {
            // Not cancellable: a handle that came back must be closed and freed, even if the screen is gone.
            val result = withContext(Dispatchers.IO + NonCancellable) {
                runCatching {
                    Native.connect(app.filesDir.path, Build.MODEL, id, password, metrics.widthPixels, metrics.heightPixels)
                }
            }
            connecting = false
            result.onFailure { message = it.message ?: text.getString(R.string.could_not_connect) }
            result.onSuccess { handle ->
                message = null
                session = RemoteSession(
                    handle,
                    app,
                    text,
                    // Remember only what actually connected.
                    onConnected = { rememberPartner(id, password, remember) },
                    onClosed = { reason ->
                        session = null
                        message = reason.ifEmpty { text.getString(R.string.session_ended) }
                    },
                ).also {
                    it.start()
                    if (cleared) it.disconnect()
                }
            }
        }
    }

    private fun rememberPartner(id: String, password: String, remember: Boolean) {
        credentials.addRecent(id)
        recents = credentials.recents
        // The Keystore can fail (e.g. a key invalidated by a lock-screen change); that must not end the session.
        runCatching { if (remember) credentials.savePassword(id, password) else credentials.forgetPassword(id) }
            .onFailure { Log.w(TAG, "Could not update the saved password", it) }
    }

    private var cleared = false

    override fun onCleared() {
        cleared = true
        session?.disconnect()
    }

    private companion object {
        const val TAG = "AndroidViewer"
    }
}
