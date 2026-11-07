package org.shelfarr.app.reader

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RestoredPlaceTest {
    private fun locator(href: String, progression: Double? = null, extra: String? = null): JsonObject = buildJsonObject {
        put("href", href)
        put("type", "application/xhtml+xml")
        putJsonObject("locations") {
            progression?.let { put("progression", it) }
            extra?.let { put("position", 7) }
        }
    }

    @Test
    fun `Readium reporting the opened place is not reading`() {
        assertTrue(isRestoredPlace(locator("OEBPS/c2.xhtml", 0.43), locator("OEBPS/c2.xhtml", 0.43, extra = "x")))
        // It may land at the start of the page holding the saved progression.
        assertTrue(isRestoredPlace(locator("OEBPS/c2.xhtml", 0.437), locator("OEBPS/c2.xhtml", 0.42)))
        assertTrue(isRestoredPlace(locator("OEBPS/c2.xhtml"), locator("/OEBPS/c2.xhtml", 0.0)))
    }

    @Test
    fun `moving to another page or chapter is reading`() {
        assertFalse(isRestoredPlace(locator("OEBPS/c2.xhtml", 0.43), locator("OEBPS/c2.xhtml", 0.5)))
        // Even one short page forward in a long chapter.
        assertFalse(isRestoredPlace(locator("OEBPS/c2.xhtml", 0.43), locator("OEBPS/c2.xhtml", 0.436)))
        assertFalse(isRestoredPlace(locator("OEBPS/c2.xhtml"), locator("OEBPS/c2.xhtml", 0.01)))
        assertFalse(isRestoredPlace(locator("OEBPS/c2.xhtml", 0.43), locator("OEBPS/c2.xhtml", 0.3)))
        assertFalse(isRestoredPlace(locator("OEBPS/c1.xhtml", 0.0), locator("OEBPS/c2.xhtml", 0.0)))
        assertFalse(isRestoredPlace(locator("OEBPS/c1.xhtml", 0.0), JsonObject(emptyMap())))
    }
}
