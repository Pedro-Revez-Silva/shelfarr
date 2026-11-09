package org.shelfarr.app.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.reader.pages.PagedReader
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.SyncStatus
import org.shelfarr.app.ui.components.MessageState
import org.shelfarr.app.ui.components.QuietSlider
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.components.errorCopy
import org.shelfarr.app.ui.describePlace
import kotlin.math.roundToInt
import org.readium.r2.shared.publication.Link

/** Everything drawn above the book. Touches pass through whenever the chrome is hidden. */
@Composable
fun ReaderScreen(
    viewModel: ReaderViewModel,
    chromeVisible: Boolean,
    onToggleChrome: () -> Unit,
    onClose: () -> Unit,
    onGo: (Link) -> Unit,
    onScrub: (Float) -> Unit,
    onUseOtherPlace: () -> Unit,
    narration: NarrationActions = NarrationActions.None,
) {
    val state by viewModel.state.collectAsState()
    val readAlong by viewModel.readAlongUi.collectAsState()
    val settings by viewModel.settings.collectAsState()
    val place by viewModel.place.collectAsState()
    val sync by viewModel.syncStatus.collectAsState()
    val theme = settings.theme

    when (val current = state) {
        is ReaderState.Preparing -> Preparing(theme, current.fraction, onClose)
        is ReaderState.ChooseResume -> {
            Box(Modifier.fillMaxSize().background(theme.pageColor))
            ResumeChoiceDialog(
                local = current.local,
                server = current.server,
                onKeepLocal = { viewModel.chooseResume(keepLocal = true) },
                onUseServer = { viewModel.chooseResume(keepLocal = false) },
            )
        }
        is ReaderState.Failed -> {
            val copy = errorCopy(current.error, viewModel.serverHost)
            ReaderMessage(theme, copy.title, copy.message, onClose, if (copy.retryable) viewModel::open else null)
        }
        ReaderState.Unreadable -> ReaderMessage(
            theme,
            "Can't open this book",
            "This file isn't a readable EPUB, or it's protected by DRM.",
            onClose,
            null,
        )
        is ReaderState.Damaged -> ReaderMessage(theme, "Can't open this file", current.message, onClose, null)
        is ReaderState.ChooseFormat -> FormatChoice(theme, current, onClose, viewModel::chooseFormat)
        is ReaderState.Paged -> {
            val page by viewModel.page.collectAsState()
            // A rotation rebuilds the pager on the page already on screen. Seeing the last-read page again reports nothing new.
            androidx.compose.runtime.key(current.format, current.pageCount) {
                PagedReader(
                    title = current.title,
                    format = current.format,
                    pageCount = current.pageCount,
                    initialPage = page,
                    theme = theme,
                    chromeVisible = chromeVisible,
                    render = viewModel::renderPage,
                    onPageSettled = viewModel::onPageSettled,
                    onPageShown = viewModel::onPageShown,
                    onToggleChrome = onToggleChrome,
                    onClose = onClose,
                    commands = viewModel.pageCommands,
                    notice = current.notice,
                    invalidPlace = current.invalidPlace,
                    onResolveInvalidPlace = viewModel::resolveInvalidPlace,
                )
            }
            SyncOverlays(sync, theme, viewModel::keepThisPlace, onUseOtherPlace)
        }
        is ReaderState.Ready -> {
            ReaderChrome(
                ready = current,
                settings = settings,
                place = place,
                visible = chromeVisible,
                onClose = onClose,
                onGo = onGo,
                onScrub = onScrub,
                onSettings = { change -> viewModel.updateSettings(change) },
                readAlong = readAlong,
                narration = narration,
            )
            SyncOverlays(sync, theme, viewModel::keepThisPlace, onUseOtherPlace)
        }
    }
}

@Composable
private fun SyncOverlays(sync: SyncStatus, theme: ReaderTheme, onKeepLocal: () -> Unit, onUseOtherPlace: () -> Unit) {
    (sync as? SyncStatus.Conflict)?.let { conflict ->
        conflict.local?.let { local ->
            ResumeChoiceDialog(
                local = local,
                server = conflict.server,
                onKeepLocal = onKeepLocal,
                onUseServer = onUseOtherPlace,
            )
        }
    }
    syncProblemCopy(sync)?.let { problem ->
        Box(Modifier.fillMaxSize()) {
            Snackbar(
                containerColor = theme.barColor,
                contentColor = theme.textColor,
                modifier = Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(16.dp),
            ) { Text(problem) }
        }
    }
}

