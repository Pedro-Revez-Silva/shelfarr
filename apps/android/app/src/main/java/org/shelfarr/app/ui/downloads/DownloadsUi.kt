package org.shelfarr.app.ui.downloads

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DownloadProblem
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.NarrationState
import org.shelfarr.app.core.ReadAlongSummary
import org.shelfarr.app.core.defaultReadingAsset
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.core.downloadableAssets
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.ProgressRule
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.formatBytes
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** What a download is doing, in words. Partial downloads never read as ready. */
data class DownloadCopy(val title: String, val detail: String, val canRetry: Boolean = false)

/** Read-along narration follows the EPUB, so it's offered only when the book downloads as one. */
private fun defaultIsEpub(publication: Publication): Boolean = defaultReadingAsset(publication)?.isEpub == true

/** The words on a stopped download's retry button. */
fun retryLabel(record: DownloadRecord): String {
    // A ready book's only stopped transfer is its narration.
    val problem = if (record.isReady) record.narrationStopProblem else record.problem
    return when {
        record.state == DownloadState.CANCELLED -> "Download again"
        record.isReady && (problem == DownloadProblem.INTERRUPTED || problem == DownloadProblem.OFFLINE) -> "Resume narration"
        record.isReady -> "Try narration again"
        problem == DownloadProblem.INTERRUPTED || problem == DownloadProblem.OFFLINE -> "Resume"
        else -> "Try again"
    }
}

/**
 * What a download is doing. [narrationShown]: the narration's own words are on screen too
 * (the book's page), so a stopped narration isn't explained twice.
 */
fun downloadCopy(record: DownloadRecord, narrationShown: Boolean = false): DownloadCopy {
    val total = record.bytesTotal
    val amount = if (total != null) "${formatBytes(record.bytesDone)} of ${formatBytes(total)}" else "${formatBytes(record.bytesDone)} so far"
    val kept = if (record.bytesDone > 0) " ${formatBytes(record.bytesDone)} kept." else ""
    return when (record.state) {
        DownloadState.QUEUED -> DownloadCopy("Waiting to download", amount)
        DownloadState.DOWNLOADING -> DownloadCopy(
            record.fraction?.let { "Downloading ${(it * 100).toInt()}%" } ?: "Downloading",
            amount + fileCount(record),
        )
        DownloadState.READY -> if (record.narrationActive) {
            DownloadCopy("Downloaded · fetching narration", "The book opens without a connection; read-along offline needs the narration too.")
        } else if (record.narrationStopProblem != null && record.withNarration && record.narrationStopProblem != DownloadProblem.UNSUPPORTED) {
            DownloadCopy(
                "Downloaded · narration stopped",
                if (narrationShown) "${formatBytes(record.bytesDone)} on this device. Opens without a connection." else "The book opens without a connection. ${narrationStopWords(record.narrationStopProblem)}",
                canRetry = true,
            )
        } else {
            DownloadCopy("Downloaded", "${formatBytes(record.bytesDone)} on this device. Opens without a connection.")
        }
        DownloadState.CANCELLED -> DownloadCopy("Download cancelled", "Nothing is kept on this device.", canRetry = true)
        DownloadState.FAILED -> when (record.problem) {
            DownloadProblem.OFFLINE -> DownloadCopy("Paused: no connection", "Continues when you're back online.$kept", true)
            DownloadProblem.CERTIFICATE -> DownloadCopy("Stopped: can't verify your server", "Its security certificate couldn't be trusted.", true)
            DownloadProblem.SIGN_IN -> DownloadCopy("Stopped: signed out", "Sign in to this account again to continue.$kept")
            DownloadProblem.FORBIDDEN -> DownloadCopy("Not allowed", "This account can't download that file.", true)
            DownloadProblem.NOT_FOUND -> DownloadCopy("No longer on your server", "The file couldn't be found.", true)
            DownloadProblem.SERVER -> DownloadCopy("Your server had a problem", "Tries again shortly, and when you come back to Shelfarr.$kept", true)
            DownloadProblem.REDIRECT -> DownloadCopy("Server moved", "Your server redirected elsewhere, so Shelfarr stopped.", true)
            DownloadProblem.CHANGED -> DownloadCopy("Changed on your server", "The file was replaced while downloading. Download again for the new edition.", true)
            DownloadProblem.STORAGE -> DownloadCopy("Not enough space", "Free some space on this device, then try again.$kept", true)
            DownloadProblem.MISSING -> DownloadCopy("Files missing", "Some downloaded files are no longer on this device.", true)
            DownloadProblem.UNSUPPORTED -> DownloadCopy("Can't be downloaded", "There's no file here the app can open.")
            DownloadProblem.INTERRUPTED -> DownloadCopy("Stopped before it finished", "Shelfarr was stopped while downloading. Resume to carry on.$kept", true)
            DownloadProblem.INVALID, null -> DownloadCopy("Download failed", "Your server sent an unexpected file.", true)
        }
    }
}

