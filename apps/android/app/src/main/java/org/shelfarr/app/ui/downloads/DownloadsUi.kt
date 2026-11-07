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
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.downloadableAssets
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.ProgressRule
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.formatBytes
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** What a download is doing, in words. Partial downloads never read as ready. */
data class DownloadCopy(val title: String, val detail: String, val canRetry: Boolean = false)

fun downloadCopy(record: DownloadRecord): DownloadCopy {
    val total = record.bytesTotal
    val amount = if (total != null) "${formatBytes(record.bytesDone)} of ${formatBytes(total)}" else "${formatBytes(record.bytesDone)} so far"
    val kept = if (record.bytesDone > 0) " ${formatBytes(record.bytesDone)} kept." else ""
    return when (record.state) {
        DownloadState.QUEUED -> DownloadCopy("Waiting to download", amount)
        DownloadState.DOWNLOADING -> DownloadCopy(
            record.fraction?.let { "Downloading ${(it * 100).toInt()}%" } ?: "Downloading",
            amount + fileCount(record),
        )
        DownloadState.READY -> DownloadCopy(
            "Downloaded",
            "${formatBytes(record.bytesDone)} on this device. Opens without a connection.",
        )
        DownloadState.CANCELLED -> DownloadCopy("Download cancelled", "Nothing is kept on this device.", canRetry = true)
        DownloadState.FAILED -> when (record.problem) {
            DownloadProblem.OFFLINE -> DownloadCopy("Paused: no connection", "Continues when Shelfarr is open and online.$kept", true)
            DownloadProblem.CERTIFICATE -> DownloadCopy("Stopped: can't verify your server", "Its security certificate couldn't be trusted.", true)
            DownloadProblem.SIGN_IN -> DownloadCopy("Stopped: signed out", "Sign in to this account again to continue.$kept")
            DownloadProblem.FORBIDDEN -> DownloadCopy("Not allowed", "This account can't download that file.", true)
            DownloadProblem.NOT_FOUND -> DownloadCopy("No longer on your server", "The file couldn't be found.", true)
            DownloadProblem.SERVER -> DownloadCopy("Your server had a problem", "Tries again when you come back to Shelfarr.$kept", true)
            DownloadProblem.REDIRECT -> DownloadCopy("Server moved", "Your server redirected elsewhere, so Shelfarr stopped.", true)
            DownloadProblem.CHANGED -> DownloadCopy("Changed on your server", "The file was replaced while downloading. Download again for the new edition.", true)
            DownloadProblem.STORAGE -> DownloadCopy("Not enough space", "Free some space on this device, then try again.$kept", true)
            DownloadProblem.MISSING -> DownloadCopy("Files missing", "Some downloaded files are no longer on this device.", true)
            DownloadProblem.UNSUPPORTED -> DownloadCopy("Can't be downloaded", "There's no file here the app can open.")
            DownloadProblem.INVALID, null -> DownloadCopy("Download failed", "Your server sent an unexpected file.", true)
        }
    }
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
) {
    var confirmRemove by remember { mutableStateOf(false) }
    val size = downloadableAssets(publication).sumOf { it.sizeBytes }
    Column(modifier.fillMaxWidth()) {
        when {
            record == null -> {
                OutlinedButton(
                    onClick = onDownload,
                    enabled = !offline,
                    border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                ) {
                    Icon(ShelfarrIcons.Download, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (size > 0) "Download · ${formatBytes(size)}" else "Download")
                }
                if (offline) Caption("Connect to your server to download.")
            }
            else -> {
                val copy = downloadCopy(record)
                val outdated = record.isReady && !offline && !record.matches(publication)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (record.isReady) {
                        Icon(ShelfarrIcons.Downloaded, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(copy.title, style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                    when {
                        record.isActive -> TextButton(onClick = onCancel) { Text("Cancel") }
                        else -> TextButton(onClick = { confirmRemove = true }) { Text("Remove") }
                    }
                }
                if (record.isActive) {
                    ProgressRule(record.fraction ?: 0f, Modifier.padding(vertical = 4.dp))
                }
                Caption(copy.detail)
                if (outdated) {
                    Caption("A newer edition is on your server. Reading and listening use the server's copy until you update.")
                    TextButton(onClick = onDownload) { Text("Update download") }
                } else if (copy.canRetry && !offline) {
                    TextButton(onClick = if (record.state == DownloadState.CANCELLED) onDownload else onRetry) {
                        Text(if (record.state == DownloadState.CANCELLED) "Download again" else "Try again")
                    }
                }
            }
        }
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
        Text(
            "${formatBytes(used)} used on this device. Downloads continue while Shelfarr is open, and pick up where they stopped next time.",
            style = MaterialTheme.typography.bodySmall,
            color = ShelfarrTheme.extended.inkMuted,
            modifier = Modifier.padding(horizontal = 20.dp),
        )
        LazyColumn(
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
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
                        TextButton(onClick = onCancel) { Text("Cancel") }
                    } else {
                        if (copy.canRetry) TextButton(onClick = onRetry) { Text(if (record.state == DownloadState.CANCELLED) "Download again" else "Try again") }
                        TextButton(onClick = onRemove) { Text("Remove") }
                    }
                }
            }
        }
    }
}
