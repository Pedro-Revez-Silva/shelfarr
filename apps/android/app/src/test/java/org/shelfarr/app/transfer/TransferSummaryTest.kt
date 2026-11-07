package org.shelfarr.app.transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DownloadProblem
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.DownloadedFile
import org.shelfarr.app.core.Publication

class TransferSummaryTest {
    private fun record(id: String, state: DownloadState, done: Long, size: Long = 10_000_000, problem: DownloadProblem? = null, at: Long = 0) =
        DownloadRecord(
            id,
            Publication(id, "Title $id", bookType = BookType.EBOOK, assets = listOf(Asset("$id-a", contentUrl = "/x"))),
            listOf(DownloadedFile("$id-a", "0.epub", size, bytesDone = done)),
            state,
            problem,
            updatedAtEpochMs = at,
        )

    @Test
    fun `one download names its title with an honest amount`() {
        val summary = transferSummary(listOf(record("a", DownloadState.DOWNLOADING, 2_500_000)))!!
        assertEquals("Downloading “Title a”", summary.title)
        assertEquals("3 MB of 10 MB", summary.text.replace(",", "."))
        assertEquals(0.25f, summary.fraction!!, 0.001f)
        assertEquals(listOf("a"), summary.activeIds)
    }

    @Test
    fun `several downloads are counted, waiting ones say so, and finished ones are left out`() {
        val summary = transferSummary(
            listOf(
                record("a", DownloadState.QUEUED, 0, at = 2),
                record("b", DownloadState.QUEUED, 1_000_000, at = 1),
                record("c", DownloadState.READY, 10_000_000),
            ),
        )!!
        assertEquals("Downloading 2 titles", summary.title)
        assertTrue(summary.text, summary.text.startsWith("Waiting to continue"))
        assertEquals(listOf("b", "a"), summary.activeIds)
    }

    @Test
    fun `an unknown size gives no fake bar`() {
        val summary = transferSummary(listOf(record("a", DownloadState.DOWNLOADING, 500, size = 0)))!!
        assertNull(summary.fraction)
        assertTrue(summary.text.endsWith("so far"))
    }

    @Test
    fun `nothing active means no progress notification`() {
        assertNull(transferSummary(listOf(record("a", DownloadState.READY, 10_000_000))))
    }

    @Test
    fun `results name what finished and what needs attention`() {
        val done = record("a", DownloadState.READY, 10_000_000)
        val stopped = record("b", DownloadState.FAILED, 0, problem = DownloadProblem.STORAGE)
        assertEquals("Downloaded “Title a”", transferResult(listOf(done), emptyList())!!.first)
        assertEquals("“Title b”: Not enough space", transferResult(emptyList(), listOf(stopped))!!.first)
        assertTrue(transferResult(listOf(done), listOf(stopped))!!.second.contains("1 need attention"))
        assertNull(transferResult(emptyList(), emptyList()))
    }
}
