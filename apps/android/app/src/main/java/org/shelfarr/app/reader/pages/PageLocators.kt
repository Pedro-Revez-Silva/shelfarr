package org.shelfarr.app.reader.pages

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.shelfarr.app.core.ComicPage
import org.shelfarr.app.core.PDF_MEDIA_TYPE

/** Where a fixed-layout book should open, from its saved locator. */
sealed interface PageRestore {
    /** Nothing saved: page one, with nothing written. */
    data object Beginning : PageRestore

    data class At(val index: Int) : PageRestore

    /**
     * The saved place can't be shown in this file. It is kept as the saved place, and the
     * reader chooses where to look; opening never replaces it with page one.
     */
    data class Invalid(val saved: String) : PageRestore
}

/**
 * Durable page locators shared with the web and iOS readers.
 *
 * - PDF: `href` `document.pdf`, `type` `application/pdf`, a one-based `locations.position`
 *   (at most 100,000) and `fragments: ["page=N"]`.
 * - CBZ: `href` and `type` of item N in the generation's reading order, `position` N.
 *
 * `totalProgression` is `(N - 1) / count`, as Readium's position lists use: the start of
 * the page within the whole book.
 */
object PageLocators {
    const val PDF_HREF = "document.pdf"
    const val MAX_POSITION = 100_000

    fun pdf(index: Int, count: Int): JsonObject = buildJsonObject {
        val position = index + 1
        put("href", PDF_HREF)
        put("type", PDF_MEDIA_TYPE)
        putJsonObject("locations") {
            put("position", position)
            put("totalProgression", progression(index, count))
            putJsonArray("fragments") { add("page=$position") }
        }
    }

    fun comic(page: ComicPage, count: Int): JsonObject = buildJsonObject {
        put("href", page.href)
        put("type", page.mediaType)
        putJsonObject("locations") {
            put("position", page.position)
            put("totalProgression", progression(page.position - 1, count))
        }
    }

    private fun progression(index: Int, count: Int): Double = if (count <= 0) 0.0 else (index.toDouble() / count).coerceIn(0.0, 1.0)

    fun restorePdf(locator: JsonObject?, pageCount: Int): PageRestore {
        if (locator == null) return PageRestore.Beginning
        val position = locator.position()
        val described = position?.let { "page $it" } ?: "a place this PDF can't show"
        if (locator.string("href")?.trimStart('/') != PDF_HREF) return PageRestore.Invalid(described)
        locator.string("type")?.let { if (it != PDF_MEDIA_TYPE) return PageRestore.Invalid(described) }
        if (position == null || position !in 1..MAX_POSITION || position > pageCount) return PageRestore.Invalid(described)
        return PageRestore.At(position.toInt() - 1)
    }

    fun restoreComic(locator: JsonObject?, pages: List<ComicPage>): PageRestore {
        if (locator == null) return PageRestore.Beginning
        val position = locator.position()
        val described = position?.let { "page $it" } ?: "a page this comic doesn't have"
        if (position == null || position !in 1..pages.size) return PageRestore.Invalid(described)
        val page = pages[position.toInt() - 1]
        if (locator.string("href") != page.href) return PageRestore.Invalid(described)
        locator.string("type")?.let { if (it != page.mediaType) return PageRestore.Invalid(described) }
        return PageRestore.At(position.toInt() - 1)
    }

    private fun JsonObject.string(key: String): String? =
        runCatching { (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull }.getOrNull()

    /** A whole-number position only: `3.5` or `"3"` is not a page. */
    private fun JsonObject.position(): Long? = runCatching {
        val value = this["locations"]?.jsonObject?.get("position") as? JsonPrimitive ?: return null
        if (value.isString) return null
        value.longOrNull
    }.getOrNull()
}
