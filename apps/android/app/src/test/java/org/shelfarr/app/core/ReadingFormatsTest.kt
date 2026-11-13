package org.shelfarr.app.core

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadingFormatsTest {
    private val epub = Asset("e", "b.epub", "application/epub+zip", "epub", 1_000, "/c/e", position = 0)
    private val pdf = Asset("p", "b.pdf", PDF_MEDIA_TYPE, "pdf", 2_000, "/c/p", position = 1)
    private val cbz = Asset("z", "b.cbz", CBZ_MEDIA_TYPE, "cbz", 3_000, "/c/z", position = 2, pageCount = 4, readingOrderUrl = "/ro/z")
    private fun book(vararg assets: Asset, progress: Progress? = null) =
        Publication("b", "Book", bookType = BookType.EBOOK, assets = assets.toList(), progress = progress)

    @Test
    fun `an older server's EPUB-only JSON decodes exactly as before`() {
        val json = """{"id":"b","title":"T","book_type":"ebook","assets":[
            {"id":"e","filename":"b.epub","media_type":"application/epub+zip","format":"epub","size_bytes":10,"content_url":"/c/e"}]}"""
        val publication = ApiJson.decodeFromString<Publication>(json)
        assertNull(publication.contentKind)
        assertNull(publication.assets.single().pageCount)
        assertNull(publication.assets.single().readingOrderUrl)
        assertEquals(listOf(publication.epubAsset), publication.readingAssets)
        assertEquals(listOf("e"), publication.playableAssets.map { it.id })
        assertEquals(ServerFacts(), ApiJson.decodeFromString<ServerFacts>("{}"))
    }

    @Test
    fun `a capable server's new fields decode, and graphic records stay ebooks`() {
        val json = """{"id":"b","title":"T","book_type":"ebook","content_kind":"graphic","assets":[
            {"id":"z","filename":"b.cbz","media_type":"application/vnd.comicbook+zip","format":"cbz","size_bytes":10,
             "content_url":"/c/z","page_count":12,"reading_order_url":"/api/consumer/v1/library/b/assets/z/reading_order"}]}"""
        val publication = ApiJson.decodeFromString<Publication>(json)
        assertEquals(BookType.EBOOK, publication.bookType)
        assertTrue(publication.isGraphic)
        assertEquals(12, publication.assets.single().pageCount)
        assertEquals(ReadingFormat.CBZ, publication.readingAssets.single().readingFormat)
        val facts = ApiJson.decodeFromString<ServerFacts>("""{"consumer_features":["requests"],"reader_formats":["epub","pdf","cbz"]}""")
        assertEquals(listOf("epub", "pdf", "cbz"), facts.readerFormats)
    }

    @Test
    fun `one file per format in server order, and unusable files are not offered`() {
        val second = epub.copy(id = "e2", position = 5)
        assertEquals(listOf("e", "p", "z"), book(cbz, pdf, second, epub).readingAssets.map { it.id })
        assertEquals("e", book(cbz, pdf, second, epub).epubAsset?.id)
        assertTrue(book(cbz.copy(readingOrderUrl = null)).readingAssets.isEmpty())
        assertTrue(book(pdf.copy(sizeBytes = ReadingFormat.PDF.maxBytes + 1)).readingAssets.isEmpty())
        assertTrue(book(cbz.copy(sizeBytes = ReadingFormat.CBZ.maxBytes + 1)).readingAssets.isEmpty())
        // Audio and unknown files never become reading formats.
        assertTrue(book(Asset("m", "a.mp3", "audio/mpeg", "mp3", 1, "/m")).readingAssets.isEmpty())
        // Media type alone is enough when the format is blank.
        assertEquals(ReadingFormat.PDF, pdf.copy(format = "").readingFormat)
        assertEquals("epub,pdf,cbz", READER_FORMATS)
    }

    @Test
    fun `a saved place keeps its format, a download is next, several formats ask`() {
        val mixed = book(epub, pdf, cbz)
        assertEquals(FormatChoice.Use(pdf), FormatChoice.decide(mixed, SavedPosition("p", buildJsonObject { put("href", "document.pdf") })))
        assertEquals(FormatChoice.Use(cbz), FormatChoice.decide(mixed, null, downloadedAssetId = "z"))
        assertEquals(FormatChoice.Ask(listOf(epub, pdf, cbz)), FormatChoice.decide(mixed, null))
        // A place on a file this edition no longer has doesn't pick anything.
        assertEquals(FormatChoice.Ask(listOf(epub, pdf, cbz)), FormatChoice.decide(mixed, SavedPosition("gone")))
        assertEquals(FormatChoice.Use(pdf), FormatChoice.decide(book(pdf), null))
        assertEquals(FormatChoice.None, FormatChoice.decide(book(), null))
    }

    @Test
    fun `downloads keep their format and legacy records are EPUB`() {
        val mixed = book(epub, pdf)
        assertEquals(listOf(epub), downloadableAssets(mixed))
        assertEquals(listOf(pdf), downloadableAssets(mixed, ReadingFormat.PDF))
        assertEquals(listOf(pdf), downloadableAssets(book(epub, pdf, progress = Progress("p", version = 1))))
        assertTrue(downloadableAssets(mixed, ReadingFormat.CBZ).isEmpty())

        val legacy = DownloadRecord("b", book(epub), listOf(DownloadedFile("e", "000-x.epub", 1_000, complete = true)), DownloadState.READY)
        assertEquals(ReadingFormat.EPUB, legacy.pinnedFormat)
        assertTrue("A PDF appearing doesn't make an EPUB download stale", legacy.matches(mixed))
        val chosen = DownloadRecord("b", mixed, listOf(DownloadedFile("p", "000-y.pdf", 2_000, complete = true)), DownloadState.READY, format = "pdf")
        assertEquals(ReadingFormat.PDF, chosen.pinnedFormat)
        assertTrue(chosen.matches(mixed))
        assertTrue("A replaced PDF is a new edition", !chosen.matches(book(epub, pdf.copy(id = "p2"))))
    }

    @Test
    fun `a saved PDF place resumes in the PDF, never in the EPUB`() {
        val locator = buildJsonObject { put("href", "document.pdf"); put("type", PDF_MEDIA_TYPE) }
        val mixed = book(epub, pdf, progress = Progress("p", locator, version = 3))
        val decision = ResumeDecision.decide(mixed, mixed.progress, null)
        assertTrue(decision is ResumeDecision.Continue)
        assertEquals("p", (decision as ResumeDecision.Continue).position.assetId)
        // EPUB-only books decide exactly as before.
        val epubOnly = book(epub, progress = Progress("p", locator, version = 3))
        assertEquals(ResumeDecision.EditionChanged(3), ResumeDecision.decide(epubOnly, epubOnly.progress, null))
    }
}
