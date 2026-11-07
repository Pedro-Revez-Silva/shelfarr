package org.shelfarr.app.ui.home

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Publication
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.LoadingState
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.ProgressRule
import org.shelfarr.app.ui.components.ShelfCover
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.components.shelfScale
import org.shelfarr.app.ui.progressFraction
import org.shelfarr.app.ui.progressLabel
import org.shelfarr.app.ui.theme.ShelfarrTheme

@Composable
fun HomeScreen(
    state: HomeState,
    host: String?,
    onOpen: (Publication) -> Unit,
    onContinue: (Publication) -> Unit,
    onRetry: () -> Unit,
) {
    when (state) {
        HomeState.Loading -> LoadingState()
        is HomeState.Failed -> {
            val copy = errorCopy(state.error, host)
            MessageState(copy.title, copy.message, icon = ShelfarrIcons.Offline, action = "Try again", onAction = onRetry)
        }
        is HomeState.Loaded -> if (state.isEmpty) {
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                Wordmark()
                MessageState(
                    "Nothing on the shelf yet",
                    "Books and audiobooks appear here once Shelfarr has acquired them for your library.",
                )
            }
        } else {
            HomeContent(state, onOpen, onContinue)
        }
    }
}

@Composable
private fun Wordmark() {
    Text(
        "Shelfarr",
        style = MaterialTheme.typography.headlineMedium,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
    )
}

@Composable
private fun HomeContent(state: HomeState.Loaded, onOpen: (Publication) -> Unit, onContinue: (Publication) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().statusBarsPadding(),
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        item { Wordmark() }

        state.inProgress.firstOrNull()?.let { current ->
            item {
                ContinueCard(
                    publication = current,
                    onClick = { onContinue(current) },
                    modifier = Modifier.padding(horizontal = 20.dp).padding(top = 4.dp, bottom = 8.dp),
                )
            }
        }
        if (state.inProgress.size > 1) {
            item { Shelf("Also in progress", state.inProgress.drop(1), onOpen) }
        }
        if (state.books.isNotEmpty()) item { Shelf("Books", state.books, onOpen) }
        if (state.audiobooks.isNotEmpty()) item { Shelf("Audiobooks", state.audiobooks, onOpen) }
    }
}

@Composable
fun ContinueCard(publication: Publication, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        onClick = onClick,
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = MaterialTheme.shapes.large,
        border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(84.dp)) { BookCover(publication, Modifier.fillMaxWidth()) }
            Column(Modifier.padding(start = 16.dp).weight(1f)) {
                Text(
                    if (publication.bookType == BookType.EBOOK) "Continue reading" else "Continue listening",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    publication.title,
                    style = MaterialTheme.typography.titleLarge,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                publication.author?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = ShelfarrTheme.extended.inkMuted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(12.dp))
                publication.progressFraction()?.let { ProgressRule(it) }
                publication.progressLabel()?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.labelSmall,
                        color = ShelfarrTheme.extended.inkMuted,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun Shelf(title: String, items: List<Publication>, onOpen: (Publication) -> Unit) {
    val scale = shelfScale()
    Column(Modifier.padding(top = 20.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(horizontal = 20.dp).semantics { heading() },
        )
        Spacer(Modifier.height(12.dp))
        LazyRow(
            contentPadding = PaddingValues(horizontal = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            val square = items.all { it.bookType == BookType.AUDIOBOOK }
            val width = (if (square) 128.dp else 112.dp) * scale
            items(items, key = { it.id }) { publication ->
                ShelfItem(publication, Modifier.width(width), square) { onOpen(publication) }
            }
        }
    }
}

/** One book on a shelf: jacket on the baseline, then title and author. */
@Composable
fun ShelfItem(publication: Publication, modifier: Modifier = Modifier, square: Boolean = false, onClick: () -> Unit) {
    Column(modifier.clickable(role = Role.Button, onClick = onClick)) {
        Box {
            ShelfCover(publication, square = square)
            if (publication.bookType == BookType.AUDIOBOOK) {
                Surface(
                    color = MaterialTheme.colorScheme.background.copy(alpha = 0.92f),
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.align(Alignment.BottomEnd).padding(5.dp),
                ) {
                    Icon(ShelfarrIcons.Headphones, "Audiobook", modifier = Modifier.padding(3.dp).size(14.dp))
                }
            }
        }
        publication.progressFraction()?.let { ProgressRule(it, Modifier.padding(top = 6.dp)) }
        Text(
            publication.title,
            style = MaterialTheme.typography.titleSmall,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 8.dp),
        )
        publication.author?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = ShelfarrTheme.extended.inkMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
