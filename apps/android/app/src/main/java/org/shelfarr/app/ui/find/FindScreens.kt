package org.shelfarr.app.ui.find

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DiscoverItem
import org.shelfarr.app.core.FormatOption
import org.shelfarr.app.core.FormatState
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.RequestAccess
import org.shelfarr.app.core.RequestItem
import org.shelfarr.app.core.RequestStage
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.LoadingState
import org.shelfarr.app.ui.components.PrimaryButton
import org.shelfarr.app.ui.components.ProgressRule
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.theme.ShelfarrTheme

/*
 * Find is deliberately its own tab, not part of Library search: Library is what you
 * have, Find is asking for something new. Every step is a full screen with large
 * targets and wrapping text (no sheets, no fixed-height rows), so it stays usable at
 * the largest font sizes, and nothing requests on a single stray tap: a title opens
 * a page where the format is chosen and the request is one clearly labelled button.
 */

@Composable
fun FindScreen(
    access: RequestAccess,
    state: FindState,
    host: String,
    accountName: String,
    onQuery: (String) -> Unit,
    onSearch: () -> Unit,
    onChoose: (DiscoverItem) -> Unit,
    onOpenRequest: (RequestItem) -> Unit,
    onAllow: () -> Unit,
    onReopenBrowser: () -> Unit,
    onCancelApproval: () -> Unit,
    onOpenWebsite: () -> Unit,
    onRetryRequests: () -> Unit,
) {
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Text(
            "Find",
            style = MaterialTheme.typography.headlineLarge,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 12.dp).semantics { heading() },
        )
        when (access) {
            RequestAccess.Checking -> LoadingState(label = "Checking what this connection can do")
            RequestAccess.ServerTooOld -> Explainer(
                title = "Requesting isn't available on $host",
                body = "This server's version of Shelfarr doesn't offer requesting from the app. Reading and listening work as usual, " +
                    "and you can still request books on the website.",
                action = "Open the website",
                onAction = onOpenWebsite,
            )
            is RequestAccess.NotAllowed -> Explainer(
                title = "Find new books",
                body = "Search beyond your library and request ebooks and audiobooks as $accountName. " +
                    "You approve this once in your browser. Your library, downloads and saved places stay exactly as they are.",
                action = "Allow requesting",
                onAction = onAllow,
                notice = access.notice,
            )
            is RequestAccess.Approving -> Approving(access, onReopenBrowser, onCancelApproval)
            RequestAccess.Allowed -> Searchable(state, host, onQuery, onSearch, onChoose, onOpenRequest, onRetryRequests)
        }
    }
}

@Composable
private fun Explainer(title: String, body: String, action: String, onAction: () -> Unit, notice: String? = null) {
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(ShelfarrIcons.Search, null, tint = ShelfarrTheme.extended.inkMuted, modifier = Modifier.size(28.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
        Text(body, style = MaterialTheme.typography.bodyMedium, color = ShelfarrTheme.extended.inkMuted)
        notice?.let {
            Notice(it)
        }
        PrimaryButton(action, onAction, Modifier.fillMaxWidth().padding(top = 4.dp).testTag("find-explainer-action"))
    }
}

@Composable
private fun Notice(text: String, modifier: Modifier = Modifier) {
    Surface(color = ShelfarrTheme.extended.sunken, shape = MaterialTheme.shapes.medium, modifier = modifier.fillMaxWidth()) {
        Row(Modifier.padding(14.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }, verticalAlignment = Alignment.Top) {
            Icon(ShelfarrIcons.Alert, null, tint = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 2.dp).size(18.dp))
            Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 10.dp))
        }
    }
}

@Composable
private fun Approving(phase: RequestAccess.Approving, onReopenBrowser: () -> Unit, onCancel: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Approve in your browser", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
        Text(
            "Check that the page shows this code, then choose Allow requesting. Come back here when you're done.",
            style = MaterialTheme.typography.bodyMedium,
            color = ShelfarrTheme.extended.inkMuted,
        )
        Text(
            phase.userCode,
            style = MaterialTheme.typography.headlineLarge.copy(fontFamily = FontFamily.Monospace),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).semantics { contentDescription = "Code ${phase.userCode.toList().joinToString(" ")}" },
        )
        Text(
            "Or open ${phase.verificationUri} and enter the code. It expires in ${formatCountdown(phase.secondsLeft)}.",
            style = MaterialTheme.typography.bodySmall,
            color = ShelfarrTheme.extended.inkMuted,
        )
        PrimaryButton("Open browser", onReopenBrowser, Modifier.fillMaxWidth())
        TextButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) { Text("Cancel") }
    }
}

