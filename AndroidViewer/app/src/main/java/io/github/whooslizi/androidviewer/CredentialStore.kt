package io.github.whooslizi.androidviewer

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Recent partner IDs, and their passwords encrypted with an AES key that never
 * leaves the Android Keystore. Backups are off in the manifest.
 */
class CredentialStore(context: Context) {
    private val prefs = context.getSharedPreferences("partners", Context.MODE_PRIVATE)

    val recents: List<String>
        get() = prefs.getString(RECENTS, "").orEmpty().split(',').filter { it.isNotEmpty() }

    fun addRecent(id: String) {
        val list = (listOf(id) + recents.filter { it != id }).take(MAX_RECENTS)
        prefs.edit().putString(RECENTS, list.joinToString(",")).apply()
    }

    fun password(id: String): String? = runCatching {
        val blob = Base64.decode(prefs.getString(PASSWORD + id, null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, IV_SIZE))
        String(cipher.doFinal(blob, IV_SIZE, blob.size - IV_SIZE), Charsets.UTF_8)
    }.getOrNull()

    fun savePassword(id: String, password: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val blob = cipher.iv + cipher.doFinal(password.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(PASSWORD + id, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    fun forgetPassword(id: String) {
        prefs.edit().remove(PASSWORD + id).apply()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
        }.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "partner-passwords"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
        const val RECENTS = "recents"
        const val PASSWORD = "password."
        const val MAX_RECENTS = 8
    }
}
