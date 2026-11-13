package org.shelfarr.app.ui.details

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.LoadingState
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.PrimaryButton
import org.shelfarr.app.ui.components.ProgressRule
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.downloads.DownloadPanel
import org.shelfarr.app.ui.formatBytes
import org.shelfarr.app.ui.label
import org.shelfarr.app.ui.primaryActionLabel
import org.shelfarr.app.ui.progressFraction
import org.shelfarr.app.ui.progressLabel
import org.shelfarr.app.ui.theme.ShelfarrTheme

sealed interface DetailsState {
    data object Loading : DetailsState

    /** [offline] means these are the last details seen on this device, not the server's. */
    data class Loaded(val publication: Publication, val offline: Boolean = false) : DetailsState
    data class Failed(val error: ApiException) : DetailsState
}

/** An explicit status change in flight, or the reason the last one didn't reach the server. */
data class StatusEdit(val saving: ReadingStatus? = null, val error: ApiException? = null)

/** Everything the publication page can ask for besides opening it. */
interface DetailsActions {
    fun download() {}

    /** Download one format of a book that has several, by the reader's explicit choice. */
    fun downloadFormat(format: ReadingFormat) {}
    fun cancelDownload() {}
    fun removeDownload() {}
    fun retryDownload() {}
    fun setStatus(status: ReadingStatus) {}

    /** Download (or add to a ready download) this book's read-along narration, or the text alone. */
    fun downloadNarration(include: Boolean) {}

    /** Delete narration kept with a ready book ([all]), or stop an unfinished fetch; the book itself stays. */
    fun removeNarration(all: Boolean) {}

    object None : DetailsActions
}

class DetailsViewModel(private val container: AppContainer, private val id: String) : ViewModel(), DetailsActions {
    private val account = container.currentAccount()
    private val mutableState = MutableStateFlow<DetailsState>(DetailsState.Loading)
    val state: StateFlow<DetailsState> = mutableState.asStateFlow()

    private val mutableStatus = MutableStateFlow(StatusEdit())
    val statusEdit: StateFlow<StatusEdit> = mutableStatus.asStateFlow()

    val download: StateFlow<DownloadRecord?> = account?.downloads?.records
        ?.map { it[id] }
        ?.stateIn(viewModelScope, SharingStarted.Eagerly, account.downloads.record(id))
        ?: MutableStateFlow(null)

    fun load() {
        val services = account ?: return
        viewModelScope.launch {
            try {
                val publication = services.publication(id)
                mutableState.value = DetailsState.Loaded(publication)
            } catch (error: ApiException) {
                if (mutableState.value is DetailsState.Loaded) return@launch
                // Offline, show what this device knows. Sign-in and certificate errors stay visible.
                val local = if (error.isPlainOffline) {
                    services.recall(id)
                } else {
                    null
                }
                mutableState.value = local?.let { DetailsState.Loaded(it, offline = true) } ?: DetailsState.Failed(error)
            }
        }
    }

    fun retry() {
        mutableState.value = DetailsState.Loading
        load()
    }

    /** The format the next [download] keeps; null keeps the saved or already downloaded one. */
    private var downloadFormat: ReadingFormat? = null

    /** Whether the next [download] keeps read-along narration too; null keeps the earlier choice. */
    private var downloadNarration: Boolean? = null

    fun prepareDownload(format: ReadingFormat?, narration: Boolean? = null) {
        downloadFormat = format
        downloadNarration = narration
    }

    override fun download() {
        val services = account ?: return
        val publication = (mutableState.value as? DetailsState.Loaded)?.publication ?: return
        val format = downloadFormat
        val narration = downloadNarration
        viewModelScope.launch { services.downloads.enqueue(publication, format, narration) }
    }

    override fun downloadNarration(include: Boolean) {
        prepareDownload(null, include)
        download()
    }

