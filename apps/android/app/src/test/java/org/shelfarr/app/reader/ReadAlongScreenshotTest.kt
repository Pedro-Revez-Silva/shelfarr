package org.shelfarr.app.reader

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.DownloadedFile
import org.shelfarr.app.core.NarrationDownload
import org.shelfarr.app.core.NarrationPlace
import org.shelfarr.app.core.NarrationState
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadAlongCoverage
import org.shelfarr.app.core.ReadAlongFixtures
import org.shelfarr.app.core.ReadAlongSummary
import org.shelfarr.app.ui.downloads.DownloadPanel
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** Rendered read-along screens, light, night and with large text, on a phone. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class ReadAlongScreenshotTest {
    @get:Rule val compose = createComposeRule()

    private val ready = ReadAlongUi.Ready(note = "Narration from this book. Narration covers all 12 sections.", follow = true)
    private val partial = ReadAlongUi.Ready(
        note = "Narrated by “The Way of Kings (Unabridged)”, aligned to this edition. Narration covers 38 of 40 sections; the others are text only.",
        speed = 1.25f,
    )
    private val recorded = mutableListOf<String>()
    private val actions = object : NarrationActions {
        override fun toggle() { recorded += "toggle" }
        override fun skip(back: Boolean) { recorded += if (back) "back" else "forward" }
        override fun setSpeed(speed: Float) { recorded += "speed $speed" }
        override fun setFollow(follow: Boolean) { recorded += "follow $follow" }
        override fun backToNarration() { recorded += "back to narration" }
        override fun useAudiobookPlace() { recorded += "use offer" }
        override fun dismissAudiobookPlace() { recorded += "dismiss offer" }
    }

    private fun shot(name: String, theme: ReaderTheme = ReaderTheme.PAPER, content: @Composable () -> Unit) {
        compose.setContent {
            ShelfarrTheme(if (theme == ReaderTheme.NIGHT) AppearanceMode.DARK else AppearanceMode.LIGHT) {
                Surface(Modifier.fillMaxSize(), color = theme.pageColor) { content() }
            }
        }
        compose.onRoot().captureRoboImage("build/screenshots/read-along/$name.png")
    }

    /** A page of book text, as the WebView would show it behind the chrome. */
    @Composable
    private fun Page(theme: ReaderTheme) {
        Column(Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 28.dp, vertical = 72.dp)) {
            Text(
                "Cue 3 sounds the lantern tone. " + "lantern ".repeat(60),
                style = MaterialTheme.typography.bodyLarge,
                color = theme.textColor,
            )
        }
    }

    private fun chrome(name: String, ui: ReadAlongUi, theme: ReaderTheme = ReaderTheme.PAPER) = shot(name, theme) {
        Box(Modifier.fillMaxSize().background(theme.pageColor)) {
            Page(theme)
            ReaderBars(
                title = "The Narrated Garden",
                positionCount = 214,
                settings = ReaderSettings(theme = theme),
                place = ReadingPlace(0.31f, 66, "Chapter 2"),
                onClose = {},
                onContents = {},
                onAppearance = {},
                onScrub = {},
                extra = { NarrationPanel(ui, theme, actions) },
            )
        }
    }

    /** The page with the controls hidden: only what read-along adds to it. */
    private fun page(name: String, ui: ReadAlongUi.Ready, theme: ReaderTheme = ReaderTheme.PAPER) = shot(name, theme) {
        Box(Modifier.fillMaxSize().background(theme.pageColor)) {
            Page(theme)
            PageFoot("31%", ui, theme, actions, Modifier.align(Alignment.BottomCenter))
        }
    }

    @Test
    fun controls_paper() = chrome("01-controls-paper", ready)

    @Test
    fun controls_playing_night() = chrome("02-controls-playing-night", partial.copy(playing = true, started = true), ReaderTheme.NIGHT)

    @Test
    fun controls_sepia_follow_off() = chrome("03-controls-sepia-follow-off", ready.copy(follow = false, started = true), ReaderTheme.SEPIA)

    @Test
    fun controls_problem() = chrome(
        "04-controls-problem",
        ready.copy(started = true, problem = "The narration couldn't be played. Check the connection or sign in again, then press Play."),
    )

    @Test
    fun unavailable_note() = chrome(
        "05-unavailable",
        ReadAlongUi.Unavailable("“The Way of Kings” isn't aligned with this text, so read-along isn't available. You can listen to it on its own."),
    )

    @Test
    fun pill_playing() = page("06-pill-playing", ready.copy(started = true, playing = true))

    @Test
    fun pill_browsing_night() = page("07-pill-browsing-night", ready.copy(started = true, playing = true, browsing = true), ReaderTheme.NIGHT)

    @Test
    fun offer() = page(
        "08-offer",
        partial.copy(offer = AudiobookOffer("The Paired Lighthouse", NarrationPlace(1, 7_500, 7, exact = true))),
    )

    @Test
    fun large_text_controls() {
        RuntimeEnvironment.setFontScale(2f)
        chrome("09-large-text-controls", partial.copy(started = true, playing = true))
    }

    @Test
    fun large_text_pill() {
        RuntimeEnvironment.setFontScale(2f)
        page("10-large-text-pill-browsing", ready.copy(started = true, playing = true, browsing = true))
    }

    @Test
    @Config(qualifiers = "w320dp-h568dp-xhdpi")
    fun small_phone_controls() = chrome("11-small-phone-controls", partial.copy(started = true))

    @Test
    fun plain_epub_adds_nothing() {
        chrome("12-plain-epub-controls", ReadAlongUi.Off)
        compose.onAllNodesWithText("Follow the text").assertCountEquals(0)
        compose.onAllNodesWithText("Play", substring = true).assertCountEquals(0)
    }

    @Test
    fun controls_are_named_for_talkback_and_act() {
        chrome("13-talkback", partial.copy(started = true, playing = true))
        compose.onNodeWithContentDescription("Pause narration").performClick()
        compose.onNodeWithContentDescription("Back 15 seconds").performClick()
        compose.onNodeWithContentDescription("Forward 30 seconds").performClick()
        compose.onAllNodesWithText("Follow the text")[0].performClick()
        val speed = compose.onNodeWithContentDescription("Narration speed")
        speed.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "1.25×"))
        speed.performClick()
        compose.onAllNodesWithText("1.5×")[0].performClick()
        assertEquals(listOf("toggle", "back", "forward", "follow false", "speed 1.5"), recorded)
    }

    private val book = Publication(
        id = "garden-1", title = "The Narrated Garden", bookType = BookType.EBOOK,
        assets = listOf(
            Asset(
                ReadAlongFixtures.EPUB_ID, "garden.epub", "application/epub+zip", "epub", 2_200_000, "/c",
                readAlong = ReadAlongSummary(
                    "available", "media_overlay", ReadAlongFixtures.GENERATION, "/m",
                    coverage = ReadAlongCoverage(true, 12, 12), audioBytes = 61_000_000,
                ),
            ),
        ),
    )

    private fun downloads(name: String, record: DownloadRecord?, offline: Boolean = false) = shot(name) {
        ShelfarrTheme(AppearanceMode.LIGHT) {
            Surface(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp)) {
                    DownloadPanel(book, record, offline, {}, {}, {}, {})
                }
            }
        }
    }

    private val readyBook = DownloadRecord(
        "garden-1", book, listOf(DownloadedFile(ReadAlongFixtures.EPUB_ID, "000-a.epub", 2_200_000, complete = true, bytesDone = 2_200_000)),
        DownloadState.READY,
    )

    @Test
    fun download_with_narration() = downloads("14-download-offer", null)

    @Test
    fun download_narration_progress() = downloads(
        "15-download-narration-progress",
        readyBook.copy(
            withNarration = true,
            narration = NarrationDownload(
                ReadAlongFixtures.GENERATION, "media_overlay", "ra-x.json",
                listOf(DownloadedFile("n0", "ra-x-0000.wav", 61_000_000, bytesDone = 24_000_000)), NarrationState.DOWNLOADING,
            ),
        ),
    )

    @Test
    fun download_narration_ready() = downloads(
        "16-download-narration-ready",
        readyBook.copy(
            withNarration = true,
            narration = NarrationDownload(
                ReadAlongFixtures.GENERATION, "media_overlay", "ra-x.json",
                listOf(DownloadedFile("n0", "ra-x-0000.wav", 61_000_000, complete = true, bytesDone = 61_000_000)), NarrationState.READY,
            ),
        ),
    )

    @Test
    fun download_text_only() = downloads("17-download-text-only-ready", readyBook)
}
