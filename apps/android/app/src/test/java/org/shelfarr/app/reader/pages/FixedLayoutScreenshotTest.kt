package org.shelfarr.app.reader.pages

import android.app.Application
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import com.github.takahirom.roborazzi.captureRoboImage
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ComicArchive
import org.shelfarr.app.core.ComicFixtures
import org.shelfarr.app.core.PDF_MEDIA_TYPE
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.core.validate
import org.shelfarr.app.reader.FormatChoice
import org.shelfarr.app.reader.ReaderState
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.ui.details.DetailsScreen
import org.shelfarr.app.ui.details.DetailsState
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** Renders the PDF and comic reader on the JVM, at phone and large-text sizes, for review. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class FixedLayoutScreenshotTest {
    @get:Rule val compose = createComposeRule()
    @get:Rule val folder = TemporaryFolder()
    private var comic: ComicPages? = null

    @After
    fun tearDown() {
        comic?.close()
    }

    private val epub = Asset("e", "b.epub", "application/epub+zip", "epub", 2_400_000, "/c/e")
    private val pdf = Asset("p", "b.pdf", PDF_MEDIA_TYPE, "pdf", 18_600_000, "/c/p", position = 1)
    private val mixed = Publication(
        "b", "The Atlas of Remote Islands", "Fixture Author", "Fifty islands I have never set foot on and never will.",
        BookType.EBOOK, assets = listOf(epub, pdf),
    )

    /** [screen] captures every window, so dialogs are included. */
    @OptIn(com.github.takahirom.roborazzi.ExperimentalRoborazziApi::class)
    private fun shot(name: String, dark: Boolean = false, screen: Boolean = false, content: @Composable () -> Unit) {
        compose.setContent {
            ShelfarrTheme(if (dark) AppearanceMode.DARK else AppearanceMode.LIGHT) {
                Surface(Modifier.fillMaxSize()) { content() }
            }
        }
        compose.waitForIdle()
        if (screen) {
            com.github.takahirom.roborazzi.captureScreenRoboImage("build/screenshots/$name.png")
        } else {
            compose.onRoot().captureRoboImage("build/screenshots/$name.png")
        }
    }

    @Composable
    private fun PdfReaderFixture(chrome: Boolean, theme: ReaderTheme = ReaderTheme.PAPER, invalid: InvalidPlace? = null, title: String = mixed.title) =
        PagedReader(
            title = title,
            format = ReadingFormat.PDF,
            pageCount = 214,
            initialPage = 41,
            theme = theme,
            chromeVisible = chrome,
            render = { index, width, height -> PageFixtures.draw(index, width, height) },
            onPageSettled = {},
            onToggleChrome = {},
            onClose = {},
            invalidPlace = invalid,
        )

    @Test
    fun pdf_quiet() = shot("15-pdf-quiet") { PdfReaderFixture(chrome = false) }

    @Test
    fun pdf_controls() = shot("15-pdf-controls") { PdfReaderFixture(chrome = true) }

    @Test
    fun pdf_invalid_place() = shot("15-pdf-invalid-place", screen = true) {
        PdfReaderFixture(chrome = false, invalid = InvalidPlace("page 412", 214))
    }

    @Test
    fun comic_controls_night() {
        // Real archive, real page list and the platform image decoder.
        val built = ComicFixtures.zip(
            listOf(
                ComicFixtures.Entry("01.png", PageFixtures.png(0)),
                ComicFixtures.Entry("02.jpg", PageFixtures.jpeg(1), method = 0),
                ComicFixtures.Entry("03.png", PageFixtures.png(2)),
            ),
        )
        val file = File(folder.root, "c.cbz").apply { writeBytes(built.bytes) }
        val pages = ComicPages(ComicArchive.open(file, ComicFixtures.order("z", built.items).validate(ComicFixtures.asset("z", built)), file.length()))
        comic = pages
        shot("15-comic-controls-night", dark = true) {
            PagedReader(
                title = "Harbour Lights, Issue 3",
                format = ReadingFormat.CBZ,
                pageCount = pages.pageCount,
                initialPage = 1,
                theme = ReaderTheme.NIGHT,
                chromeVisible = true,
                render = { index, width, height -> runBlocking { pages.render(index, width, height) } },
                onPageSettled = {},
                onToggleChrome = {},
                onClose = {},
            )
        }
    }

    @Test
    fun large_text_controls() {
        RuntimeEnvironment.setFontScale(2f)
        shot("15-large-text-pdf-controls") { PdfReaderFixture(chrome = true, title = "A Very Long Title That Runs Over Several Lines of the Jacket") }
    }

    @Test
    @Config(qualifiers = "w320dp-h568dp-xhdpi")
    fun small_phone_large_text_controls() {
        RuntimeEnvironment.setFontScale(2f)
        shot("15-small-large-text-pdf-controls") { PdfReaderFixture(chrome = true, theme = ReaderTheme.SEPIA) }
    }

    @Test
    fun format_choice() = shot("15-format-choice") {
        FormatChoice(ReaderTheme.PAPER, ReaderState.ChooseFormat(mixed.title, mixed.readingAssets), {}, {})
    }

    @Test
    @Config(qualifiers = "w320dp-h568dp-xhdpi")
    fun small_phone_large_text_format_choice() {
        RuntimeEnvironment.setFontScale(2f)
        shot("15-small-large-text-format-choice") {
            FormatChoice(ReaderTheme.NIGHT, ReaderState.ChooseFormat(mixed.title, mixed.readingAssets), {}, {})
        }
    }

    @Test
    fun details_download_format_choice() {
        shot("15-details-formats") { DetailsScreen(DetailsState.Loaded(mixed), "books.example.org", {}, {}, {}) }
        compose.onNodeWithText("Download…").performClick()
        compose.waitForIdle()
        @OptIn(com.github.takahirom.roborazzi.ExperimentalRoborazziApi::class)
        com.github.takahirom.roborazzi.captureScreenRoboImage("build/screenshots/15-details-download-format-choice.png")
    }
}
