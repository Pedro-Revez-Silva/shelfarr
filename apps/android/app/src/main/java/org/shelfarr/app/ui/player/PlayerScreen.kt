package org.shelfarr.app.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.util.Locale
import org.shelfarr.app.core.SyncStatus
import org.shelfarr.app.playback.AudioChapter
import org.shelfarr.app.playback.PlaybackProblem
import org.shelfarr.app.playback.PlaybackSnapshot
import org.shelfarr.app.reader.ResumeChoiceDialog
import org.shelfarr.app.ui.components.BookCover
import org.shelfarr.app.ui.components.LoadingState
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.QuietSlider
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.formatDuration
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** Actions the player exposes, so the screen can be drawn without a live service. */
interface PlayerControls {
    fun togglePlay()
    fun seekTo(positionMs: Long)
    fun skipBack()
    fun skipForward()
    fun playTrack(index: Int)
    fun playChapter(chapter: AudioChapter)
    fun setSpeed(speed: Float)
    fun setSleepTimer(minutes: Int?)
}

@Composable
fun PlayerRoute(
    state: PlayerState,
    snapshot: PlaybackSnapshot,
    syncStatus: SyncStatus,
    host: String?,
    controls: PlayerControls,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onChooseResume: (keepLocal: Boolean) -> Unit,
    onKeepThisPlace: () -> Unit,
    onUseOtherPlace: () -> Unit,
) {
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            IconButton(onClick = onBack, modifier = Modifier.padding(4.dp)) {
                Icon(ShelfarrIcons.Back, "Back")
            }
            when (state) {
                PlayerState.Loading -> LoadingState(label = "Preparing audio")
                is PlayerState.ChooseResume -> ResumeChoiceDialog(
                    local = state.local,
                    server = state.server,
                    onKeepLocal = { onChooseResume(true) },
                    onUseServer = { onChooseResume(false) },
                )
                is PlayerState.Failed -> {
                    val copy = errorCopy(state.error, host)
                    MessageState(
                        copy.title,
                        copy.message,
                        icon = ShelfarrIcons.Offline,
                        action = if (copy.retryable) "Try again" else null,
                        onAction = onRetry,
                    )
                }
                PlayerState.NoAudio -> MessageState(
                    "Nothing to play",
                    "This publication has no audio file the app can play.",
                )
                is PlayerState.Active -> if (snapshot.isLoaded) {
                    PlayerContent(snapshot, state.notice, controls)
                } else {
                    MessageState(
                        "Playback stopped",
                        "Open this audiobook again to carry on.",
                        action = "Reload",
                        onAction = onRetry,
                    )
                }
            }
        }
        (syncStatus as? SyncStatus.Conflict)?.let { conflict ->
            conflict.local?.let { local ->
                ResumeChoiceDialog(local, conflict.server, onKeepThisPlace, onUseOtherPlace)
            }
        }
    }
}

