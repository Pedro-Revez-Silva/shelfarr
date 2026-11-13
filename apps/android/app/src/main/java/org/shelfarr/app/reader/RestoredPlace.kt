package org.shelfarr.app.reader

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Initial page-start tolerance applies only until the first restored report. */
internal class ReadingRestoration(opening: JsonObject?) {
    private var anchor = opening
    private var established = false
    private var reading = false

    /**
     * [current] is on screen for a reason other than reading (following narration, a
     * layout change, a place shown on request). It becomes the place to move away from:
     * only a later, different report is reading again.
     */
    fun adopt(current: JsonObject) {
        anchor = current
        established = true
        reading = false
    }

    /**
     * True while [current] is still Readium settling on the place this session opened at,
     * before anything else was shown: the page being restored, not the reader moving.
     */
    fun isOpening(current: JsonObject): Boolean {
        if (established) return false
        val start = anchor
        return start == null || isRestoredPlace(start, current)
    }

    fun isReading(current: JsonObject): Boolean {
        if (reading) return true
        val start = anchor
        if (!established && (start == null || isRestoredPlace(start, current))) {
            anchor = current
            established = true
            return false
        }
        if (established && start != null &&
            current.string("href")?.trimStart('/') == start.string("href")?.trimStart('/') &&
            current.progression() == start.progression()
        ) return false
        reading = true
        return true
    }
}

/**
 * Readium lands on the start of the page holding a saved progression, so a restored
 * report can be up to a page earlier, never later. Any forward page turn is reading.
 */
private const val RESTORE_BEFORE = 0.02
private const val RESTORE_AFTER = 0.0005

/**
 * True when [current] is Readium reporting the place a session opened at, rather than
 * the reader moving. Restoring a place is not reading, so it must not become a new
 * checkpoint with a new activity time.
 */
internal fun isRestoredPlace(start: JsonObject, current: JsonObject): Boolean {
    val href = current.string("href") ?: return false
    if (href.trimStart('/') != start.string("href")?.trimStart('/')) return false
    // A place saved by element (read-along, or another reader's fragment) has no
    // progression: Readium opens on the page holding that element, wherever it is.
    if (start.progression() == null && start.hasFragment()) return true
    val opened = start.progression() ?: 0.0
    val now = current.progression() ?: 0.0
    return now >= opened - RESTORE_BEFORE && now <= opened + RESTORE_AFTER
}

private fun JsonObject.string(key: String): String? = runCatching { this[key]?.jsonPrimitive?.contentOrNull }.getOrNull()

private fun JsonObject.hasFragment(): Boolean = runCatching {
    (this["locations"]?.jsonObject?.get("fragments") as? kotlinx.serialization.json.JsonArray)?.isNotEmpty() == true
}.getOrDefault(false)

private fun JsonObject.progression(): Double? =
    runCatching { this["locations"]?.jsonObject?.get("progression")?.jsonPrimitive?.doubleOrNull }.getOrNull()
