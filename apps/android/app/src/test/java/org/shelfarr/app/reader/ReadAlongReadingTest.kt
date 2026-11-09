package org.shelfarr.app.reader

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.shelfarr.app.core.LocalProgress
import org.shelfarr.app.core.NarrationPlace
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ReadAlong
import org.shelfarr.app.core.ReadAlongFixtures
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.TEST_EPOCH
import org.shelfarr.app.core.ActivityTime

/** What counts as reading next to narration, and what Play and the audiobook offer decide. */
class ReadAlongReadingTest {
    private fun place(href: String, progression: Double? = null, fragment: String? = null, generation: String? = null): JsonObject = buildJsonObject {
        put("href", href)
        put("type", "application/xhtml+xml")
        putJsonObject("locations") {
            progression?.let { put("progression", it) }
            fragment?.let { put("fragments", buildJsonArray { add(JsonPrimitive(it)) }) }
            generation?.let { putJsonObject("readAlong") { put("generation", it); put("audio", 0); put("offset_ms", 13_743) } }
        }
    }

    @Test
    fun `opening at a narration place is not reading, wherever its page is`() {
        // Saved by element with no progression (read-along, or another reader's fragment).
        val saved = place("OEBPS/chapter2.xhtml", fragment = "c6", generation = ReadAlongFixtures.GENERATION)
        val restoration = ReadingRestoration(saved)
        // Readium lands mid-chapter, on the page holding the element.
        assertFalse(restoration.isReading(place("OEBPS/chapter2.xhtml", progression = 0.62)))
        assertFalse(restoration.isReading(place("OEBPS/chapter2.xhtml", progression = 0.62)))
        assertTrue(restoration.isReading(place("OEBPS/chapter2.xhtml", progression = 0.7)))
    }

    @Test
    fun `the measured narration page restores silently before a real turn`() {
        // The pagination callback reports the page actually laid out, without the
        // currentLocator flow's synthetic opening value.
        val saved = place("OEBPS/chapter2.xhtml", fragment = "c7", generation = ReadAlongFixtures.GENERATION)
        val restoration = ReadingRestoration(saved)
        val reports = listOf(place("OEBPS/chapter2.xhtml", progression = 0.5), place("OEBPS/chapter2.xhtml", progression = 0.5))
        val read = reports.map(restoration::isReading)
        assertEquals(listOf(false, false), read)
        // Turning on from the restored page is still reading.
        assertTrue(restoration.isReading(place("OEBPS/chapter2.xhtml", progression = 0.75)))
    }

    @Test
    fun `the opened page laid out after Play is not browsing, a page turned from it is`() {
        val fresh = ReadingRestoration(null)
        assertTrue(fresh.isOpening(place("OEBPS/chapter1.xhtml", progression = 0.0)))
        fresh.adopt(place("OEBPS/chapter1.xhtml", progression = 0.0))
        assertFalse(fresh.isOpening(place("OEBPS/chapter1.xhtml", progression = 0.34)))

        val saved = ReadingRestoration(place("OEBPS/chapter2.xhtml", fragment = "c7", generation = ReadAlongFixtures.GENERATION))
        assertFalse(saved.isOpening(place("OEBPS/chapter1.xhtml", progression = 0.0)))
        assertTrue(saved.isOpening(place("OEBPS/chapter2.xhtml", progression = 0.5)))
        saved.adopt(place("OEBPS/chapter2.xhtml", progression = 0.5))
        assertFalse(saved.isOpening(place("OEBPS/chapter2.xhtml", progression = 0.75)))
    }

    @Test
    fun `an exactly restored measured page establishes small backward reading`() {
        val saved = place("OEBPS/chapter1.xhtml", progression = 0.08968609865470852)
        val restoration = ReadingRestoration(saved)
        assertFalse(restoration.isReading(saved))
        assertFalse(restoration.isReading(saved))
        assertTrue(restoration.isReading(place("OEBPS/chapter1.xhtml", progression = 0.08520179372197309)))
    }

    @Test
    fun `a page shown for narration or a layout change becomes the place to move away from`() {
        val restoration = ReadingRestoration(place("OEBPS/chapter1.xhtml", progression = 0.1))
        assertFalse(restoration.isReading(place("OEBPS/chapter1.xhtml", progression = 0.1)))
        assertTrue(restoration.isReading(place("OEBPS/chapter1.xhtml", progression = 0.2)))
        // Following the narration to the next chapter: shown, not read.
        restoration.adopt(place("OEBPS/chapter2.xhtml", progression = 0.0))
        assertFalse(restoration.isReading(place("OEBPS/chapter2.xhtml", progression = 0.0)))
        // Turning on from there, though, is reading again.
        assertTrue(restoration.isReading(place("OEBPS/chapter2.xhtml", progression = 0.1)))
    }

