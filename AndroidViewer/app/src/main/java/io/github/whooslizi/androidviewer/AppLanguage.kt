package io.github.whooslizi.androidviewer

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/** The language chosen in Settings: "" follows the phone, otherwise a tag with a res/values-<tag> folder. */
object AppLanguage {
    fun get(context: Context): String = prefs(context).getString(KEY, "").orEmpty()

    fun set(context: Context, tag: String) = prefs(context).edit().putString(KEY, tag).apply()

    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private const val KEY = "language"
}

fun Context.localized(): Context {
    val tag = AppLanguage.get(this).ifEmpty { return this }
    return createConfigurationContext(Configuration(resources.configuration).apply { setLocale(Locale.forLanguageTag(tag)) })
}