private fun formatCountdown(seconds: Long): String = "%d:%02d".format(seconds / 60, seconds % 60)

@Composable
private fun Searchable(
    state: FindState,
    host: String,
    onQuery: (String) -> Unit,
    onSearch: () -> Unit,
    onChoose: (DiscoverItem) -> Unit,
    onOpenRequest: (RequestItem) -> Unit,
    onRetryRequests: () -> Unit,
) {
    FindField(state.query, onQuery, onSearch, Modifier.padding(horizontal = 20.dp))
    val showingResults = state.searchedFor != null || state.searching
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 24.dp)) {
        if (showingResults) {
            if (state.searching) {
                item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp) } }
            }
            val error = state.searchError
            when {
                error != null -> item { SearchProblem(error, host, onSearch) }
                !state.searching && state.results.isEmpty() -> item {
                    Text(
                        "Nothing found for “${state.searchedFor}”. Try fewer words, or the author's name.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = ShelfarrTheme.extended.inkMuted,
                        modifier = Modifier.padding(vertical = 16.dp).semantics { liveRegion = LiveRegionMode.Polite },
                    )
                }
                else -> items(state.results, key = { "result:" + it.id }) { item -> ResultRow(item, onChoose) }
            }
        }
        if (state.requests.isNotEmpty() || state.requestsError != null) {
            item {
                Text(
                    "Your requests",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(top = if (showingResults) 24.dp else 4.dp, bottom = 4.dp).semantics { heading() },
                )
            }
            state.requestsError?.let { error ->
                item {
                    val note = if (error is ApiException.Offline && !error.certificate) {
                        if (state.requests.isEmpty()) "You're offline. Your requests appear when $host can be reached." else "You're offline. These are from earlier."
                    } else {
                        errorCopy(error, host).message
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(note, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.weight(1f))
                        TextButton(onClick = onRetryRequests, modifier = Modifier.heightIn(min = 48.dp)) { Text("Retry") }
                    }
                }
            }
            items(state.requests, key = { "request:" + it.id }) { request -> RequestRow(request, onOpenRequest) }
        } else if (!showingResults && state.requestsLoaded) {
            item {
                Text(
                    "Search for a title or author. Requests you make appear here so you can follow them.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = ShelfarrTheme.extended.inkMuted,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun SearchProblem(error: Throwable, host: String, onRetry: () -> Unit) {
    val message = when {
        error is ApiException.Offline && !error.certificate -> "You're offline. Finding new books needs a connection to $host."
        error is ApiException.Forbidden -> "This connection can't search any more. Allow requesting again to continue."
        error is ApiException.Server && error.status == 503 -> "$host couldn't reach its book catalogues. Try again in a moment."
        error is ApiException.Server -> "$host couldn't search right now (error ${error.status}). Try again in a moment."
        else -> errorCopy(error, host).message
    }
    Column(Modifier.padding(vertical = 12.dp)) {
        Notice(message)
        TextButton(onClick = onRetry, modifier = Modifier.heightIn(min = 48.dp)) { Text("Try again") }
    }
}

@Composable
private fun FindField(query: String, onChange: (String) -> Unit, onSearch: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        color = ShelfarrTheme.extended.sunken,
        contentColor = MaterialTheme.colorScheme.onBackground,
        shape = MaterialTheme.shapes.medium,
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
    ) {
        Row(Modifier.padding(start = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(ShelfarrIcons.Search, null, tint = ShelfarrTheme.extended.inkMuted, modifier = Modifier.size(20.dp))
            Box(Modifier.weight(1f).padding(start = 10.dp, top = 12.dp, bottom = 12.dp)) {
                if (query.isEmpty()) {
                    Text("Title or author", style = MaterialTheme.typography.bodyMedium, color = ShelfarrTheme.extended.inkMuted)
                }
                BasicTextField(
                    value = query,
                    onValueChange = onChange,
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(color = LocalContentColor.current),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { onSearch() }),
                    modifier = Modifier.fillMaxWidth().testTag("find-query").semantics { contentDescription = "Find a title or author" },
                )
            }
            IconButton(onClick = onSearch, modifier = Modifier.testTag("find-submit")) {
                Icon(ShelfarrIcons.ChevronRight, "Search", modifier = Modifier.size(20.dp))
            }
        }
    }
}

@Composable
private fun ResultRow(item: DiscoverItem, onChoose: (DiscoverItem) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = "Choose a format") { onChoose(item) }
            .padding(vertical = 10.dp)
            .testTag("result:${item.id}"),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.width(56.dp)) { BookCover(item.asPublication(), Modifier.fillMaxWidth(), elevation = 1.dp) }
        Column(Modifier.weight(1f).padding(start = 14.dp)) {
            Text(item.title, style = MaterialTheme.typography.titleMedium)
            val byline = listOfNotNull(item.author, item.year?.toString()).joinToString(" · ")
            if (byline.isNotEmpty()) {
                Text(byline, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 2.dp))
            }
            Text(
                formatsLine(item),
                style = MaterialTheme.typography.labelMedium,
                color = ShelfarrTheme.extended.inkMuted,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
    }
}

