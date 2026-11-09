package org.shelfarr.app.reader.pages

import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The page on screen and the reading place are separate; only a page seen moves the place. */
class PageProgressTest {
    private val recorded = mutableListOf<Pair<Int, Long>>()

    private fun progress(pageCount: Int = 10, start: Int = 0) =
        PageProgress().apply { open(pageCount, start) { index, at -> recorded += index to at } }

    @Test
    fun `restoring is not reading, and seeing the restored page again writes nothing`() {
        val pages = progress(start = 4)
        assertEquals(4, pages.page.value)
        pages.onSettled(4)
        pages.onShown(4, 100)
        assertTrue(recorded.isEmpty())
        assertEquals(4, pages.readingPlace)
    }

    @Test
    fun `a settled page that is never drawn moves the pager but not the place`() {
        val pages = progress(start = 2)
        pages.onSettled(3)
        assertEquals(3, pages.page.value)
        assertEquals(2, pages.readingPlace)
        assertTrue(recorded.isEmpty())
        pages.onSettled(4)
        pages.onShown(4, 200)
        assertEquals(listOf(4 to 200L), recorded)
        assertEquals(4, pages.readingPlace)
    }

    @Test
    fun `turning starts from the page on screen, so a failed page never traps the reader`() = runTest(UnconfinedTestDispatcher()) {
        val pages = progress(pageCount = 5, start = 0)
        val commands = mutableListOf<PageCommand>()
        val collecting = launch { pages.commands.take(3).toList(commands) }
        pages.onSettled(1) // drawn or not, the pager is here
        pages.turn(1)
        pages.onSettled(2)
        pages.turn(-1)
        pages.onSettled(1)
        pages.turn(-1)
        collecting.join()
        assertEquals(listOf(2, 1, 0), commands.map { it.index })
        assertTrue(commands.all { it.animate })
    }

    @Test
    fun `turning past either end and reports outside the book do nothing`() = runTest(UnconfinedTestDispatcher()) {
        val pages = progress(pageCount = 3, start = 2)
        val commands = mutableListOf<PageCommand>()
        backgroundScope.launch { pages.commands.toList(commands) }
        pages.onSettled(7)
        pages.onShown(-1, 1)
        pages.onShown(3, 1)
        assertEquals(2, pages.page.value)
        assertTrue(recorded.isEmpty())
        pages.turn(1) // already on the last page
        pages.turn(-1)
        assertEquals(listOf(1), commands.map { it.index })
    }

    @Test
    fun `choosing a saved place, as for an invalid place or another device's, is looking, not reading`() = runTest(UnconfinedTestDispatcher()) {
        val pages = progress(pageCount = 214, start = 0)
        val commands = mutableListOf<PageCommand>()
        val collecting = launch { pages.commands.take(1).toList(commands) }
        pages.goToSaved(213)
        collecting.join()
        assertEquals(listOf(PageCommand(213, animate = false)), commands)
        assertEquals(213, pages.page.value)
        pages.onSettled(213)
        pages.onShown(213, 50)
        assertTrue("Arriving at the chosen place writes nothing", recorded.isEmpty())
        // The reader then turns a page, which is reading.
        pages.onSettled(212)
        pages.onShown(212, 60)
        assertEquals(listOf(212 to 60L), recorded)
    }
}