/** Several formats and nothing saved to go by: the reader chooses, and nothing is written yet. */
@Composable
internal fun FormatChoice(theme: ReaderTheme, state: ReaderState.ChooseFormat, onClose: () -> Unit, onChoose: (String) -> Unit) {
    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize().background(theme.pageColor)) {
        val viewport = maxHeight
        // Scrolls under large text; centred when it fits.
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = viewport)
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(start = 32.dp, end = 32.dp, top = 56.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        ) {
            Text(
                "How would you like to read it?",
                style = MaterialTheme.typography.titleLarge,
                color = theme.textColor,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                "${state.title} is on your server in more than one format. Your place is saved separately for each.",
                style = MaterialTheme.typography.bodyMedium,
                color = theme.mutedColor,
            )
            state.options.forEach { option ->
                val format = option.readingFormat ?: return@forEach
                Box(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .border(1.dp, theme.hairlineColor, RoundedCornerShape(12.dp))
                        .clickable(role = Role.Button) { onChoose(option.id) }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                ) {
                    Column {
                        Text(format.label, style = MaterialTheme.typography.titleMedium, color = theme.textColor)
                        Text(formatHint(format, option.sizeBytes), style = MaterialTheme.typography.bodySmall, color = theme.mutedColor)
                    }
                }
            }
        }
        // Drawn last so it stays above the scrolling text.
        Box(Modifier.fillMaxWidth().background(theme.pageColor).statusBarsPadding()) {
            CloseButton(theme, onClose, Modifier.padding(4.dp))
        }
    }
}

private fun formatHint(format: ReadingFormat, size: Long): String {
    val kind = when (format) {
        ReadingFormat.EPUB -> "Reflowing text, with your font and size"
        ReadingFormat.PDF -> "Fixed pages, as printed"
        ReadingFormat.CBZ -> "Page images, as drawn"
    }
    return if (size > 0) "$kind · ${org.shelfarr.app.ui.formatBytes(size)}" else kind
}

@Composable
private fun Preparing(theme: ReaderTheme, fraction: Float?, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().background(theme.pageColor)) {
        CloseButton(theme, onClose, Modifier.statusBarsPadding().padding(4.dp))
        Column(
            Modifier.align(Alignment.Center).padding(horizontal = 56.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (fraction == null) "Opening…" else "Fetching this book",
                style = MaterialTheme.typography.titleLarge,
                color = theme.textColor,
            )
            if (fraction == null) {
                LinearProgressIndicator(
                    modifier = Modifier.fillMaxWidth().height(3.dp),
                    color = theme.accentColor,
                    trackColor = theme.hairlineColor,
                )
            } else {
                LinearProgressIndicator(
                    progress = { fraction },
                    modifier = Modifier.fillMaxWidth().height(3.dp),
                    color = theme.accentColor,
                    trackColor = theme.hairlineColor,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
            }
        }
    }
}

@Composable
private fun ReaderMessage(
    theme: ReaderTheme,
    title: String,
    message: String,
    onClose: () -> Unit,
    onRetry: (() -> Unit)?,
) {
    Box(Modifier.fillMaxSize().background(theme.pageColor)) {
        CloseButton(theme, onClose, Modifier.statusBarsPadding().padding(4.dp))
        MessageState(title, message, action = onRetry?.let { "Try again" }, onAction = onRetry)
    }
}

@Composable
private fun CloseButton(theme: ReaderTheme, onClose: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(onClick = onClose, modifier = modifier) {
        Icon(ShelfarrIcons.Back, "Close book", tint = theme.textColor)
    }
}

@Composable
fun BoxScope.ReaderBars(
    title: String,
    positionCount: Int,
    settings: ReaderSettings,
    place: ReadingPlace,
    onClose: () -> Unit,
    onContents: () -> Unit,
    onAppearance: () -> Unit,
    onScrub: (Float) -> Unit,
    /** Above the place and slider: read-along controls, when the book has narration. */
    extra: @Composable () -> Unit = {},
) {
    val theme = settings.theme
    Column(Modifier.align(Alignment.TopCenter).background(theme.barColor).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CloseButton(theme, onClose)
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = theme.textColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(horizontal = 4.dp),
            )
            IconButton(onClick = onContents) { Icon(ShelfarrIcons.Contents, "Contents", tint = theme.textColor) }
            IconButton(
                onClick = onAppearance,
                modifier = Modifier.semantics { contentDescription = "Reading settings" },
            ) {
                Text("Aa", style = MaterialTheme.typography.titleMedium, color = theme.textColor)
            }
        }
        HorizontalDivider(color = theme.hairlineColor)
    }

    Column(Modifier.align(Alignment.BottomCenter).background(theme.barColor).navigationBarsPadding()) {
        HorizontalDivider(color = theme.hairlineColor)
        Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 10.dp)) {
            extra()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    place.chapter.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = theme.mutedColor,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    placeLabel(place, positionCount),
                    style = MaterialTheme.typography.bodySmall,
                    color = theme.mutedColor,
                )
            }
            var scrubbing by remember { mutableStateOf<Float?>(null) }
            QuietSlider(
                value = scrubbing ?: place.fraction,
                onValueChange = { scrubbing = it },
                onValueChangeFinished = {
                    scrubbing?.let(onScrub)
                    scrubbing = null
                },
                activeColor = theme.accentColor,
                trackColor = theme.hairlineColor,
                modifier = Modifier.semantics { contentDescription = "Position in book" },
            )
        }
    }
}