private enum class PlayerSheet { NONE, CONTENTS, SPEED, SLEEP }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerContent(snapshot: PlaybackSnapshot, notice: String?, controls: PlayerControls) {
    val publication = snapshot.publication ?: return
    var sheet by remember { mutableStateOf(PlayerSheet.NONE) }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val coverSize = minOf(maxWidth - 72.dp, maxHeight * 0.44f, 420.dp)
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.size(coverSize), contentAlignment = Alignment.Center) {
                BookCover(publication, Modifier.size(coverSize), corner = 8.dp, elevation = 12.dp)
            }
            Spacer(Modifier.height(24.dp))
            Text(
                publication.title,
                style = MaterialTheme.typography.headlineSmall,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            publication.author?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = ShelfarrTheme.extended.inkMuted,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            placeLine(snapshot)?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }

            notice?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = ShelfarrTheme.extended.inkMuted,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 10.dp),
                )
            }
            snapshot.problem?.let { problem ->
                Text(
                    problemCopy(problem),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 10.dp),
                )
            }

            Spacer(Modifier.height(16.dp))
            Scrubber(snapshot, controls)
            Spacer(Modifier.height(8.dp))
            Transport(snapshot, controls)
            Spacer(Modifier.height(20.dp))

            val quiet = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onBackground)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                TextButton(onClick = { sheet = PlayerSheet.SPEED }, colors = quiet) {
                    Text(speedLabel(snapshot.speed), style = MaterialTheme.typography.labelLarge)
                }
                TextButton(onClick = { sheet = PlayerSheet.SLEEP }, colors = quiet) {
                    Icon(ShelfarrIcons.Moon, null, modifier = Modifier.size(18.dp))
                    Text(
                        if (snapshot.sleepTimerEndsAtMs != null) "Sleep on" else "Sleep",
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
                if (snapshot.tracks.size > 1 || snapshot.chapters.isNotEmpty()) {
                    TextButton(onClick = { sheet = PlayerSheet.CONTENTS }, colors = quiet) {
                        Icon(ShelfarrIcons.Contents, null, modifier = Modifier.size(18.dp))
                        Text(
                            if (snapshot.chapters.isNotEmpty()) "Chapters" else "Tracks",
                            style = MaterialTheme.typography.labelLarge,
                            modifier = Modifier.padding(start = 6.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }

    if (sheet != PlayerSheet.NONE) {
        ModalBottomSheet(onDismissRequest = { sheet = PlayerSheet.NONE }) {
            when (sheet) {
                PlayerSheet.CONTENTS -> ContentsSheet(snapshot, controls) { sheet = PlayerSheet.NONE }
                PlayerSheet.SPEED -> ChoiceSheet(
                    "Playback speed",
                    SPEEDS,
                    snapshot.speed,
                    ::speedLabel,
                ) {
                    controls.setSpeed(it)
                    sheet = PlayerSheet.NONE
                }
                PlayerSheet.SLEEP -> ChoiceSheet(
                    "Sleep timer",
                    SLEEP_MINUTES,
                    null,
                    { if (it == 0) "Off" else "$it minutes" },
                ) {
                    controls.setSleepTimer(it)
                    sheet = PlayerSheet.NONE
                }
                PlayerSheet.NONE -> Unit
            }
        }
    }
}

private val SPEEDS = listOf(0.8f, 1f, 1.2f, 1.5f, 1.75f, 2f, 2.5f, 3f)
private val SLEEP_MINUTES = listOf(0, 15, 30, 45, 60)

private fun speedLabel(speed: Float): String = String.format(Locale.getDefault(), "%.2f", speed)
    .trimEnd('0')
    .trimEnd('.', ',')
    .let { if (it.contains('.') || it.contains(',')) it else "$it.0" } + "×"

private fun placeLine(snapshot: PlaybackSnapshot): String? {
    val chapter = snapshot.chapters.getOrNull(snapshot.chapterIndex)
    return when {
        chapter != null -> chapter.title ?: "Chapter ${snapshot.chapterIndex + 1}"
        snapshot.tracks.size > 1 -> "Track ${snapshot.trackIndex + 1} of ${snapshot.tracks.size}"
        else -> null
    }
}

private fun problemCopy(problem: PlaybackProblem): String = when (problem) {
    PlaybackProblem.CONNECTION -> "Lost the connection to your server. Press play to try again."
    PlaybackProblem.SIGN_IN -> "Your sign-in has ended, so audio can't load."
    PlaybackProblem.UNSUPPORTED -> "This device can't play this audio file."
    PlaybackProblem.UNAVAILABLE -> "Your server couldn't provide this file."
}

@Composable
private fun Scrubber(snapshot: PlaybackSnapshot, controls: PlayerControls) {
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    val duration = snapshot.durationMs.coerceAtLeast(0)
    val shown = scrubbing?.toLong() ?: snapshot.positionMs.coerceAtMost(duration.takeIf { it > 0 } ?: Long.MAX_VALUE)

    Column {
        QuietSlider(
            value = shown.toFloat(),
            onValueChange = { scrubbing = it },
            onValueChangeFinished = {
                scrubbing?.let { controls.seekTo(it.toLong()) }
                scrubbing = null
            },
            enabled = duration > 0,
            valueRange = 0f..duration.toFloat().coerceAtLeast(1f),
            activeColor = MaterialTheme.colorScheme.primary,
            trackColor = ShelfarrTheme.extended.hairline,
            modifier = Modifier.semantics {
                contentDescription = "Position"
                stateDescription = "${formatDuration(shown)} of ${formatDuration(duration)}"
            },
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum")
            Text(formatDuration(shown), style = style, color = ShelfarrTheme.extended.inkMuted)
            Text(
                if (duration > 0) "-${formatDuration(duration - shown)}" else "--:--",
                style = style,
                color = ShelfarrTheme.extended.inkMuted,
            )
        }
    }
}

@Composable
private fun Transport(snapshot: PlaybackSnapshot, controls: PlayerControls) {
    val chapters = snapshot.chapters
    val hasPrevious = chapters.isNotEmpty() || snapshot.trackIndex > 0
    val hasNext = if (chapters.isNotEmpty()) {
        snapshot.chapterIndex < chapters.lastIndex
    } else {
        snapshot.trackIndex < snapshot.tracks.lastIndex
    }
    val canStep = chapters.isNotEmpty() || snapshot.tracks.size > 1

    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (canStep) {
            IconButton(
                onClick = {
                    if (chapters.isNotEmpty()) {
                        val index = (snapshot.chapterIndex - 1).coerceAtLeast(0)
                        controls.playChapter(chapters[index])
                    } else {
                        controls.playTrack(snapshot.trackIndex - 1)
                    }
                },
                enabled = hasPrevious,
            ) { Icon(ShelfarrIcons.PreviousTrack, "Previous") }
        }
        SkipButton(ShelfarrIcons.SkipBack, "15", "Back 15 seconds", controls::skipBack)

        Box(
            Modifier
                .size(76.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primary)
                .clickable(role = Role.Button, onClick = controls::togglePlay)
                .semantics {
                    contentDescription = if (snapshot.isPlaying) "Pause" else "Play"
                },
            contentAlignment = Alignment.Center,
        ) {
            if (snapshot.isBuffering) {
                CircularProgressIndicator(
                    color = MaterialTheme.colorScheme.onPrimary,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(28.dp),
                )
            } else {
                Icon(
                    if (snapshot.isPlaying) ShelfarrIcons.Pause else ShelfarrIcons.Play,
                    null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(34.dp),
                )
            }
        }

        SkipButton(ShelfarrIcons.SkipForward, "30", "Forward 30 seconds", controls::skipForward)
        if (canStep) {
            IconButton(
                onClick = {
                    if (chapters.isNotEmpty()) {
                        controls.playChapter(chapters[snapshot.chapterIndex + 1])
                    } else {
                        controls.playTrack(snapshot.trackIndex + 1)
                    }
                },
                enabled = hasNext,
            ) { Icon(ShelfarrIcons.NextTrack, "Next") }
        }
    }
}

@Composable
private fun SkipButton(icon: ImageVector, label: String, description: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(56.dp)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, modifier = Modifier.size(34.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(top = 7.dp))
    }
}

@Composable
private fun ContentsSheet(snapshot: PlaybackSnapshot, controls: PlayerControls, onDone: () -> Unit) {
    val chapters = snapshot.chapters
    Column {
        Text(
            if (chapters.isNotEmpty()) "Chapters" else "Tracks",
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp),
        )
        LazyColumn {
            if (chapters.isNotEmpty()) {
                itemsIndexed(chapters) { index, chapter ->
                    SheetRow(
                        title = chapter.title ?: "Chapter ${index + 1}",
                        trailing = formatDuration(chapter.startMs),
                        selected = index == snapshot.chapterIndex,
                    ) {
                        controls.playChapter(chapter)
                        onDone()
                    }
                }
            } else {
                itemsIndexed(snapshot.tracks) { index, asset ->
                    SheetRow(
                        title = asset.filename.ifEmpty { "Track ${index + 1}" },
                        trailing = null,
                        selected = index == snapshot.trackIndex,
                    ) {
                        controls.playTrack(index)
                        onDone()
                    }
                }
            }
        }
    }
}

@Composable
private fun <T> ChoiceSheet(
    title: String,
    options: List<T>,
    selected: T?,
    label: (T) -> String,
    onSelect: (T) -> Unit,
) {
    Column(Modifier.padding(bottom = 16.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 8.dp),
        )
        options.forEach { option ->
            SheetRow(label(option), null, option == selected) { onSelect(option) }
        }
    }
}

