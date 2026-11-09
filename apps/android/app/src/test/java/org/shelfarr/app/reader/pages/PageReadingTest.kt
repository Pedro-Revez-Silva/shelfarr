package org.shelfarr.app.reader.pages

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.pinch
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ComicArchive
import org.shelfarr.app.core.ComicFixtures
import org.shelfarr.app.core.ComicPage
import org.shelfarr.app.core.ContractServer
import org.shelfarr.app.core.LocalProgress
import org.shelfarr.app.core.MemoryStore
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.SyncTiming
import org.shelfarr.app.core.TEST_EPOCH
import org.shelfarr.app.core.UnreadableFile
import org.shelfarr.app.core.validate
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * A PDF or comic's reading place moves only when a different page is settled on and drawn.
 *
 * Wired as the reader screen wires it: the real [PagedReader] reports to the real
 * [PageProgress] the view model uses, whose recorded pages go, with their locators, to a
 * real [ProgressSync] over a durable store and a server that follows the progress
 * contract. A hardware key is [PageProgress.turn], which is all `ReaderActivity.onKeyDown`
 * → `ReaderViewModel.turnPage` does once a PDF or comic is open.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class PageReadingTest {
    @get:Rule val compose = createComposeRule()
    @get:Rule val folder = TemporaryFolder()

    /** The device's wall clock. Tests move it to tell when each thing happened. */
    private var nowMs = TEST_EPOCH
    private var toggles = 0
    private val scopes = mutableListOf<CoroutineScope>()
    private var comic: ComicPages? = null

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        comic?.close()
    }

    /** One open book: its pager state machine and its durable, synchronised place. */
    private inner class Reading(val pageCount: Int, start: Int, val locate: (Int) -> JsonObject) {
        val store = MemoryStore()
        val server = ContractServer({ nowMs })
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined).also { scopes += it }

        // Sends only when flushed, so a test can wait between reading and syncing.
        val sync = ProgressSync(
            "book", store, server.remote(), scope, now = { nowMs },
            timing = SyncTiming(debounceMs = HOUR, maxWaitMs = HOUR),
        )
        val progress = PageProgress()

        /** Every page the reader recorded as read, with its activity time. */
        val recorded = CopyOnWriteArrayList<Pair<Int, Long>>()

        init {
            // The saved place this session restores, reached on another day.
            runBlocking { sync.begin(SavedPosition("a", locate(start)), 0, OPENED_EARLIER) }
            // As ReaderViewModel.recordPage: the page's locator, with the time it was seen.
            progress.open(pageCount, start) { index, observedAt ->
                recorded += index to observedAt
                runBlocking { sync.update(SavedPosition("a", locate(index)), observedAt) }
            }
        }

        fun saved(): LocalProgress = store.records.getValue("book")

        fun savedPage(): Int = saved().position!!.locator!!["locations"]!!.jsonObject["position"]!!.jsonPrimitive.int - 1

        fun flush() = runBlocking { sync.flush() }
    }

    private var generation by mutableIntStateOf(0)
    private var compact by mutableStateOf(false)

    /** The reader screen's wiring of [PagedReader], keyed as a rebuild on rotation is. */
    private fun show(
        reading: Reading,
        render: suspend (Int, Int, Int) -> Bitmap,
        chrome: Boolean = false,
        format: ReadingFormat = ReadingFormat.PDF,
        theme: ReaderTheme = ReaderTheme.PAPER,
    ) {
        compose.setContent {
            ShelfarrTheme(if (theme == ReaderTheme.NIGHT) AppearanceMode.DARK else AppearanceMode.LIGHT) {
                Surface(if (compact) Modifier.size(300.dp, 500.dp) else Modifier.fillMaxSize()) {
                    val page by reading.progress.page.collectAsState()
                    androidx.compose.runtime.key(generation) {
                        PagedReader(
                            title = "The Atlas of Remote Islands",
                            format = format,
                            pageCount = reading.pageCount,
                            initialPage = page,
                            theme = theme,
                            chromeVisible = chrome,
                            render = render,
                            onPageSettled = reading.progress::onSettled,
                            onPageShown = reading.progress::onShown,
                            onToggleChrome = { toggles++ },
                            onClose = {},
                            commands = reading.progress.commands,
                            clock = { nowMs },
                        )
                    }
                }
            }
        }
        settle()
    }

    private fun settle() {
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }

    private fun shot(name: String) = compose.onRoot().captureRoboImage("build/screenshots/$name.png")

    private fun drawn(failing: Set<Int> = emptySet()): suspend (Int, Int, Int) -> Bitmap = { index, width, height ->
        if (index in failing) throw UnreadableFile("This page's image is damaged.")
        PageFixtures.draw(index, width, height)
    }

    private fun pdf(count: Int): (Int) -> JsonObject = { index -> PageLocators.pdf(index, count) }

    @Test
    fun `a page that can't be drawn keeps the place, and the Next control goes past it`() {
        val reading = Reading(pageCount = 5, start = 0, locate = pdf(5))
        show(reading, drawn(failing = setOf(1)), chrome = true)
        val restored = reading.saved()

        nowMs += 60_000
        compose.onNodeWithContentDescription("Next page").performClick()
        settle()
        compose.onNodeWithText("Couldn't show page 2. This page's image is damaged.").assertIsDisplayed()
        compose.onNodeWithText("Your reading place hasn't moved.").assertIsDisplayed()
        compose.onNodeWithText("Page 2 of 5").assertIsDisplayed()
        shot("16-page-failed-controls")
        assertEquals("The reader is on the failed page", 1, reading.progress.page.value)
        assertEquals("Nothing was recorded for it", emptyList<Pair<Int, Long>>(), reading.recorded)
        assertEquals("Local place, outbox and activity time are untouched", restored, reading.saved())
        reading.flush()
        assertTrue("Nothing reached the server: ${reading.server.received}", reading.server.received.isEmpty())

        // Next from the failed page reaches the page after it.
        nowMs += 60_000
        val seenAt = nowMs
        compose.onNodeWithContentDescription("Next page").performClick()
        settle()
        assertEquals(2, reading.progress.page.value)
        assertEquals(listOf(2 to seenAt), reading.recorded)
        assertEquals(2, reading.savedPage())
        assertEquals(seenAt, reading.saved().observedAtEpochMs)

        // Waiting before the server hears of it keeps the time the page was seen.
        nowMs += 30 * 60_000
        reading.flush()
        val sent = reading.server.received.single()
        assertEquals(3, sent.locator!!["locations"]!!.jsonObject["position"]!!.jsonPrimitive.int)
        assertEquals(ActivityTime.format(seenAt), sent.observedAt)
        assertEquals(ActivityTime.format(seenAt), reading.server.stored!!.observedAt)
    }

    @Test
    fun `hardware keys and edge taps turn past a failed page, or back from it, without saving it`() {
        val reading = Reading(pageCount = 5, start = 0, locate = pdf(5))
        show(reading, drawn(failing = setOf(1)))

        // Page Down: onto the page that fails.
        reading.progress.turn(1)
        settle()
        compose.onNodeWithText("Couldn't show page 2. This page's image is damaged.").assertIsDisplayed()
        assertEquals(1, reading.progress.page.value)
        assertTrue(reading.recorded.isEmpty())
        assertEquals(0, reading.savedPage())

        // Page Down again: turning starts from the page on screen, not from the saved one.
        nowMs += 1_000
        reading.progress.turn(1)
        settle()
        assertEquals(2, reading.progress.page.value)
        assertEquals(listOf(2 to nowMs), reading.recorded)

        // Page Up: back onto the failed page. The place stays on the page last seen.
        reading.progress.turn(-1)
        settle()
        assertEquals(1, reading.progress.page.value)
        assertEquals(2, reading.savedPage())

        // A tap on the failed page's left edge returns to the page before it, which is read.
        nowMs += 1_000
        compose.onNodeWithContentDescription("Page 2 of 5").performTouchInput { click(Offset(width * 0.05f, height / 2f)) }
        settle()
        assertEquals(0, reading.progress.page.value)
        assertEquals(listOf(2 to nowMs - 1_000, 0 to nowMs), reading.recorded)
        assertEquals(0, reading.savedPage())

        // Forward again over it with the right edge, twice.
        reading.progress.turn(1)
        settle()
        compose.onNodeWithContentDescription("Page 2 of 5").performTouchInput { click(Offset(width * 0.95f, height / 2f)) }
        settle()
        assertEquals(2, reading.progress.page.value)
        assertEquals(2, reading.savedPage())
        assertEquals("No failed page was ever recorded", listOf(2, 0, 2), reading.recorded.map { it.first })
        assertEquals("Edge taps never toggled the controls", 0, toggles)
    }

    @Test
    fun `a neighbour drawn ahead is not reading, and a slow page counts only once it is drawn`() {
        val requested = CopyOnWriteArrayList<Int>()
        val gates = mapOf(2 to CompletableDeferred<Unit>(), 3 to CompletableDeferred<Unit>())
        val reading = Reading(pageCount = 6, start = 0, locate = pdf(6))
        show(reading, { index, width, height ->
            requested += index
            gates[index]?.await()
            PageFixtures.draw(index, width, height)
        })
        assertTrue("Page 2 was drawn ahead: $requested", 1 in requested)
        assertTrue("Prefetching is not reading", reading.recorded.isEmpty())
        assertEquals(0, reading.savedPage())

        // Settling on the prefetched page shows it at once.
        nowMs += 1_000
        val secondSeenAt = nowMs
        reading.progress.turn(1)
        settle()
        assertEquals(listOf(1 to secondSeenAt), reading.recorded)

        // Page 3 is still being drawn: the pager is there, the place is not.
        nowMs += 1_000
        reading.progress.turn(1)
        settle()
        assertEquals(2, reading.progress.page.value)
        assertEquals(1, reading.savedPage())
        nowMs += 4_000
        val drawnAt = nowMs
        gates.getValue(2).complete(Unit)
        settle()
        assertEquals("Recorded when it was first seen", listOf(1 to secondSeenAt, 2 to drawnAt), reading.recorded)

        // The reader moves to page 4 and back before it is drawn: page 4 was never seen.
        assertTrue("Page 4 is being drawn ahead", 3 in requested)
        reading.progress.turn(1)
        settle()
        assertEquals(3, reading.progress.page.value)
        reading.progress.turn(-1)
        settle()
        gates.getValue(3).complete(Unit)
        settle()
        assertEquals(2, reading.progress.page.value)
        assertEquals(listOf(1, 2), reading.recorded.map { it.first })
        assertEquals(2, reading.savedPage())
    }

    @Test
    fun `trying a failed page again saves it once it is drawn, at that time`() {
        var healed = false
        val reading = Reading(pageCount = 4, start = 0, locate = pdf(4))
        show(reading, { index, width, height ->
            if (index == 1 && !healed) throw UnreadableFile("This device ran out of memory for it.")
            PageFixtures.draw(index, width, height)
        })
        reading.progress.turn(1)
        settle()
        compose.onNodeWithText("Try again").assertIsDisplayed()
        assertTrue(reading.recorded.isEmpty())

        // Still failing: trying again changes nothing.
        compose.onNodeWithText("Try again").performClick()
        settle()
        compose.onNodeWithText("Couldn't show page 2. This device ran out of memory for it.").assertIsDisplayed()
        assertTrue(reading.recorded.isEmpty())

        nowMs += 5 * 60_000
        healed = true
        compose.onNodeWithText("Try again").performClick()
        settle()
        compose.onNodeWithText("Try again").assertDoesNotExist()
        shot("16-page-retried")
        assertEquals(listOf(1 to nowMs), reading.recorded)
        assertEquals(1, reading.savedPage())
        assertEquals(nowMs, reading.saved().observedAtEpochMs)
        assertEquals("Trying again neither turned nor toggled the controls", 0, toggles)
        assertEquals(1, reading.progress.page.value)
    }

    @Test
    fun `opening, rebuilding, resizing and zooming save nothing`() {
        val requested = CopyOnWriteArrayList<Pair<Int, Int>>()
        val reading = Reading(pageCount = 6, start = 3, locate = pdf(6))
        val restored = reading.saved()
        show(reading, { index, width, height ->
            requested += index to width
            PageFixtures.draw(index, width, height)
        })
        compose.onNodeWithContentDescription("Page 4 of 6").assertIsDisplayed()

        generation++ // a rotation rebuilds the reader on the page on screen
        settle()
        compact = true // a window resize re-lays out and redraws the page
        settle()
        assertTrue("Redrawn at the new size: $requested", requested.map { it.second }.distinct().size >= 2)
        compose.onNodeWithContentDescription("Page 4 of 6").performTouchInput {
            pinch(center - Offset(40f, 0f), center - Offset(250f, 0f), center + Offset(40f, 0f), center + Offset(250f, 0f))
        }
        settle()
        reading.flush()
        assertTrue("Nothing recorded: ${reading.recorded}", reading.recorded.isEmpty())
        assertEquals(restored, reading.saved())
        assertTrue(reading.server.received.isEmpty())
    }

    @Test
    fun `a saved place whose page fails to draw stays saved through opening and rebuilding`() {
        val failing = Reading(pageCount = 6, start = 3, locate = pdf(6))
        val restored = failing.saved()
        show(failing, drawn(failing = setOf(3)))
        compose.onNodeWithText("Couldn't show page 4. This page's image is damaged.").assertIsDisplayed()
        generation++
        settle()
        failing.flush()
        assertTrue(failing.recorded.isEmpty())
        assertEquals(restored, failing.saved())
        assertTrue(failing.server.received.isEmpty())
        failing.progress.turn(1)
        settle()
        assertEquals(4, failing.savedPage())
    }

    @Test
    fun `a damaged comic page from a real archive is skipped by key, and the comic's place follows`() {
        val built = ComicFixtures.zip(
            listOf(
                ComicFixtures.Entry("01.png", PageFixtures.png(0)),
                // The archive's checksum doesn't match the stored image: it opens, but this page can't be read.
                ComicFixtures.Entry("02.jpg", PageFixtures.jpeg(1), method = 0, crc = 0x1234_5678L),
                ComicFixtures.Entry("03.png", PageFixtures.png(2)),
                ComicFixtures.Entry("04.png", PageFixtures.png(3)),
            ),
        )
        val file = File(folder.root, "c.cbz").apply { writeBytes(built.bytes) }
        val asset = ComicFixtures.asset("a", built)
        val order: List<ComicPage> = ComicFixtures.order("a", built.items).validate(asset)
        val pages = ComicPages(ComicArchive.open(file, order, file.length())).also { comic = it }
        val reading = Reading(pageCount = pages.pageCount, start = 0) { index -> PageLocators.comic(order[index], order.size) }
        show(reading, { index, width, height -> runBlocking { pages.render(index, width, height) } }, format = ReadingFormat.CBZ, theme = ReaderTheme.NIGHT)

        reading.progress.turn(1)
        settle()
        compose.onNodeWithText("Couldn't show page 2. Page 2 is damaged (its checksum doesn't match)").assertIsDisplayed()
        shot("16-comic-page-failed-night")
        assertTrue(reading.recorded.isEmpty())
        assertEquals(order[0].href, reading.saved().position!!.locator!!["href"]!!.jsonPrimitive.content)

        nowMs += 2_000
        reading.progress.turn(1)
        settle()
        assertEquals(listOf(2 to nowMs), reading.recorded)
        val place = reading.saved().position!!.locator!!
        assertEquals(order[2].href, place["href"]!!.jsonPrimitive.content)
        assertEquals(3, place["locations"]!!.jsonObject["position"]!!.jsonPrimitive.int)
        reading.flush()
        assertEquals(order[2].href, reading.server.received.single().locator!!["href"]!!.jsonPrimitive.content)
        assertEquals(ActivityTime.format(nowMs), reading.server.received.single().observedAt)
    }

    private companion object {
        const val HOUR = 3_600_000L
        const val OPENED_EARLIER = TEST_EPOCH - 86_400_000L
    }
}