/** "Ebook or audiobook", or each format's state in reading order when they differ. */
internal fun formatsLine(item: DiscoverItem): String {
    val options = listOf(BookType.EBOOK, BookType.AUDIOBOOK).mapNotNull(item::format)
    if (options.size == 2 && options.all { it.state == FormatState.REQUESTABLE }) return "Ebook or audiobook"
    return formatStates(item)
}

private fun formatStates(item: DiscoverItem): String = listOf(BookType.EBOOK, BookType.AUDIOBOOK).mapNotNull { type ->
    val option = item.format(type) ?: return@mapNotNull null
    val state = when (option.state) {
        FormatState.REQUESTABLE -> "can be requested"
        FormatState.IN_LIBRARY -> "in your library"
        FormatState.REQUESTED -> "requested"
        FormatState.REQUESTED_BY_SOMEONE -> "already requested"
        FormatState.UNKNOWN -> "unavailable"
    }
    "${type.label} $state"
}.joinToString(" · ")

@Composable
private fun RequestRow(request: RequestItem, onOpen: (RequestItem) -> Unit) {
    val copy = request.stageCopy()
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClickLabel = "Follow this request") { onOpen(request) }
            .padding(vertical = 10.dp)
            .testTag("request:${request.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(44.dp)) {
            BookCover(Publication(id = "request:${request.id}", title = request.title, author = request.author, bookType = request.bookType, coverUrl = request.coverUrl), Modifier.fillMaxWidth(), elevation = 1.dp)
        }
        Column(Modifier.weight(1f).padding(start = 14.dp)) {
            Text(request.title, style = MaterialTheme.typography.bodyLarge)
            Text(
                "${request.bookType.label} · ${copy.headline}",
                style = MaterialTheme.typography.bodySmall,
                color = if (request.isReady) MaterialTheme.colorScheme.primary else ShelfarrTheme.extended.inkMuted,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        Icon(ShelfarrIcons.ChevronRight, null, tint = ShelfarrTheme.extended.inkMuted, modifier = Modifier.size(18.dp))
    }
}

