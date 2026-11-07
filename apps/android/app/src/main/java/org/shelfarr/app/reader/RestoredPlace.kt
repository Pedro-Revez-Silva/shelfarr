package org.shelfarr.app.reader

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Marks a session that opened at the beginning, before Readium has said where that is. */
internal val NO_PLACE = JsonObject(emptyMap())

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
    val opened = start.progression() ?: 0.0
    val now = current.progression() ?: 0.0
    return now >= opened - RESTORE_BEFORE && now <= opened + RESTORE_AFTER
}

private fun JsonObject.string(key: String): String? = runCatching { this[key]?.jsonPrimitive?.contentOrNull }.getOrNull()

private fun JsonObject.progression(): Double? =
    runCatching { this["locations"]?.jsonObject?.get("progression")?.jsonPrimitive?.doubleOrNull }.getOrNull()