private fun placeLabel(place: ReadingPlace, positions: Int): String {
    val percent = (place.fraction * 100).roundToInt()
    val position = place.position
    return if (position != null && positions > 0) "$position of $positions · $percent%" else "$percent%"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReaderChrome(
    ready: ReaderState.Ready,
    settings: ReaderSettings,
    place: ReadingPlace,
    visible: Boolean,
    onClose: () -> Unit,
    onGo: (Link) -> Unit,
    onScrub: (Float) -> Unit,
    onSettings: ((ReaderSettings) -> ReaderSettings) -> Unit,
    readAlong: ReadAlongUi = ReadAlongUi.Off,
    narration: NarrationActions = NarrationActions.None,
) {
    var sheet by remember { mutableStateOf(ReaderSheet.NONE) }
    var notice by remember(ready) { mutableStateOf(ready.notice) }
    val theme = settings.theme

    LaunchedEffect(notice) {
        if (notice != null) {
            delay(7_000)
            notice = null
        }
    }

    Box(Modifier.fillMaxSize()) {
        // Always-present quiet folio, so progress is never more than a glance away.
        if (!visible) {
            Text(
                "${(place.fraction * 100).roundToInt()}%",
                style = MaterialTheme.typography.labelSmall,
                color = theme.mutedColor,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 10.dp),
            )
            // Read-along adds nothing to the page until narration is used, or a later audiobook place is offered.
            val ready = readAlong as? ReadAlongUi.Ready
            if (ready != null && (ready.started || ready.offer != null)) {
                Column(
                    Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = 30.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    ready.offer?.let { OfferCard(it, theme, narration, Modifier.widthIn(max = 480.dp)) }
                    if (ready.started) NarrationPill(ready, theme, narration)
                }
            }
        }

        AnimatedVisibility(visible, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize()) {
                ReaderBars(
                    title = ready.title,
                    positionCount = ready.positionCount,
                    settings = settings,
                    place = place,
                    onClose = onClose,
                    onContents = { sheet = ReaderSheet.CONTENTS },
                    onAppearance = { sheet = ReaderSheet.SETTINGS },
                    onScrub = onScrub,
                    extra = { NarrationPanel(readAlong, theme, narration) },
                )
            }
        }

        notice?.let { text ->
            Snackbar(
                containerColor = theme.barColor,
                contentColor = theme.textColor,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(16.dp),
            ) { Text(text) }
        }
    }

    if (sheet != ReaderSheet.NONE) {
        ModalBottomSheet(
            onDismissRequest = { sheet = ReaderSheet.NONE },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = sheet == ReaderSheet.SETTINGS),
            containerColor = theme.barColor,
            contentColor = theme.textColor,
            scrimColor = Color.Black.copy(alpha = 0.25f),
        ) {
            when (sheet) {
                ReaderSheet.CONTENTS -> ContentsSheet(ready.contents, place.chapter, theme) { link ->
                    sheet = ReaderSheet.NONE
                    onGo(link)
                }
                ReaderSheet.SETTINGS -> SettingsSheet(settings, onSettings)
                ReaderSheet.NONE -> Unit
            }
        }
    }
}

private enum class ReaderSheet { NONE, CONTENTS, SETTINGS }

@Composable
private fun ContentsSheet(
    entries: List<ContentsEntry>,
    current: String?,
    theme: ReaderTheme,
    onSelect: (Link) -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Text(
            "Contents",
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(start = 24.dp, end = 24.dp, bottom = 12.dp),
        )
        if (entries.isEmpty()) {
            Text(
                "This book doesn't list any chapters.",
                style = MaterialTheme.typography.bodyMedium,
                color = theme.mutedColor,
                modifier = Modifier.padding(24.dp),
            )
        }
        LazyColumn {
            itemsIndexed(entries) { _, entry ->
                val selected = entry.title == current
                Text(
                    entry.title,
                    style = MaterialTheme.typography.bodyLarge,
                    color = if (selected) theme.accentColor else theme.textColor,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button) { onSelect(entry.link) }
                        .padding(start = 24.dp + 16.dp * entry.depth, end = 24.dp, top = 12.dp, bottom = 12.dp),
                )
            }
        }
    }
}