/** A search result, where the format is chosen and the request made. */
@Composable
fun TitleScreen(
    state: TitleState,
    onBack: () -> Unit,
    onSelect: (BookType) -> Unit,
    onSubmit: () -> Unit,
    onOpenPublication: (String) -> Unit,
    onOpenRequest: (RequestItem) -> Unit,
) {
    val item = state.item
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        IconButton(onClick = onBack, modifier = Modifier.padding(4.dp)) { Icon(ShelfarrIcons.Back, "Back") }
        if (item == null) {
            Text("Search again from Find.", modifier = Modifier.padding(20.dp), style = MaterialTheme.typography.bodyMedium)
            return@Column
        }
        Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 32.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Box(Modifier.width(96.dp)) { BookCover(item.asPublication(), Modifier.fillMaxWidth(), corner = 6.dp, elevation = 6.dp) }
                    Column(Modifier.weight(1f).padding(start = 18.dp)) {
                        Text(item.title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
                        item.author?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 4.dp)) }
                        val extra = listOfNotNull(
                            item.year?.toString(),
                            item.seriesName?.let { series -> item.seriesPosition?.let { "$series, book $it" } ?: series },
                        ).joinToString(" · ")
                        if (extra.isNotEmpty()) Text(extra, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 4.dp))
                    }
                }

                Text("Choose a format", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 28.dp, bottom = 10.dp).semantics { heading() })
                Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    listOf(BookType.EBOOK, BookType.AUDIOBOOK).forEach { type ->
                        val option = item.format(type) ?: FormatOption(type)
                        FormatRow(option, selected = state.format == type, onSelect = { onSelect(type) }, onOpenPublication = onOpenPublication, onOpenRequest = onOpenRequest)
                    }
                }

                state.message?.let { Notice(it, Modifier.padding(top = 16.dp)) }

                val format = state.format
                Spacer(Modifier.height(20.dp))
                if (format != null) {
                    PrimaryButton(
                        if (state.submitting) "Requesting…" else "Request ${format.word}",
                        onSubmit,
                        Modifier.fillMaxWidth().testTag("request-submit"),
                        enabled = !state.submitting,
                    )
                    Text(
                        "Shelfarr looks for a copy and adds it to the library for everyone on this server. It can take a while; you can follow it here.",
                        style = MaterialTheme.typography.bodySmall,
                        color = ShelfarrTheme.extended.inkMuted,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                } else if (item.formats.none { it.state == FormatState.REQUESTABLE }) {
                    Text(
                        "There's nothing left to request for this title.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = ShelfarrTheme.extended.inkMuted,
                    )
                }
                item.description?.takeIf(String::isNotBlank)?.let {
                    Text(it, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 28.dp))
                }
            }
        }
    }
}