    private val server = (ServerAddress.parse("https://books.example") as ServerAddress.ParseResult.Valid).address
    private val overlay = ReadAlong.read(ReadAlongFixtures.overlayManifest().byteInputStream(), ReadAlongFixtures.EPUB_ID, null, server)

    @Test
    fun `Play from a page starts at the narration that page shows`() {
        // The first narrated element in view, else the next after the page, else the next narrated document.
        assertEquals(3, ReadAlongDecisions.cueForPage(overlay, 0, "c3", null))
        assertEquals(4, ReadAlongDecisions.cueForPage(overlay, 0, null, "c4"))
        assertEquals(5, ReadAlongDecisions.cueForPage(overlay, 0, null, null))
        // A page outside the narrated text, or a document with nothing after, starts at the first cue.
        assertEquals(0, ReadAlongDecisions.cueForPage(overlay, null, null, null))
        assertEquals(0, ReadAlongDecisions.cueForPage(overlay, 1, null, null))
        // An ID that isn't a cue of this document is not trusted.
        assertEquals(5, ReadAlongDecisions.cueForPage(overlay, 0, "c6", null))
    }

    private val now = TEST_EPOCH + 3_600_000

    @Test
    fun `a later audiobook place is offered, never when it agrees or is older`() {
        val ebook = NarrationPlace(0, 4_000, 2, exact = true)
        val later = NarrationPlace(0, 12_000, 6, exact = true)
        assertEquals(later, ReadAlongDecisions.offer(ebook, now - 60_000, later, now - 1_000, now))
        assertNull(ReadAlongDecisions.offer(ebook, now - 1_000, later, now - 60_000, now))
        assertNull(ReadAlongDecisions.offer(ebook, now - 60_000, ebook.copy(offsetMs = 4_500), now - 1_000, now))
        // Unknown or implausible audiobook times never claim to be later.
        assertNull(ReadAlongDecisions.offer(ebook, now - 60_000, later, null, now))
        assertNull(ReadAlongDecisions.offer(ebook, null, later, now + ActivityTime.FUTURE_TOLERANCE_MS + 1, now))
        // With no narration place for the text, the audiobook's place is offered as it is.
        assertEquals(later, ReadAlongDecisions.offer(null, now - 1_000, later, null, now))
        assertNull(ReadAlongDecisions.offer(ebook, now, null, now, now))
    }

    @Test
    fun `the audiobook's newest known place is this device's unsynced one or the server's, by time`() {
        val mine = LocalProgress("a", SavedPosition("lh-1", positionSeconds = 3.0), dirty = true, observedAtEpochMs = now - 10_000)
        val theirs = Progress("lh-2", positionSeconds = 1.0, version = 4, observedAt = ActivityTime.format(now - 5_000))
        assertEquals(SavedPosition("lh-2", positionSeconds = 1.0) to now - 5_000, ReadAlongDecisions.audiobookPlace(mine, theirs, now))
        val newer = mine.copy(observedAtEpochMs = now - 1_000)
        assertEquals(newer.position to newer.observedAtEpochMs, ReadAlongDecisions.audiobookPlace(newer, theirs, now))
        assertEquals(mine.position to mine.observedAtEpochMs, ReadAlongDecisions.audiobookPlace(mine, null, now))
        assertEquals(SavedPosition("lh-2", positionSeconds = 1.0) to now - 5_000, ReadAlongDecisions.audiobookPlace(null, theirs, now))
        assertNull(ReadAlongDecisions.audiobookPlace(null, null, now))
    }

    @Test
    fun `narration scripts carry IDs as data, never as code`() {
        val script = NarrationScripts.pageCues(listOf("c1", "x'); alert(1); ('"))
        assertTrue(script.contains("[\"c1\",\"x'); alert(1); ('\"]"))
        assertTrue(NarrationScripts.isVisible("a\"b").contains("(\"a\\\"b\")"))
        assertEquals("v:c3", NarrationScripts.decode("\"v:c3\""))
        assertEquals("", NarrationScripts.decode("\"\""))
        assertEquals("1", NarrationScripts.decode("1"))
        assertNull(NarrationScripts.decode(null))
    }

    @Test
    fun `speeds read as the controls name them`() {
        assertEquals(listOf("0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"), ReaderSettings.NarrationSpeeds.map(::speedLabel))
    }
}