@Composable
fun SettingsSheet(settings: ReaderSettings, onChange: ((ReaderSettings) -> ReaderSettings) -> Unit) {
    val theme = settings.theme
    Column(
        Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ReaderTheme.entries.forEach { option ->
                val selected = option == theme
                Box(
                    Modifier
                        .weight(1f)
                        .height(64.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(option.pageColor)
                        .border(
                            if (selected) 2.dp else 1.dp,
                            if (selected) theme.accentColor else theme.hairlineColor,
                            RoundedCornerShape(12.dp),
                        )
                        .clickable(role = Role.RadioButton) { onChange { it.copy(theme = option) } }
                        .semantics { contentDescription = "${option.label} pages" },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(option.label, style = MaterialTheme.typography.labelLarge, color = option.textColor)
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Text size", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            StepperButton("A", "Smaller text", theme, small = true) {
                onChange { it.copy(fontSize = (it.fontSize - ReaderSettings.FontStep).coerceAtLeast(ReaderSettings.FontSizes.start)) }
            }
            Text(
                "${(settings.fontSize * 100).roundToInt()}%",
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.width(64.dp).padding(horizontal = 8.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            StepperButton("A", "Larger text", theme, small = false) {
                onChange { it.copy(fontSize = (it.fontSize + ReaderSettings.FontStep).coerceAtMost(ReaderSettings.FontSizes.endInclusive)) }
            }
        }

        OptionRow("Typeface", ReaderFont.entries, settings.font, { it.label }, theme) { font ->
            onChange { it.copy(font = font) }
        }
        OptionRow("Line spacing", LINE_HEIGHTS, settings.lineHeight, { LINE_LABELS.getValue(it) }, theme) { value ->
            onChange { it.copy(lineHeight = value) }
        }
        OptionRow("Margins", MARGINS, settings.margins, { MARGIN_LABELS.getValue(it) }, theme) { value ->
            onChange { it.copy(margins = value) }
        }

        ToggleRow("Justify text", settings.justify, theme) { value -> onChange { it.copy(justify = value) } }
        ToggleRow("Scroll instead of turning pages", settings.scroll, theme) { value -> onChange { it.copy(scroll = value) } }
    }
}

private val LINE_HEIGHTS = listOf(1.3, 1.5, 1.8)
private val LINE_LABELS = mapOf(1.3 to "Tight", 1.5 to "Normal", 1.8 to "Loose")
private val MARGINS = listOf(0.6, 1.0, 1.6)
private val MARGIN_LABELS = mapOf(0.6 to "Narrow", 1.0 to "Normal", 1.6 to "Wide")

@Composable
private fun StepperButton(label: String, description: String, theme: ReaderTheme, small: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .border(1.dp, theme.hairlineColor, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = if (small) MaterialTheme.typography.titleSmall else MaterialTheme.typography.titleLarge)
    }
}

@Composable
private fun <T> OptionRow(
    title: String,
    options: List<T>,
    selected: T,
    label: (T) -> String,
    theme: ReaderTheme,
    onSelect: (T) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.bodyMedium)
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .border(1.dp, theme.hairlineColor, RoundedCornerShape(12.dp)),
        ) {
            options.forEach { option ->
                val active = option == selected
                Box(
                    Modifier
                        .weight(1f)
                        .height(48.dp)
                        .background(if (active) theme.accentColor.copy(alpha = 0.14f) else Color.Transparent)
                        .clickable(role = Role.RadioButton) { onSelect(option) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label(option),
                        style = MaterialTheme.typography.labelLarge,
                        color = if (active) theme.accentColor else theme.textColor,
                    )
                }
            }
        }
    }
}

@Composable
private fun ToggleRow(title: String, checked: Boolean, theme: ReaderTheme, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Switch) { onChange(!checked) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = null,
            colors = SwitchDefaults.colors(
                checkedTrackColor = theme.accentColor,
                uncheckedBorderColor = theme.mutedColor,
                uncheckedThumbColor = theme.mutedColor,
                uncheckedTrackColor = Color.Transparent,
            ),
        )
    }
}

/** Shown when two devices disagree. Neither place is thrown away without a choice. */
/** What a reader or listener must know about their saved place, if anything. */
fun syncProblemCopy(status: SyncStatus): String? = when (status) {
    SyncStatus.StorageFailed -> "Couldn't save your place on this device. It will still be sent to the server when possible."
    SyncStatus.Rejected -> "The server didn't accept this place. It's still saved on this device."
    else -> null
}

@Composable
fun ResumeChoiceDialog(
    local: SavedPosition,
    server: Progress,
    onKeepLocal: () -> Unit,
    onUseServer: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Where would you like to continue?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("This device and another one saved different places, and it isn't clear which was more recent.")
                Text("This device: ${describePlace(local.locator, local.positionSeconds)}", style = MaterialTheme.typography.bodySmall)
                Text("Other device: ${describePlace(server.locator, server.positionSeconds)}", style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = onUseServer) { Text("Use other device") } },
        dismissButton = { TextButton(onClick = onKeepLocal) { Text("Keep this device") } },
    )
}
