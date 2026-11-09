package org.shelfarr.app.reader.pages

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.click
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.pinch
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.unit.IntSize
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.ComicArchive
import org.shelfarr.app.core.ComicFixtures
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.core.UnreadableFile
import org.shelfarr.app.core.validate
import org.shelfarr.app.reader.ReaderTheme

/**
 * The pager only reports where it settled; the view model writes a page only when that
 * differs from the page already shown. These tests pin what the pager reports.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class PagedReaderTest {
    @get:Rule val compose = createComposeRule()
    @get:Rule val folder = TemporaryFolder()

    private val settled = CopyOnWriteArrayList<Int>()
    private var toggles = 0
    private val commands = MutableSharedFlow<PageCommand>(extraBufferCapacity = 4)

    private fun show(initial: Int, pageCount: Int = 6, chrome: Boolean = false) {
        compose.setContent {
            PagedReader(
                title = "Fixture",
                format = ReadingFormat.PDF,
                pageCount = pageCount,
                initialPage = initial,
                theme = ReaderTheme.PAPER,
                chromeVisible = chrome,
                render = { index, width, height -> PageFixtures.draw(index, width, height) },
                onPageSettled = { settled += it },
                onToggleChrome = { toggles++ },
                onClose = {},
                commands = commands,
            )
        }
        compose.waitForIdle()
    }

    @Test
    fun `opening at a saved page reports only that page`() {
        show(initial = 3)
        assertEquals(listOf(3), settled.distinct())
        compose.onNodeWithContentDescription("Page 4 of 6").assertExists()
    }

    @Test
    fun `a swipe, an edge tap and a command each settle on a new page`() {
        show(initial = 0)
        compose.onNodeWithContentDescription("Page 1 of 6").performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertEquals(1, settled.last())
        compose.onNodeWithContentDescription("Page 2 of 6").performTouchInput { click(Offset(width * 0.95f, height / 2f)) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(2, settled.last())
        compose.onNodeWithContentDescription("Page 3 of 6").performTouchInput { click(Offset(width * 0.05f, height / 2f)) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(1, settled.last())
        runBlocking { commands.emit(PageCommand(5, animate = false)) }
        compose.waitForIdle()
        assertEquals(5, settled.last())
    }

    @Test
    fun `a middle tap shows the controls and turns nothing`() {
        show(initial = 2)
        compose.onNodeWithContentDescription("Page 3 of 6").performTouchInput { click(center) }
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(1, toggles)
        assertEquals(listOf(2), settled.distinct())
    }

    @Test
    fun `zooming and panning a zoomed page never turn it`() {
        show(initial = 1)
        val page = compose.onNodeWithContentDescription("Page 2 of 6")
        page.performTouchInput {
            pinch(center - Offset(40f, 0f), center - Offset(300f, 0f), center + Offset(40f, 0f), center + Offset(300f, 0f))
        }
        compose.waitForIdle()
        page.performTouchInput { swipeLeft() }
        compose.waitForIdle()
        assertEquals("Zoomed: a drag pans", listOf(1), settled.distinct())
    }

    @Test
    fun `rebuilding the reader, as a rotation does, reports the page already shown`() {
        var initial by mutableIntStateOf(4)
        var generation by mutableStateOf(0)
        compose.setContent {
            androidx.compose.runtime.key(generation) {
                PagedReader(
                    title = "Fixture", format = ReadingFormat.CBZ, pageCount = 6, initialPage = initial,
                    theme = ReaderTheme.NIGHT, chromeVisible = false,
                    render = { index, width, height -> PageFixtures.draw(index, width, height) },
                    onPageSettled = { settled += it }, onToggleChrome = {}, onClose = {},
                )
            }
        }
        compose.waitForIdle()
        generation++
        compose.waitForIdle()
        assertEquals(listOf(4), settled.distinct())
    }

    @Test
    fun `controls turn pages with labelled buttons`() {
        show(initial = 2, chrome = true)
        compose.onNodeWithText("Page 3 of 6").assertExists()
        compose.onNodeWithContentDescription("Next page").performClick()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(3, settled.last())
        compose.onNodeWithContentDescription("Previous page").performClick()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(2, settled.last())
    }

    @Test
    fun `comic pages decode through the real archive and image decoder, bounded`() = runBlocking {
        val built = ComicFixtures.zip(
            listOf(
                ComicFixtures.Entry("01.png", PageFixtures.png(0)),
                ComicFixtures.Entry("02.jpg", PageFixtures.jpeg(1), method = 0),
            ),
        )
        val file = File(folder.root, "c.cbz").apply { writeBytes(built.bytes) }
        val asset = ComicFixtures.asset("z", built)
        ComicPages(ComicArchive.open(file, ComicFixtures.order("z", built.items).validate(asset), file.length())).use { pages ->
            val small = pages.render(0, 150, 300)
            assertTrue("sampled down to the box: ${small.width}x${small.height}", small.width in 150..300 && small.height <= 600)
            val full = pages.render(1, 1200, 1800)
            assertEquals(600, full.width)
            assertTrue("the second page's band is drawn", near(PageFixtures.color(1), full.getPixel(300, 40)))
            assertTrue("the first page's band is drawn", near(PageFixtures.color(0), small.getPixel(small.width / 2, 5)))
        }
        // A page whose bytes aren't the image type the page list claims is refused visibly.
        val lying = ComicFixtures.zip(listOf(ComicFixtures.Entry("01.png", PageFixtures.jpeg(0))))
        val lyingFile = File(folder.root, "l.cbz").apply { writeBytes(lying.bytes) }
        ComicPages(ComicArchive.open(lyingFile, ComicFixtures.order("l", lying.items).validate(ComicFixtures.asset("l", lying)), lyingFile.length())).use { pages ->
            val failure = runCatching { pages.render(0, 300, 300) }.exceptionOrNull()
            assertTrue("$failure", failure is UnreadableFile)
        }
    }

    @Test
    fun `page fitting keeps the shape and the pixel bound`() {
        assertEquals(400 to 600, fit(800, 1200, 400, 900))
        val (w, h) = fit(10_000, 10_000, 20_000, 20_000)
        assertTrue(w.toLong() * h <= MAX_PAGE_PIXELS + w + h)
        assertEquals(TapZone.PREVIOUS, tapZone(10f, 400))
        assertEquals(TapZone.MIDDLE, tapZone(200f, 400))
        assertEquals(TapZone.NEXT, tapZone(390f, 400))
        assertEquals(Offset(50f, -100f), clampOffset(Offset(500f, -500f), 2f, IntSize(100, 200)))
    }

    private fun near(expected: Int, actual: Int): Boolean =
        listOf(16, 8, 0).all { shift -> kotlin.math.abs(((expected shr shift) and 255) - ((actual shr shift) and 255)) <= 40 }
}