@Composable
private fun SheetRow(title: String, trailing: String?, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.bodyMedium,
            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        trailing?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
        }
        if (selected) {
            Icon(
                ShelfarrIcons.Check,
                "Selected",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 12.dp).size(20.dp),
            )
        }
    }
}

/** The always-available strip above the tab bar while audio is loaded. */
@Composable
fun MiniPlayer(snapshot: PlaybackSnapshot, onOpen: () -> Unit, onToggle: () -> Unit, modifier: Modifier = Modifier) {
    val publication = snapshot.publication ?: return
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        modifier = modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onOpen)
            .semantics { contentDescription = "Now playing: ${publication.title}. Open player." },
    ) {
        Column {
            val fraction = if (snapshot.durationMs > 0) snapshot.positionMs.toFloat() / snapshot.durationMs else 0f
            Box(Modifier.fillMaxWidth().height(2.dp).background(ShelfarrTheme.extended.hairline)) {
                Box(
                    Modifier
                        .fillMaxWidth(fraction.coerceIn(0f, 1f))
                        .height(2.dp)
                        .background(MaterialTheme.colorScheme.primary),
                )
            }
            Row(
                Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.width(40.dp)) { BookCover(publication, Modifier.fillMaxWidth(), elevation = 1.dp) }
                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                    Text(publication.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
                IconButton(onClick = onToggle) {
                    if (snapshot.isBuffering) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(
                            if (snapshot.isPlaying) ShelfarrIcons.Pause else ShelfarrIcons.Play,
                            if (snapshot.isPlaying) "Pause" else "Play",
                        )
                    }
                }
            }
        }
    }
}
