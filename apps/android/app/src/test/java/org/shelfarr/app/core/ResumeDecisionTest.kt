package org.shelfarr.app.core

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ResumeDecisionTest {
    private val epub = Asset(id = "a1", format = "epub", contentUrl = "/c")
    private val book = Publication("p", "T", bookType = BookType.EBOOK, assets = listOf(epub))

    private fun locator(total: Double) = buildJsonObject {
        put("href", "c.xhtml")
        putJsonObject("locations") { put("totalProgression", total) }
    }

    private fun server(version: Int, assetId: String = "a1", total: Double = 0.5) =
        Progress(assetId, locator(total), version = version)

    private fun local(dirty: Boolean, base: Int, assetId: String = "a1", total: Double = 0.2) = LocalProgress(
        publicationId = "p",
        position = SavedPosition(assetId, locator(total)),
        baseVersion = base,
        dirty = dirty,
    )

    @Test
    fun `nothing saved opens at the beginning`() {
        assertEquals(ResumeDecision.Beginning, ResumeDecision.decide(book, null, null))
    }

    @Test
    fun `server progress wins over a clean local copy`() {
        val decision = ResumeDecision.decide(book, server(4), local(dirty = false, base = 3))
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.5)), 4), decision)
    }

    @Test
    fun `unsent local reading continues when the server has not moved`() {
        val decision = ResumeDecision.decide(book, server(3), local(dirty = true, base = 3))
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.2)), 3), decision)
    }

    @Test
    fun `offline-only reading continues with no server state`() {
        val decision = ResumeDecision.decide(book, null, local(dirty = true, base = 0))
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.2)), 0), decision)
    }

    @Test
    fun `newer server state against unsent reading asks the reader`() {
        val decision = ResumeDecision.decide(book, server(5), local(dirty = true, base = 3))
        assertTrue(decision is ResumeDecision.Choose)
    }

    @Test
    fun `identical places never ask`() {
        val decision = ResumeDecision.decide(book, server(5, total = 0.2), local(dirty = true, base = 3))
        assertTrue(decision is ResumeDecision.Continue)
    }

    @Test
    fun `a position on a replaced asset is not applied`() {
        val decision = ResumeDecision.decide(book, server(5, assetId = "old"), null)
        assertEquals(ResumeDecision.EditionChanged(5), decision)
    }

    @Test
    fun `unsent local reading on a replaced asset is dropped too`() {
        val decision = ResumeDecision.decide(book, server(5, assetId = "old"), local(dirty = true, base = 5, assetId = "old"))
        assertEquals(ResumeDecision.EditionChanged(5), decision)
    }

    @Test
    fun `audio resumes the saved track only if the track still exists`() {
        val tracks = listOf(Asset("t1", format = "mp3", contentUrl = "/1"), Asset("t2", format = "mp3", contentUrl = "/2", position = 1))
        val audio = Publication("p", "T", bookType = BookType.AUDIOBOOK, assets = tracks)
        val kept = ResumeDecision.decide(audio, Progress("t2", positionSeconds = 10.0, version = 2), null)
        assertEquals(ResumeDecision.Continue(SavedPosition("t2", positionSeconds = 10.0), 2), kept)
        val gone = ResumeDecision.decide(audio, Progress("t9", positionSeconds = 10.0, version = 2), null)
        assertEquals(ResumeDecision.EditionChanged(2), gone)
    }

    @Test
    fun `version zero means no saved state`() {
        assertEquals(ResumeDecision.Beginning, ResumeDecision.decide(book, Progress("a1", version = 0), null))
    }
}