/** What a book's read-along narration download is doing, and what can be done about it. */
data class NarrationCopy(val text: String, val action: NarrationAction? = null, val progress: Float? = null)

enum class NarrationAction(val label: String) {
    DOWNLOAD("Download narration"),
    UPDATE("Update narration"),
    RETRY("Try narration again"),
    STOP("Stop"),
    REMOVE("Remove narration"),
}

/**
 * Narration words for a book's download page. Null when there is nothing to say: no
 * read-along for this edition and none kept. [current] is the server's summary, when known.
 */
fun narrationCopy(record: DownloadRecord, current: ReadAlongSummary?, offline: Boolean): NarrationCopy? {
    if (!record.isReady) return null
    val available = current?.takeIf { it.isAvailable }
    val kept = record.narration?.takeIf { it.isReady }
    val work = record.narrationWork
    val size = available?.audioBytes?.takeIf { it > 0 }?.let { " · ${formatBytes(it)}" }.orEmpty()
    return when {
        record.narrationRequested && record.narrationProblem == null -> NarrationCopy("Preparing narration…", NarrationAction.STOP, 0f)
        // Stopped before anything was pinned: the request is kept and resumes from the start.
        record.narrationRequested -> {
            val why = narrationStopWords(record.narrationProblem)
            val keptNote = if (kept != null) " The earlier narration on this device still plays offline." else " The book itself reads offline."
            val retry = NarrationAction.RETRY.takeIf { !offline && available != null && record.narrationProblem != DownloadProblem.UNSUPPORTED }
            NarrationCopy(why + keptNote, retry)
        }
        work != null && work.isActive -> {
            val fraction = work.bytesTotal.takeIf { it > 0 }?.let { (work.bytesDone.toFloat() / it).coerceIn(0f, 1f) }
            val label = if (kept != null) "Updating narration" else "Downloading narration"
            NarrationCopy(
                fraction?.let { "$label ${(it * 100).toInt()}%" } ?: label,
                NarrationAction.STOP,
                fraction ?: 0f,
            )
        }
        work != null && work.state == NarrationState.FAILED -> {
            val why = narrationStopWords(work.problem)
            val keptNote = if (kept != null) " The earlier narration on this device still plays offline." else " The book itself reads offline."
            NarrationCopy(why + keptNote, NarrationAction.RETRY.takeIf { !offline && available != null })
        }
        kept != null && available != null && kept.generation != available.generation && !offline ->
            NarrationCopy("Updated narration is on your server. The copy on this device still plays offline.", NarrationAction.UPDATE)
        kept != null -> NarrationCopy("Narration is on this device, so you can read along offline.", NarrationAction.REMOVE)
        available != null && !offline -> NarrationCopy("Narration for read-along isn't on this device$size.", NarrationAction.DOWNLOAD)
        else -> null
    }
}

/** Why narration stopped, in words, whether before or after its files were pinned. */
fun narrationStopWords(problem: DownloadProblem?): String = when (problem) {
    DownloadProblem.OFFLINE -> "Narration paused: no connection. It continues when you're back online."
    DownloadProblem.SERVER -> "Narration paused: your server had a problem. It tries again shortly."
    DownloadProblem.STORAGE -> "Narration didn't fit on this device. Free some space, then try again."
    DownloadProblem.CHANGED -> "The narration changed on your server while downloading."
    DownloadProblem.UNSUPPORTED -> "This edition no longer has narration on your server."
    DownloadProblem.SIGN_IN -> "Narration stopped: signed out. Sign in to this account again to continue."
    DownloadProblem.MISSING -> "Some narration files are no longer on this device."
    DownloadProblem.INTERRUPTED -> "Narration stopped before it finished."
    else -> "The narration didn't download."
}

private fun fileCount(record: DownloadRecord): String {
    if (record.files.size <= 1) return ""
    val done = record.files.count { it.complete }
    return " · file ${(done + 1).coerceAtMost(record.files.size)} of ${record.files.size}"
}