@Composable
private fun FormatRow(
    option: FormatOption,
    selected: Boolean,
    onSelect: () -> Unit,
    onOpenPublication: (String) -> Unit,
    onOpenRequest: (RequestItem) -> Unit,
) {
    val requestable = option.state == FormatState.REQUESTABLE
    val outline = if (selected) MaterialTheme.colorScheme.primary else ShelfarrTheme.extended.hairline
    val publication = option.publicationId
    val request = option.request
    val base = Modifier
        .fillMaxWidth()
        .heightIn(min = 64.dp)
        .border(BorderStroke(if (selected) 2.dp else 1.dp, outline), MaterialTheme.shapes.medium)
        .testTag("format:${option.bookType.word}")
    val interactive = when {
        requestable -> base.selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
        option.state == FormatState.IN_LIBRARY && publication != null -> base.clickable(role = Role.Button, onClickLabel = "Open") { onOpenPublication(publication) }
        option.state == FormatState.REQUESTED && request != null -> base.clickable(role = Role.Button, onClickLabel = "Follow request") { onOpenRequest(request) }
        else -> base.semantics { stateDescription = "Not available to request" }
    }
    Row(interactive.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (requestable) {
            Box(
                Modifier
                    .size(20.dp)
                    .border(2.dp, if (selected) MaterialTheme.colorScheme.primary else ShelfarrTheme.extended.inkMuted, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                if (selected) Box(Modifier.size(10.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
            }
        } else {
            Icon(
                if (option.state == FormatState.IN_LIBRARY) ShelfarrIcons.Downloaded else if (option.bookType == BookType.AUDIOBOOK) ShelfarrIcons.Headphones else ShelfarrIcons.Library,
                null,
                tint = ShelfarrTheme.extended.inkMuted,
                modifier = Modifier.size(20.dp),
            )
        }
        Column(Modifier.weight(1f).padding(start = 14.dp)) {
            Text(option.bookType.label, style = MaterialTheme.typography.titleSmall)
            Text(option.summary(), style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 2.dp))
        }
        when {
            option.state == FormatState.IN_LIBRARY && publication != null -> Text("Open", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            option.state == FormatState.REQUESTED && request != null -> Icon(ShelfarrIcons.ChevronRight, null, modifier = Modifier.size(18.dp))
            else -> Unit
        }
    }
}

/** Follows one request to the moment it can be opened. */
@Composable
fun RequestScreen(
    state: TrackState,
    host: String,
    onBack: () -> Unit,
    onOpen: (String) -> Unit,
    onDetails: (String) -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
) {
    var confirming by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        IconButton(onClick = onBack, modifier = Modifier.padding(4.dp)) { Icon(ShelfarrIcons.Back, "Back") }
        val request = state.request
        if (request == null) {
            if (state.error != null) {
                val copy = errorCopy(state.error, host)
                Column(Modifier.padding(20.dp)) {
                    Text(copy.title, style = MaterialTheme.typography.headlineSmall)
                    Text(copy.message, style = MaterialTheme.typography.bodyMedium, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 8.dp))
                    if (copy.retryable) OutlinedButton(onClick = onRetry, modifier = Modifier.padding(top = 16.dp)) { Text("Try again") }
                }
            } else {
                LoadingState()
            }
            return@Column
        }
        val copy = request.stageCopy()
        Box(Modifier.fillMaxSize().verticalScroll(rememberScrollState()), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 32.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Box(Modifier.width(80.dp)) {
                        BookCover(Publication(id = "request:${request.id}", title = request.title, author = request.author, bookType = request.bookType, coverUrl = request.coverUrl), Modifier.fillMaxWidth(), corner = 6.dp, elevation = 6.dp)
                    }
                    Column(Modifier.weight(1f).padding(start = 18.dp)) {
                        Text(request.title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
                        Text(listOfNotNull(request.author, request.bookType.label).joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 4.dp))
                    }
                }
                Column(Modifier.padding(top = 24.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }.testTag("request-stage")) {
                    Text(copy.headline, style = MaterialTheme.typography.titleLarge)
                    Text(copy.detail, style = MaterialTheme.typography.bodyMedium, color = ShelfarrTheme.extended.inkMuted, modifier = Modifier.padding(top = 4.dp))
                }
                if (request.stage == RequestStage.DOWNLOADING) {
                    request.downloadPercent?.let { ProgressRule(it / 100f, Modifier.padding(top = 14.dp)) }
                }
                Steps(request, Modifier.padding(top = 20.dp))

                state.error?.let {
                    Text(
                        if (it is ApiException.Offline && !it.certificate) "Offline. Showing the last update; this page refreshes when the connection is back." else errorCopy(it, host).message,
                        style = MaterialTheme.typography.bodySmall,
                        color = ShelfarrTheme.extended.inkMuted,
                        modifier = Modifier.padding(top = 16.dp),
                    )
                }
                state.cancelMessage?.let { Notice(it, Modifier.padding(top = 16.dp)) }

                val publication = request.publicationId
                if (request.isReady && publication != null) {
                    Spacer(Modifier.height(24.dp))
                    PrimaryButton(
                        if (state.opening) "Opening…" else if (request.bookType == BookType.EBOOK) "Read now" else "Listen now",
                        { onOpen(publication) },
                        Modifier.fillMaxWidth().testTag("request-open"),
                        enabled = !state.opening,
                    )
                    TextButton(onClick = { onDetails(publication) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Details and download") }
                } else if (request.canCancel && request.stage.isOpen) {
                    Spacer(Modifier.height(24.dp))
                    TextButton(
                        onClick = { confirming = true },
                        enabled = !state.cancelling,
                        modifier = Modifier.heightIn(min = 48.dp).testTag("request-cancel"),
                    ) { Text(if (state.cancelling) "Cancelling…" else "Cancel request") }
                }
            }
        }
    }
    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Cancel this request?") },
            text = { Text("Shelfarr stops looking for it. You can request it again later.") },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    onCancel()
                }) { Text("Cancel request") }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Keep it") } },
        )
    }
}

@Composable
private fun Steps(request: RequestItem, modifier: Modifier = Modifier) {
    val reached = request.stepReached()
    Column(modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        REQUEST_STEPS.forEachIndexed { index, label ->
            val done = reached >= 0 && index < reached || (reached == REQUEST_STEPS.lastIndex && index == reached)
            val current = index == reached && !done
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(10.dp)
                        .background(
                            when {
                                done -> MaterialTheme.colorScheme.primary
                                current -> MaterialTheme.colorScheme.primary.copy(alpha = 0.45f)
                                else -> ShelfarrTheme.extended.hairline
                            },
                            CircleShape,
                        ),
                )
                Text(
                    label,
                    style = if (current) MaterialTheme.typography.labelLarge else MaterialTheme.typography.bodySmall,
                    color = if (done || current) MaterialTheme.colorScheme.onBackground else ShelfarrTheme.extended.inkMuted,
                    modifier = Modifier.padding(start = 12.dp),
                )
            }
        }
    }
}
