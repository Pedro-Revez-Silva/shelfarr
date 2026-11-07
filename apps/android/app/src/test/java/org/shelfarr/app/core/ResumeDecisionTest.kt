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
    fun `offline EPUB resumes clean local progress newer than the download snapshot`() {
        val decision = ResumeDecision.decide(book, server(1), local(dirty = false, base = 4), offline = true)
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.2)), 4), decision)
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.2)), 4),
            ResumeDecision.decide(book, null, local(dirty = false, base = 4), offline = true))
    }

    @Test
    fun `offline audio resumes the latest synced local track and time`() {
        val tracks = listOf(Asset("t1", format = "mp3", contentUrl = "/1"), Asset("t2", format = "mp3", contentUrl = "/2", position = 1))
        val audio = Publication("p", "T", bookType = BookType.AUDIOBOOK, assets = tracks)
        val position = SavedPosition("t2", positionSeconds = 42.0)
        val saved = LocalProgress("p", position = position, baseVersion = 5)
        assertEquals(ResumeDecision.Continue(position, 5), ResumeDecision.decide(audio,
            Progress("t1", positionSeconds = 10.0, version = 1), saved, offline = true))
    }

    @Test
    fun `offline local progress on a different generation is still refused`() {
        assertEquals(ResumeDecision.EditionChanged(4), ResumeDecision.decide(book,
            server(4, assetId = "old"), local(dirty = false, base = 4, assetId = "old"), offline = true))
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

    private val now = 1_794_042_000_000L
    private fun time(offsetMs: Long) = ActivityTime.format(now + offsetMs)

    private fun timedServer(version: Int, offsetMs: Long?, total: Double = 0.5, mutation: String? = "other") =
        Progress("a1", locator(total), version = version, clientMutationId = mutation, observedAt = offsetMs?.let(::time))

    private fun timedLocal(offsetMs: Long?, base: Int = 3, total: Double = 0.2, pending: PendingMutation? = null, dirty: Boolean = true) =
        local(dirty = dirty, base = base, total = total).copy(observedAtEpochMs = offsetMs?.let { now + it }, pending = pending)

    @Test
    fun `later local reading wins over an older server place without asking`() {
        val decision = ResumeDecision.decide(book, timedServer(5, -60_000), timedLocal(-1_000), now = now)
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.2)), 5, now - 1_000), decision)
    }

    @Test
    fun `later reading elsewhere wins over unsent local reading, even further back in the book`() {
        val decision = ResumeDecision.decide(book, timedServer(5, -1_000, total = 0.1), timedLocal(-60_000, total = 0.9), now = now)
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.1)), 5, now - 1_000), decision)
    }

    @Test
    fun `unknown, equal or implausible times still ask`() {
        val cases = listOf(
            timedServer(5, null) to timedLocal(-1_000),
            timedServer(5, -1_000) to timedLocal(null),
            timedServer(5, -1_000) to timedLocal(-1_000),
            timedServer(5, 10 * 60_000) to timedLocal(-1_000),
            timedServer(5, -1_000) to timedLocal(-now + 1_000),
        )
        for ((server, local) in cases) {
            assertTrue("$server vs $local", ResumeDecision.decide(book, server, local, now = now) is ResumeDecision.Choose)
        }
    }

    @Test
    fun `a place the server refused is never settled automatically`() {
        val decision = ResumeDecision.decide(book, timedServer(5, -60_000), timedLocal(-1_000).copy(rejected = true), now = now)
        assertTrue(decision is ResumeDecision.Choose)
    }

    @Test
    fun `a pending write the server already holds is not a conflict`() {
        val pending = PendingMutation(SavedPosition("a1", locator(0.2)), 3, "mine", now - 5_000)
        val server = timedServer(4, -5_000, total = 0.2, mutation = "mine")
        val decision = ResumeDecision.decide(book, server, timedLocal(-5_000, pending = pending, dirty = false), now = now)
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.2)), 4, now - 5_000), decision)
    }

    @Test
    fun `a clean device resumes the server place with its activity time`() {
        val decision = ResumeDecision.decide(book, timedServer(5, -1_000), timedLocal(-60_000, dirty = false), now = now)
        assertEquals(ResumeDecision.Continue(SavedPosition("a1", locator(0.5)), 5, now - 1_000), decision)
    }

    @Test
    fun `version zero means no saved state`() {
        assertEquals(ResumeDecision.Beginning, ResumeDecision.decide(book, Progress("a1", version = 0), null))
    }
}