    override fun removeNarration(all: Boolean) {
        val services = account ?: return
        container.scope.launch { services.downloads.removeNarration(id, removeAll = all) }
    }

    override fun downloadFormat(format: ReadingFormat) {
        prepareDownload(format)
        download()
    }

    override fun cancelDownload() {
        val services = account ?: return
        container.scope.launch { services.downloads.cancel(id) }
    }

    override fun removeDownload() {
        val services = account ?: return
        container.scope.launch { services.downloads.remove(id) }
    }

    override fun retryDownload() {
        val services = account ?: return
        viewModelScope.launch { services.downloads.retry(id) }
    }

    /** Needs the server: nothing is changed locally until it has accepted the status. */
    override fun setStatus(status: ReadingStatus) {
        val services = account ?: return
        val loaded = mutableState.value as? DetailsState.Loaded ?: return
        if (loaded.offline || mutableStatus.value.saving != null || loaded.publication.status == status) return
        mutableStatus.value = StatusEdit(saving = status)
        viewModelScope.launch {
            try {
                val updated = services.setReadingStatus(id, status)
                mutableState.value = DetailsState.Loaded(updated)
                mutableStatus.value = StatusEdit()
            } catch (error: ApiException) {
                mutableStatus.value = StatusEdit(error = error)
            }
        }
    }
}

@Composable
fun DetailsScreen(
    state: DetailsState,
    host: String?,
    onBack: () -> Unit,
    onPrimary: (Publication) -> Unit,
    onRetry: () -> Unit,
    download: DownloadRecord? = null,
    statusEdit: StatusEdit = StatusEdit(),
    actions: DetailsActions = DetailsActions.None,
) {
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        IconButton(onClick = onBack, modifier = Modifier.padding(4.dp)) {
            Icon(ShelfarrIcons.Back, "Back")
        }
        when (state) {
            DetailsState.Loading -> LoadingState()
            is DetailsState.Failed -> {
                val copy = errorCopy(state.error, host)
                MessageState(
                    copy.title,
                    copy.message,
                    icon = ShelfarrIcons.Offline,
                    action = if (copy.retryable) "Try again" else null,
                    onAction = onRetry,
                )
            }
            is DetailsState.Loaded -> Details(state, host, download, statusEdit, actions, onPrimary)
        }
    }
}

@Composable
private fun Details(
    state: DetailsState.Loaded,
    host: String?,
    download: DownloadRecord?,
    statusEdit: StatusEdit,
    actions: DetailsActions,
    onPrimary: (Publication) -> Unit,
) {
    val publication = state.publication
    Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier
                .widthIn(max = 560.dp)
                .fillMaxWidth()
                .padding(start = 24.dp, end = 24.dp, bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val coverWidth = if (publication.bookType == BookType.AUDIOBOOK) 220.dp else 188.dp
            Box(Modifier.widthIn(max = coverWidth).fillMaxWidth()) {
                BookCover(publication, Modifier.fillMaxWidth(), corner = 6.dp, elevation = 10.dp)
            }
            Spacer(Modifier.height(24.dp))
            Text(
                publication.title,
                style = MaterialTheme.typography.headlineLarge,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            publication.author?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = ShelfarrTheme.extended.inkMuted,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }

            Spacer(Modifier.height(24.dp))
            if (publication.isReadableHere) {
                PrimaryButton(publication.primaryActionLabel, { onPrimary(publication) }, Modifier.fillMaxWidth())
                publication.progressLabel()?.let { label ->
                    Spacer(Modifier.height(12.dp))
                    publication.progressFraction()?.let { ProgressRule(it) }
                    Text(
                        label,
                        style = MaterialTheme.typography.labelSmall,
                        color = ShelfarrTheme.extended.inkMuted,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            } else {
                Text(
                    "This format can't be opened in the app yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = ShelfarrTheme.extended.inkMuted,
                    textAlign = TextAlign.Center,
                )
            }
            if (state.offline) {
                Text(
                    if (download?.isReady == true) "Offline. Opening the download on this device." else "Offline. These are the last details seen on this device.",
                    style = MaterialTheme.typography.bodySmall,
                    color = ShelfarrTheme.extended.inkMuted,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 10.dp),
                )
            }

            if (publication.isReadableHere) {
                Spacer(Modifier.height(20.dp))
                DownloadPanel(
                    publication = publication,
                    record = download,
                    offline = state.offline,
                    onDownload = actions::download,
                    onCancel = actions::cancelDownload,
                    onRemove = actions::removeDownload,
                    onRetry = actions::retryDownload,
                    onDownloadFormat = actions::downloadFormat,
                    onNarration = actions::downloadNarration,
                    onRemoveNarration = actions::removeNarration,
                )
            }
            StatusPicker(publication, state.offline, statusEdit, host, actions::setStatus)

            publication.description?.takeIf(String::isNotBlank)?.let { Description(it) }
            FileDetails(publication, download)
        }
    }
}

