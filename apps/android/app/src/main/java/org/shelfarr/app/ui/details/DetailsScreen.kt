package org.shelfarr.app.ui.details

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Publication
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.LoadingState
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.PrimaryButton
import org.shelfarr.app.ui.components.ProgressRule
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.formatBytes
import org.shelfarr.app.ui.primaryActionLabel
import org.shelfarr.app.ui.progressFraction
import org.shelfarr.app.ui.progressLabel
import org.shelfarr.app.ui.theme.ShelfarrTheme

sealed interface DetailsState {
    data object Loading : DetailsState
    data class Loaded(val publication: Publication) : DetailsState
    data class Failed(val error: ApiException) : DetailsState
}

class DetailsViewModel(private val container: AppContainer, private val id: String) : ViewModel() {
    private val mutableState = MutableStateFlow<DetailsState>(DetailsState.Loading)
    val state: StateFlow<DetailsState> = mutableState.asStateFlow()

    fun load() {
        val server = container.sessions.signedIn?.server ?: return
        viewModelScope.launch {
            try {
                mutableState.value = DetailsState.Loaded(container.api.publication(server, id))
            } catch (error: ApiException) {
                if (mutableState.value !is DetailsState.Loaded) mutableState.value = DetailsState.Failed(error)
            }
        }
    }

    fun retry() {
        mutableState.value = DetailsState.Loading
        load()
    }
}

@Composable
fun DetailsScreen(
    state: DetailsState,
    host: String?,
    onBack: () -> Unit,
    onPrimary: (Publication) -> Unit,
    onRetry: () -> Unit,
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
            is DetailsState.Loaded -> Details(state.publication, onPrimary)
        }
    }
}

@Composable
private fun Details(publication: Publication, onPrimary: (Publication) -> Unit) {
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

            publication.description?.takeIf(String::isNotBlank)?.let { Description(it) }
            FileDetails(publication)
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

@Composable
private fun FileDetails(publication: Publication) {
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
            if (publication.bookType == BookType.AUDIOBOOK) "Streams from your server" else "Opens from your server",
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
