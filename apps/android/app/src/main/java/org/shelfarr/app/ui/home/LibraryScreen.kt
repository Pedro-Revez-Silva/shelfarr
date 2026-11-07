package org.shelfarr.app.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import org.shelfarr.app.core.LibraryFilter
import org.shelfarr.app.core.LibrarySort
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.ui.label
import org.shelfarr.app.core.Publication
import org.shelfarr.app.ui.components.LoadingState
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.components.shelfScale
import org.shelfarr.app.ui.theme.ShelfarrTheme

@Composable
fun LibraryScreen(
    state: LibraryState,
    host: String?,
    onFilter: (LibraryFilter) -> Unit,
    onQuery: (String) -> Unit,
    onOpen: (Publication) -> Unit,
    onLoadMore: () -> Unit,
    onRetry: () -> Unit,
    onStatus: (ReadingStatus?) -> Unit = {},
    onSort: (LibrarySort) -> Unit = {},
) {
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Text(
            "Library",
            style = MaterialTheme.typography.headlineLarge,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 12.dp),
        )
        SearchField(state.query, onQuery, Modifier.padding(horizontal = 20.dp))
        FilterTabs(state.filter, onFilter, Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
        StatusAndSort(state.status, state.sort, onStatus, onSort, Modifier.padding(horizontal = 20.dp))

        when {
            state.loading && state.items.isEmpty() -> LoadingState()
            state.error != null -> {
                val copy = errorCopy(state.error, host)
                MessageState(copy.title, copy.message, icon = ShelfarrIcons.Offline, action = "Try again", onAction = onRetry)
            }
            state.items.isEmpty() && state.query.isNotBlank() -> MessageState(
                "No matches",
                "Nothing in your library matches “${state.query}”" + (state.status?.let { " with status ${it.label.lowercase()}" } ?: "") + ".",
            )
            state.items.isEmpty() && state.status != null -> MessageState(
                when (state.status) {
                    ReadingStatus.UNREAD -> "Nothing unread"
                    ReadingStatus.IN_PROGRESS -> "Nothing in progress"
                    ReadingStatus.FINISHED -> "Nothing finished yet"
                },
                "Change the status filter to see the rest of your library.",
                action = "Show all",
                onAction = { onStatus(null) },
            )
            state.items.isEmpty() -> MessageState(
                "Nothing here yet",
                "Acquired books and audiobooks appear here.",
            )
            else -> Grid(state, onOpen, onLoadMore)
        }
    }
}

@Composable
private fun Grid(state: LibraryState, onOpen: (Publication) -> Unit, onLoadMore: () -> Unit) {
    val grid = rememberLazyGridState()
    val nearEnd by remember {
        derivedStateOf {
            val info = grid.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            info.totalItemsCount > 0 && last >= info.totalItemsCount - 6
        }
    }
    // A new filter, sort or search starts from the top of its first page.
    LaunchedEffect(state.libraryQuery) { if (grid.firstVisibleItemIndex > 0) grid.scrollToItem(0) }
    LaunchedEffect(nearEnd, state.nextCursor) {
        if (nearEnd && state.nextCursor != null && !state.pageFailed) onLoadMore()
    }

    LazyVerticalGrid(
        state = grid,
        columns = GridCells.Adaptive(minSize = 104.dp * shelfScale()),
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 16.dp, bottom = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        val square = state.filter == LibraryFilter.AUDIOBOOK
        items(state.items, key = { it.id }) { publication ->
            ShelfItem(publication, square = square) { onOpen(publication) }
        }
        if (state.loadingMore) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                }
            }
        }
        if (state.pageFailed) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                TextButton(onClick = onLoadMore) { Text("Couldn't load more. Try again") }
            }
        }
    }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    Surface(
        color = ShelfarrTheme.extended.sunken,
        contentColor = MaterialTheme.colorScheme.onBackground,
        shape = MaterialTheme.shapes.medium,
        modifier = modifier.fillMaxWidth().height(48.dp),
    ) {
        Row(Modifier.padding(start = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(ShelfarrIcons.Search, null, tint = ShelfarrTheme.extended.inkMuted, modifier = Modifier.size(20.dp))
            Box(Modifier.weight(1f).padding(start = 10.dp)) {
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
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Search your library" },
                )
            }
            if (query.isNotEmpty()) {
                IconButton(onClick = { onChange("") }) {
                    Icon(ShelfarrIcons.Close, "Clear search", modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
private fun FilterTabs(selected: LibraryFilter, onSelect: (LibraryFilter) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(22.dp)) {
        FILTERS.forEach { (filter, label) ->
            val active = filter == selected
            Column(
                Modifier
                    .height(48.dp)
                    .clickable(role = Role.Tab) { onSelect(filter) }
                    .semantics { this.selected = active },
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (active) MaterialTheme.colorScheme.onBackground else ShelfarrTheme.extended.inkMuted,
                    modifier = Modifier.padding(top = 6.dp, bottom = 6.dp),
                )
                Box(
                    Modifier
                        .height(2.dp)
                        .width(if (active) 22.dp else 0.dp)
                        .background(MaterialTheme.colorScheme.primary),
                )
            }
        }
    }
}

@Composable
private fun StatusAndSort(
    status: ReadingStatus?,
    sort: LibrarySort,
    onStatus: (ReadingStatus?) -> Unit,
    onSort: (LibrarySort) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Two menus rather than a scrolling chip row, so the active choice is always on screen.
    Row(modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        MenuButton(
            label = "Status: ${status?.label ?: "Any"}",
            active = status != null,
            options = STATUS_FILTERS,
            selected = status,
            onSelect = onStatus,
        )
        MenuButton(
            label = "Sort: ${if (sort == LibrarySort.TITLE) "Title" else "Recent"}",
            active = false,
            options = listOf(LibrarySort.RECENT to "Recent activity", LibrarySort.TITLE to "Title A–Z"),
            selected = sort,
            onSelect = onSort,
            icon = ShelfarrIcons.Sort,
        )
    }
}

@Composable
private fun <T> MenuButton(
    label: String,
    active: Boolean,
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        Surface(
            onClick = { open = true },
            color = if (active) ShelfarrTheme.extended.accentSoft else MaterialTheme.colorScheme.background,
            shape = MaterialTheme.shapes.small,
            border = androidx.compose.foundation.BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
            modifier = Modifier.height(40.dp).semantics { contentDescription = "$label. Change" },
        ) {
            Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                icon?.let { Icon(it, null, modifier = Modifier.size(16.dp).padding(end = 2.dp)) }
                Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(start = if (icon != null) 6.dp else 0.dp))
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (value, text) ->
                DropdownMenuItem(
                    text = { Text(text) },
                    onClick = {
                        open = false
                        onSelect(value)
                    },
                    leadingIcon = {
                        if (value == selected) Icon(ShelfarrIcons.Check, null, modifier = Modifier.size(18.dp)) else Box(Modifier.size(18.dp))
                    },
                )
            }
        }
    }
}

private val STATUS_FILTERS = listOf(
    null to "Any status",
    ReadingStatus.UNREAD to "Unread",
    ReadingStatus.IN_PROGRESS to "In progress",
    ReadingStatus.FINISHED to "Finished",
)

private val FILTERS = listOf(
    LibraryFilter.ALL to "All",
    LibraryFilter.EBOOK to "Books",
    LibraryFilter.AUDIOBOOK to "Audiobooks",
)