@Composable
private fun Description(text: String) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    var overflowing by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(top = 28.dp)) {
        Text(
            text,
            style = MaterialTheme.typography.bodyLarge,
            maxLines = if (expanded) Int.MAX_VALUE else 6,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { if (!expanded) overflowing = it.hasVisualOverflow },
        )
        if (overflowing || expanded) {
            Text(
                if (expanded) "Show less" else "Read more",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .clickable(role = Role.Button) { expanded = !expanded }
                    .padding(vertical = 14.dp),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StatusPicker(
    publication: Publication,
    offline: Boolean,
    edit: StatusEdit,
    host: String?,
    onSelect: (ReadingStatus) -> Unit,
) {
    val current = edit.saving ?: publication.status
    Column(Modifier.fillMaxWidth().padding(top = 24.dp)) {
        Text(
            "Status",
            style = MaterialTheme.typography.labelMedium,
            color = ShelfarrTheme.extended.inkMuted,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.height(8.dp))
        FlowRow(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReadingStatus.entries.forEach { status ->
                val selected = status == current
                FilterChip(
                    selected = selected,
                    onClick = { onSelect(status) },
                    enabled = !offline && edit.saving == null,
                    label = { Text(status.label, maxLines = 1) },
                    leadingIcon = if (selected) {
                        { Icon(ShelfarrIcons.Check, null, modifier = Modifier.size(16.dp)) }
                    } else {
                        null
                    },
                    modifier = Modifier.semantics { role = Role.RadioButton },
                )
            }
        }
        val note = when {
            offline -> "Connect to your server to change the status."
            edit.saving != null -> "Saving…"
            edit.error != null -> errorCopy(edit.error, host).let { "Couldn't change the status. ${it.title}." }
            publication.progress?.isUsable == true -> "Changing the status keeps your saved place."
            else -> null
        }
        note?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = if (edit.error != null) MaterialTheme.colorScheme.error else ShelfarrTheme.extended.inkMuted,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

@Composable
private fun FileDetails(publication: Publication, download: DownloadRecord?) {
    val assets = publication.orderedAssets
    if (assets.isEmpty()) return
    val total = assets.sumOf { it.sizeBytes }
    val format = assets.map { it.format.uppercase() }.filter(String::isNotEmpty).distinct().joinToString(", ")
    Column(Modifier.fillMaxWidth().padding(top = 28.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        HorizontalDivider(color = ShelfarrTheme.extended.hairline)
        DetailRow("Format", format.ifEmpty { "Unknown" })
        if (assets.size > 1) DetailRow("Files", assets.size.toString())
        if (total > 0) DetailRow("Size", formatBytes(total))
        DetailRow(
            "Availability",
            when {
                download?.isReady == true -> "Downloaded to this device"
                publication.bookType == BookType.AUDIOBOOK -> "Streams from your server"
                else -> "Opens from your server"
            },
        )
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}
