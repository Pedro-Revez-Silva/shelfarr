package org.shelfarr.app.ui

import androidx.compose.runtime.staticCompositionLocalOf
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.core.ServerAddress

/** The signed-in server, for resolving cover URLs without threading it everywhere. */
val LocalServer = staticCompositionLocalOf<ServerAddress?> { null }

fun formatDuration(milliseconds: Long): String {
    val total = (milliseconds / 1_000).coerceAtLeast(0)
    val hours = total / 3_600
    val minutes = (total % 3_600) / 60
    val seconds = total % 60
    return if (hours > 0) {
        String.format(Locale.ROOT, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        String.format(Locale.ROOT, "%d:%02d", minutes, seconds)
    }
}

fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> String.format(Locale.getDefault(), "%.1f GB", bytes / 1e9)
    bytes >= 1_000_000 -> String.format(Locale.getDefault(), "%.0f MB", bytes / 1e6)
    bytes >= 1_000 -> String.format(Locale.getDefault(), "%.0f KB", bytes / 1e3)
    else -> "$bytes B"
}

/** A saved place in words: a percentage for books, a timestamp for audio. */
fun describePlace(locator: JsonObject?, positionSeconds: Double?): String {
    val total = locator?.get("locations")?.jsonObject?.get("totalProgression")?.jsonPrimitive?.doubleOrNull
    return when {
        total != null -> "${(total * 100).roundToInt()}% through"
        positionSeconds != null -> formatDuration((positionSeconds * 1_000).toLong())
        else -> "Unknown place"
    }
}

/** Short status for a publication in progress, e.g. `42%` or `Track 3 · 12:20`. */
fun Publication.progressLabel(): String? {
    val saved = progress ?: return null
    saved.totalProgression?.let { return "${(it * 100).roundToInt()}%" }
    val time = saved.positionSeconds?.let { formatDuration((it * 1_000).toLong()) } ?: return null
    val tracks = audioAssets
    val index = tracks.indexOfFirst { it.id == saved.assetId }
    return if (tracks.size > 1 && index >= 0) "Track ${index + 1} · $time" else time
}

/** 0–1 through the publication, when that can honestly be worked out. */
fun Publication.progressFraction(): Float? {
    val saved: Progress = progress ?: return null
    saved.totalProgression?.let { return it.toFloat() }
    val tracks = audioAssets
    val index = tracks.indexOfFirst { it.id == saved.assetId }
    return if (tracks.size > 1 && index >= 0) index.toFloat() / tracks.size else null
}

val Publication.primaryActionLabel: String
    get() = when {
        // Finished stays finished: opening it again doesn't promise a restart.
        status == ReadingStatus.FINISHED && bookType == BookType.EBOOK -> "Open book"
        status == ReadingStatus.FINISHED -> "Play audiobook"
        progress?.isUsable == true && bookType == BookType.EBOOK -> "Continue reading"
        progress?.isUsable == true -> "Continue listening"
        bookType == BookType.EBOOK -> "Start reading"
        else -> "Start listening"
    }

val ReadingStatus.label: String
    get() = when (this) {
        ReadingStatus.UNREAD -> "Unread"
        ReadingStatus.IN_PROGRESS -> "In progress"
        ReadingStatus.FINISHED -> "Finished"
    }

/** "just now", "12 min ago", "3 h ago", "yesterday", "4 days ago", or a date, for freshness notes. */
fun formatAgo(epochMs: Long, nowMs: Long = System.currentTimeMillis()): String {
    val minutes = ((nowMs - epochMs).coerceAtLeast(0)) / 60_000
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "$minutes min ago"
        minutes < 24 * 60 -> "${minutes / 60} h ago"
        minutes < 48 * 60 -> "yesterday"
        minutes < 7 * 24 * 60 -> "${minutes / (24 * 60)} days ago"
        else -> java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(epochMs))
    }
}
