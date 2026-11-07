package org.shelfarr.app.reader

import android.content.SharedPreferences
import androidx.compose.ui.graphics.Color as ComposeColor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.Color
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.preferences.ImageFilter
import org.readium.r2.navigator.preferences.TextAlign
import org.readium.r2.navigator.preferences.Theme
import org.readium.r2.shared.ExperimentalReadiumApi
import org.shelfarr.app.core.ApiJson

/** Page colours. These apply to the book and its chrome, independent of the app theme. */
enum class ReaderTheme(
    val label: String,
    val page: Long,
    val text: Long,
    val muted: Long,
    val bar: Long,
    val hairline: Long,
    val accent: Long,
    val readium: Theme,
) {
    PAPER("Paper", 0xFFFBF7F0, 0xFF2A241D, 0xFF665B4E, 0xFFFFFDF9, 0xFFE6DCCB, 0xFFA33A22, Theme.LIGHT),
    SEPIA("Sepia", 0xFFF0E5D0, 0xFF3A2E21, 0xFF65553F, 0xFFF7EEDD, 0xFFDCCDB1, 0xFF96351F, Theme.SEPIA),
    NIGHT("Night", 0xFF16130F, 0xFFD9CFC0, 0xFFA99D8D, 0xFF211C17, 0xFF38302A, 0xFFEE9270, Theme.DARK),
    ;

    val pageColor: ComposeColor get() = ComposeColor(page)
    val textColor: ComposeColor get() = ComposeColor(text)
    val mutedColor: ComposeColor get() = ComposeColor(muted)
    val barColor: ComposeColor get() = ComposeColor(bar)
    val hairlineColor: ComposeColor get() = ComposeColor(hairline)
    val accentColor: ComposeColor get() = ComposeColor(accent)
}

enum class ReaderFont(val label: String, val family: String?) {
    NEWSREADER("Newsreader", "Newsreader"),
    SANS("Sans", "sans-serif"),
    ORIGINAL("Book's own", null),
}

@Serializable
data class ReaderSettings(
    val theme: ReaderTheme = ReaderTheme.PAPER,
    val font: ReaderFont = ReaderFont.NEWSREADER,
    val fontSize: Double = 1.0,
    val lineHeight: Double = 1.5,
    val margins: Double = 1.0,
    val justify: Boolean = false,
    val scroll: Boolean = false,
) {
    @OptIn(ExperimentalReadiumApi::class)
    fun toPreferences(): EpubPreferences {
        val original = font == ReaderFont.ORIGINAL
        return EpubPreferences(
            theme = theme.readium,
            backgroundColor = Color(theme.page.toInt()),
            textColor = Color(theme.text.toInt()),
            imageFilter = if (theme == ReaderTheme.NIGHT) ImageFilter.DARKEN else null,
            fontFamily = font.family?.let(::FontFamily),
            fontSize = fontSize,
            lineHeight = if (original) null else lineHeight,
            pageMargins = margins,
            publisherStyles = original,
            textAlign = if (original) null else if (justify) TextAlign.JUSTIFY else TextAlign.START,
            hyphens = if (original) null else justify,
            scroll = scroll,
        )
    }

    companion object {
        val FontSizes = 0.75..2.5
        const val FontStep = 0.1
    }
}

/** Display preferences only, so plain app preferences are the right home. */
class ReaderSettingsStore(private val preferences: SharedPreferences) {
    private val state = MutableStateFlow(load())
    val settings: StateFlow<ReaderSettings> = state.asStateFlow()

    private fun load(): ReaderSettings = preferences.getString(KEY, null)
        ?.let { runCatching { ApiJson.decodeFromString<ReaderSettings>(it) }.getOrNull() }
        ?: ReaderSettings()

    fun update(transform: (ReaderSettings) -> ReaderSettings) {
        val updated = transform(state.value)
        state.value = updated
        preferences.edit().putString(KEY, ApiJson.encodeToString(updated)).apply()
    }

    private companion object {
        const val KEY = "reader_settings"
    }
}
