package org.shelfarr.app.reader.pages

import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.shelfarr.app.core.ComicPage
import org.shelfarr.app.reader.pages.PageRestore.At
import org.shelfarr.app.reader.pages.PageRestore.Beginning
import org.shelfarr.app.reader.pages.PageRestore.Invalid

class PageLocatorsTest {
    private fun page(position: Int, href: String, type: String = "image/png") =
        ComicPage(position, href, type, href, href.toByteArray(), 10, 10, 0, 0, 0)

    private val comic = listOf(page(1, "01.png"), page(2, "ch%202/02.jpg", "image/jpeg"), page(3, "03.webp", "image/webp"))

    private fun locator(href: String?, type: String?, position: Any?) = buildJsonObject {
        href?.let { put("href", it) }
        type?.let { put("type", it) }
        putJsonObject("locations") {
            when (position) {
                is Int -> put("position", position)
                is Double -> put("position", position)
                is String -> put("position", position)
            }
        }
    }

    @Test
    fun `PDF locators are one-based with the canonical href, type and page fragment`() {
        val json = PageLocators.pdf(index = 4, count = 10)
        assertEquals("document.pdf", json["href"]!!.jsonPrimitive.content)
        assertEquals("application/pdf", json["type"]!!.jsonPrimitive.content)
        val locations = json["locations"]!!.jsonObject
        assertEquals(5, locations["position"]!!.jsonPrimitive.content.toInt())
        assertEquals(0.4, locations["totalProgression"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals(JsonPrimitive("page=5"), locations["fragments"]!!.jsonArray.single())
        assertEquals(0.0, PageLocators.pdf(0, 1)["locations"]!!.jsonObject["totalProgression"]!!.jsonPrimitive.content.toDouble(), 0.0)
    }

    @Test
    fun `comic locators carry the page's exact escaped href and media type`() {
        val json = PageLocators.comic(comic[1], comic.size)
        assertEquals("ch%202/02.jpg", json["href"]!!.jsonPrimitive.content)
        assertEquals("image/jpeg", json["type"]!!.jsonPrimitive.content)
        assertEquals(2, json["locations"]!!.jsonObject["position"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun `restoring a PDF place shows it, or keeps an impossible one for the reader to decide`() {
        assertEquals(Beginning, PageLocators.restorePdf(null, 10))
        assertEquals(At(4), PageLocators.restorePdf(PageLocators.pdf(4, 10), 10))
        assertEquals(At(9), PageLocators.restorePdf(locator("/document.pdf", null, 10), 10))
        assertEquals(Invalid("page 11"), PageLocators.restorePdf(locator("document.pdf", "application/pdf", 11), 10))
        assertEquals(Invalid("page 0"), PageLocators.restorePdf(locator("document.pdf", "application/pdf", 0), 10))
        assertEquals(Invalid("page 100001"), PageLocators.restorePdf(locator("document.pdf", "application/pdf", 100_001), 200_000))
        assertEquals(Invalid("a place this PDF can't show"), PageLocators.restorePdf(locator("document.pdf", "application/pdf", 2.5), 10))
        assertEquals(Invalid("a place this PDF can't show"), PageLocators.restorePdf(locator("document.pdf", "application/pdf", "2"), 10))
        // An EPUB place is never applied to a PDF.
        assertEquals(Invalid("page 2"), PageLocators.restorePdf(locator("OEBPS/c2.xhtml", "application/xhtml+xml", 2), 10))
        assertEquals(Invalid("page 2"), PageLocators.restorePdf(locator("document.pdf", "image/png", 2), 10))
    }

    @Test
    fun `restoring a comic place needs the same page at the same position`() {
        assertEquals(Beginning, PageLocators.restoreComic(null, comic))
        assertEquals(At(1), PageLocators.restoreComic(PageLocators.comic(comic[1], 3), comic))
        assertEquals(At(2), PageLocators.restoreComic(locator("03.webp", null, 3), comic))
        assertEquals(Invalid("page 3"), PageLocators.restoreComic(locator("01.png", "image/png", 3), comic))
        assertEquals(Invalid("page 4"), PageLocators.restoreComic(locator("04.png", "image/png", 4), comic))
        assertEquals(Invalid("page 2"), PageLocators.restoreComic(locator("ch 2/02.jpg", "image/jpeg", 2), comic))
        assertEquals(Invalid("page 1"), PageLocators.restoreComic(locator("01.png", "image/jpeg", 1), comic))
    }
}