/** The download controls on a publication's page. */
@Composable
fun DownloadPanel(
    publication: Publication,
    record: DownloadRecord?,
    offline: Boolean,
    onDownload: () -> Unit,
    onCancel: () -> Unit,
    onRemove: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    /** Several reading formats and no saved one: Download asks which, then calls this. */
    onDownloadFormat: (ReadingFormat) -> Unit = {},
    /** Read-along: download with (true) or without (false) the narration, or add it to a ready book. */
    onNarration: (Boolean) -> Unit = {},
    /** Deletes narration kept with the book: everything ([all]), or only an unfinished fetch. */
    onRemoveNarration: (all: Boolean) -> Unit = {},
) {
    var confirmRemove by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    val choices = publication.readingAssets
    // A saved place keeps its format; with none, a book offered in several formats asks.
    val mustChoose = record == null && choices.size > 1 && choices.none { it.id == publication.progress?.assetId }
    val size = if (mustChoose) 0 else downloadableAssets(publication, record?.pinnedFormat).sumOf { it.sizeBytes }
    val pinnedEpub = record?.files?.singleOrNull()?.assetId
    val readAlong = (publication.assets.firstOrNull { it.id == pinnedEpub } ?: publication.epubAsset)?.readAlong
    // Narration comes with a book that has a real alignment, unless the reader asks for the text alone.
    val narration = readAlong?.takeIf { it.isAvailable && !mustChoose && publication.bookType == BookType.EBOOK && defaultIsEpub(publication) }
    Column(modifier.fillMaxWidth()) {
        when {
            record == null && narration != null -> {
                val audio = narration.audioBytes ?: 0
                OutlinedButton(
                    onClick = { onNarration(true) },
                    enabled = !offline,
                    border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) {
                    Icon(ShelfarrIcons.Download, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (size + audio > 0) "Download with narration · ${formatBytes(size + audio)}" else "Download with narration")
                }
                Caption("Keeps the text and its narration, so you can read along without a connection.")
                if (!offline) {
                    TextButton(onClick = { onNarration(false) }) {
                        Text(if (size > 0) "Download text only · ${formatBytes(size)}" else "Download text only")
                    }
                } else {
                    Caption("Connect to your server to download.")
                }
            }
            record == null -> {
                OutlinedButton(
                    onClick = if (mustChoose) ({ choosing = true }) else onDownload,
                    enabled = !offline,
                    border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                ) {
                    Icon(ShelfarrIcons.Download, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(
                        when {
                            mustChoose -> "Download…"
                            size > 0 -> "Download · ${formatBytes(size)}"
                            else -> "Download"
                        },
                    )
                }
                if (offline) Caption("Connect to your server to download.")
            }
            else -> {
                val copy = downloadCopy(record, narrationShown = narrationCopy(record, readAlong, offline) != null)
                val outdated = record.isReady && !offline && !record.matches(publication)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (record.isReady) {
                        Icon(ShelfarrIcons.Downloaded, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(copy.title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                    // Narration has its own Stop below; Cancel is only for the book's own transfer.
                    when {
                        record.isActive && !record.isReady -> TextButton(onClick = onCancel) { Text("Cancel") }
                        else -> TextButton(onClick = { confirmRemove = true }) { Text("Remove") }
                    }
                }
                if (record.isActive && !record.isReady) {
                    ProgressRule(record.fraction ?: 0f, Modifier.padding(vertical = 4.dp))
                }
                Caption(copy.detail)
                if (choices.size > 1) record.pinnedFormat?.let { Caption("Keeps the ${it.label} copy on this device.") }
                if (outdated) {
                    Caption("A newer edition is on your server. Reading and listening use the server's copy until you update.")
                    TextButton(onClick = onDownload) { Text("Update download") }
                } else if (copy.canRetry && !offline && !record.isReady) {
                    TextButton(onClick = if (record.state == DownloadState.CANCELLED) onDownload else onRetry) {
                        Text(retryLabel(record))
                    }
                }
                if (!outdated) narrationCopy(record, readAlong, offline)?.let { words ->
                    words.progress?.let { ProgressRule(it, Modifier.padding(top = 8.dp, bottom = 2.dp)) }
                    Caption(words.text)
                    words.action?.let { action ->
                        TextButton(onClick = {
                            when (action) {
                                NarrationAction.DOWNLOAD, NarrationAction.UPDATE, NarrationAction.RETRY -> onNarration(true)
                                NarrationAction.STOP -> onRemoveNarration(false)
                                NarrationAction.REMOVE -> onRemoveNarration(true)
                            }
                        }) {
                            val label = if (action == NarrationAction.DOWNLOAD) {
                                readAlong?.audioBytes?.takeIf { it > 0 }?.let { "${action.label} · ${formatBytes(it)}" } ?: action.label
                            } else {
                                action.label
                            }
                            Text(label)
                        }
                    }
                }
            }
        }
    }
    if (choosing) {
        AlertDialog(
            onDismissRequest = { choosing = false },
            title = { Text("Download which format?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    choices.forEach { asset ->
                        val format = asset.readingFormat ?: return@forEach
                        TextButton(
                            onClick = {
                                choosing = false
                                onDownloadFormat(format)
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                if (asset.sizeBytes > 0) "${format.label} · ${formatBytes(asset.sizeBytes)}" else format.label,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } },
        )
    }
    if (confirmRemove) {
        AlertDialog(
            onDismissRequest = { confirmRemove = false },
            title = { Text("Remove download?") },
            text = { Text("This deletes the files from this device. Your saved place and status stay, and you can download it again.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmRemove = false
                    onRemove()
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Keep") } },
        )
    }
}

@Composable
private fun Caption(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = ShelfarrTheme.extended.inkMuted,
        modifier = Modifier.padding(top = 4.dp),
    )
}

/** Everything this account keeps on the device, with what each download is doing. */
@Composable
fun DownloadsScreen(
    records: List<DownloadRecord>,
    onBack: () -> Unit,
    onOpen: (Publication) -> Unit,
    onCancel: (String) -> Unit,
    onRemove: (String) -> Unit,
    onRetry: (String) -> Unit,
    /** Notifications are off, so progress is only visible here and in the system's Task Manager. */
    notificationsOff: Boolean = false,
    onTurnOnNotifications: () -> Unit = {},
) {
    var removing by remember { mutableStateOf<DownloadRecord?>(null) }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.padding(4.dp)) { Icon(ShelfarrIcons.Back, "Back") }
            Text("Downloads", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.semantics { heading() })
        }
        if (records.isEmpty()) {
            MessageState(
                "Nothing downloaded",
                "Download a book or audiobook from its page to read or listen without a connection.",
                icon = ShelfarrIcons.Download,
            )
            return@Column
        }
        val used = records.sumOf { it.bytesDone }
        // Explanations scroll with the list, so large text never pins them over the downloads.
        LazyColumn(
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "about") {
                Text(
                    "${formatBytes(used)} used on this device. Downloads keep going after you leave Shelfarr, as far as Android allows, " +
                        "and pick up where they stopped. Force stopping the app pauses them until you resume.",
                    style = MaterialTheme.typography.bodySmall,
                    color = ShelfarrTheme.extended.inkMuted,
                )
            }
            if (notificationsOff && records.any { it.isActive }) {
                item(key = "notifications") {
                    Surface(
                        color = ShelfarrTheme.extended.sunken,
                        shape = MaterialTheme.shapes.medium,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(Modifier.padding(start = 14.dp, end = 6.dp, top = 10.dp, bottom = 4.dp)) {
                            Text(
                                "Notifications are off, so progress shows only here. Downloads still continue.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                            TextButton(onClick = onTurnOnNotifications) { Text("Turn on notifications") }
                        }
                    }
                }
            }
            items(records, key = { it.publicationId }) { record ->
                DownloadRow(
                    record = record,
                    onOpen = { onOpen(record.publication) },
                    onCancel = { onCancel(record.publicationId) },
                    onRemove = { removing = record },
                    onRetry = { onRetry(record.publicationId) },
                )
            }
        }
    }
    removing?.let { record ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove “${record.publication.title}”?") },
            text = { Text("This deletes its files from this device. Your saved place and status stay.") },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    onRemove(record.publicationId)
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Keep") } },
        )
    }
}

@Composable
private fun DownloadRow(
    record: DownloadRecord,
    onOpen: () -> Unit,
    onCancel: () -> Unit,
    onRemove: () -> Unit,
    onRetry: () -> Unit,
) {
    val copy = downloadCopy(record)
    Surface(
        onClick = onOpen,
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = MaterialTheme.shapes.large,
        border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(if (record.publication.bookType == BookType.AUDIOBOOK) 56.dp else 48.dp)) {
                BookCover(record.publication, Modifier.fillMaxWidth())
            }
            Column(Modifier.weight(1f).padding(start = 12.dp)) {
                Text(record.publication.title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (record.isReady) Icon(ShelfarrIcons.Downloaded, null, modifier = Modifier.size(14.dp).padding(end = 2.dp))
                    Text(copy.title, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(start = if (record.isReady) 4.dp else 0.dp))
                }
                if (record.isActive) ProgressRule(record.fraction ?: 0f, Modifier.padding(vertical = 4.dp))
                Text(copy.detail, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
                Row {
                    if (record.isActive) {
                        TextButton(onClick = onCancel) { Text(if (record.isReady) "Stop narration" else "Cancel") }
                    } else {
                        if (copy.canRetry) TextButton(onClick = onRetry) { Text(retryLabel(record)) }
                        TextButton(onClick = onRemove) { Text("Remove") }
                    }
                }
            }
        }
    }
}
