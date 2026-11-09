package org.shelfarr.app.reader.pages

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.ui.components.QuietSlider
import org.shelfarr.app.ui.components.ShelfarrIcons

/** A request to show a page. Saving is decided by the view model when the pager settles. */
data class PageCommand(val index: Int, val animate: Boolean)

/** A saved place that this file can't show, waiting for the reader's choice. */
data class InvalidPlace(val saved: String, val pageCount: Int)

private const val MAX_ZOOM = 5f
private const val DOUBLE_TAP_ZOOM = 2.5f

/**
 * Full-page reading for PDFs and comics: one quiet page at a time. A tap in the middle
 * shows or hides the controls; taps near the edges, swipes, keys and the controls turn
 * pages. Pinch or double-tap zooms; while zoomed, dragging pans instead of turning.
 */
@Composable
fun PagedReader(
    title: String,
    format: ReadingFormat,
    pageCount: Int,
    initialPage: Int,
    theme: ReaderTheme,
    chromeVisible: Boolean,
    render: suspend (index: Int, width: Int, height: Int) -> Bitmap,
    onPageSettled: (Int) -> Unit,
    onToggleChrome: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    commands: Flow<PageCommand> = emptyFlow(),
    notice: String? = null,
    invalidPlace: InvalidPlace? = null,
    onResolveInvalidPlace: (Int) -> Unit = {},
) {
    val pager = rememberPagerState(initialPage = initialPage.coerceIn(0, (pageCount - 1).coerceAtLeast(0))) { pageCount }
    val scope = rememberCoroutineScope()
    val settled by rememberUpdatedState(onPageSettled)
    var zoomed by remember { mutableStateOf(false) }
    var goTo by remember { mutableStateOf(false) }
    var shownNotice by remember(notice) { mutableStateOf(notice) }

    LaunchedEffect(pager) { snapshotFlow { pager.settledPage }.collect { settled(it) } }
    LaunchedEffect(pager, commands) {
        commands.collect { command ->
            val target = command.index.coerceIn(0, pageCount - 1)
            if (command.animate) pager.animateScrollToPage(target) else pager.scrollToPage(target)
        }
    }
    LaunchedEffect(shownNotice) {
        if (shownNotice != null) {
            delay(7_000)
            shownNotice = null
        }
    }

    fun show(index: Int, animate: Boolean = true) {
        val target = index.coerceIn(0, pageCount - 1)
        scope.launch { if (animate) pager.animateScrollToPage(target) else pager.scrollToPage(target) }
    }

    val current = pager.currentPage
    Box(modifier.fillMaxSize().background(theme.pageColor)) {
        HorizontalPager(
            state = pager,
            beyondViewportPageCount = 1,
            userScrollEnabled = !zoomed,
            key = { it },
            modifier = Modifier.fillMaxSize(),
        ) { index ->
            ZoomablePage(
                index = index,
                pageCount = pageCount,
                isCurrent = index == pager.currentPage,
                theme = theme,
                render = render,
                onZoomed = { if (index == pager.currentPage) zoomed = it },
                onTapZone = { zone ->
                    when (zone) {
                        TapZone.PREVIOUS -> show(index - 1)
                        TapZone.NEXT -> show(index + 1)
                        TapZone.MIDDLE -> onToggleChrome()
                    }
                },
                onAccessibilityTurn = { delta -> show(index + delta) },
                onToggleChrome = onToggleChrome,
            )
        }

        if (!chromeVisible) {
            Text(
                "${current + 1} / $pageCount",
                style = MaterialTheme.typography.labelSmall,
                color = theme.mutedColor,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 10.dp),
            )
        }

        AnimatedVisibility(chromeVisible, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize()) {
                PageBars(
                    title = title,
                    format = format,
                    page = current,
                    pageCount = pageCount,
                    theme = theme,
                    onClose = onClose,
                    onGoTo = { goTo = true },
                    onShow = { show(it, animate = false) },
                    onTurn = { delta -> show(current + delta) },
                )
            }
        }

        shownNotice?.let { text ->
            Snackbar(
                containerColor = theme.barColor,
                contentColor = theme.textColor,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(16.dp),
            ) { Text(text) }
        }
    }

    if (goTo) {
        GoToPageDialog(
            pageCount = pageCount,
            current = current,
            onGo = { index ->
                goTo = false
                show(index, animate = false)
            },
            onDismiss = { goTo = false },
        )
    }

    invalidPlace?.let { place ->
        InvalidPlaceDialog(place, format) { index ->
            onResolveInvalidPlace(index)
        }
    }
}

enum class TapZone { PREVIOUS, MIDDLE, NEXT }

/** Edge quarters turn pages; the middle half shows or hides the controls. */
internal fun tapZone(x: Float, width: Int): TapZone = when {
    width <= 0 -> TapZone.MIDDLE
    x < width * 0.25f -> TapZone.PREVIOUS
    x > width * 0.75f -> TapZone.NEXT
    else -> TapZone.MIDDLE
}

/** The largest translation that keeps a page scaled by [scale] covering its own box. */
internal fun clampOffset(offset: Offset, scale: Float, size: IntSize): Offset {
    val maxX = (scale - 1f) * size.width / 2f
    val maxY = (scale - 1f) * size.height / 2f
    return Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
}

@Composable
private fun ZoomablePage(
    index: Int,
    pageCount: Int,
    isCurrent: Boolean,
    theme: ReaderTheme,
    render: suspend (Int, Int, Int) -> Bitmap,
    onZoomed: (Boolean) -> Unit,
    onTapZone: (TapZone) -> Unit,
    onAccessibilityTurn: (Int) -> Unit,
    onToggleChrome: () -> Unit,
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val zoomedNow by rememberUpdatedState(onZoomed)

    LaunchedEffect(isCurrent) {
        if (!isCurrent && scale != 1f) {
            scale = 1f
            offset = Offset.Zero
        }
    }
    LaunchedEffect(scale > 1.01f, isCurrent) { if (isCurrent) zoomedNow(scale > 1.01f) }

    val label = "Page ${index + 1} of $pageCount"
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .pointerInput(index) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2 || scale > 1.01f) {
                            val zoom = event.calculateZoom()
                            val pan = event.calculatePan()
                            val centroid = event.calculateCentroid(useCurrent = true)
                            val next = (scale * zoom).coerceIn(1f, MAX_ZOOM)
                            val factor = next / scale
                            val center = Offset(this.size.width / 2f, this.size.height / 2f)
                            val anchor = if (centroid == Offset.Unspecified) center else centroid
                            val moved = (anchor - center) - (anchor - center - offset) * factor + pan
                            scale = next
                            offset = if (next <= 1.01f) Offset.Zero else clampOffset(moved, next, this.size)
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        }
                    } while (event.changes.any { it.pressed })
                }
            }
            .pointerInput(index) {
                detectTapGestures(
                    onTap = { point -> onTapZone(tapZone(point.x, this.size.width)) },
                    onDoubleTap = { point ->
                        if (scale > 1.01f) {
                            scale = 1f
                            offset = Offset.Zero
                        } else {
                            val center = Offset(this.size.width / 2f, this.size.height / 2f)
                            scale = DOUBLE_TAP_ZOOM
                            offset = clampOffset((point - center) * (1f - DOUBLE_TAP_ZOOM), DOUBLE_TAP_ZOOM, this.size)
                        }
                    },
                )
            }
            .semantics {
                contentDescription = label
                onClick(label = "Show or hide reading controls") {
                    onToggleChrome()
                    true
                }
                customActions = listOf(
                    CustomAccessibilityAction("Next page") { onAccessibilityTurn(1); true },
                    CustomAccessibilityAction("Previous page") { onAccessibilityTurn(-1); true },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        val density = LocalDensity.current
        val width = with(density) { maxWidth.roundToPx() }
        val height = with(density) { maxHeight.roundToPx() }
        // A sharper copy while zoomed, still bounded by MAX_PAGE_PIXELS.
        val detail = when {
            scale > 3f -> 3
            scale > 1.4f -> 2
            else -> 1
        }
        val base = rememberPage(index, width, height, 1, render)
        val sharp = if (detail > 1 && isCurrent) rememberPage(index, width * detail, height * detail, detail, render) else null
        val shown = (sharp as? PageImage.Ready) ?: base
        when (shown) {
            is PageImage.Ready -> {
                val image = remember(shown.bitmap) { shown.bitmap.asImageBitmap() }
                Image(
                    image,
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = scale
                            scaleY = scale
                            translationX = offset.x
                            translationY = offset.y
                        },
                )
            }
            is PageImage.Failed -> Text(
                "Couldn't show page ${index + 1}. ${shown.message}",
                style = MaterialTheme.typography.bodyMedium,
                color = theme.textColor,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(32.dp),
            )
            PageImage.Loading -> Unit
        }
    }
}

private sealed interface PageImage {
    data object Loading : PageImage
    data class Ready(val bitmap: Bitmap) : PageImage
    data class Failed(val message: String) : PageImage
}

@Composable
private fun rememberPage(index: Int, width: Int, height: Int, detail: Int, render: suspend (Int, Int, Int) -> Bitmap): PageImage {
    val state = produceState<PageImage>(PageImage.Loading, index, width, height, detail) {
        if (width <= 0 || height <= 0) return@produceState
        value = try {
            PageImage.Ready(render(index, width, height))
        } catch (error: org.shelfarr.app.core.UnreadableFile) {
            PageImage.Failed(error.message.orEmpty())
        } catch (error: OutOfMemoryError) {
            PageImage.Failed("This device ran out of memory for it.")
        }
    }
    return state.value
}

@Composable
private fun PageBars(
    title: String,
    format: ReadingFormat,
    page: Int,
    pageCount: Int,
    theme: ReaderTheme,
    onClose: () -> Unit,
    onGoTo: () -> Unit,
    onShow: (Int) -> Unit,
    onTurn: (Int) -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.align(Alignment.TopCenter).background(theme.barColor).statusBarsPadding()) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onClose) { Icon(ShelfarrIcons.Back, "Close book", tint = theme.textColor) }
                Column(Modifier.weight(1f).padding(start = 4.dp, end = 16.dp, top = 6.dp, bottom = 6.dp)) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleSmall,
                        color = theme.textColor,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(format.label, style = MaterialTheme.typography.labelSmall, color = theme.mutedColor, maxLines = 1)
                }
            }
            HorizontalDivider(color = theme.hairlineColor)
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(theme.barColor).navigationBarsPadding()) {
            HorizontalDivider(color = theme.hairlineColor)
            Column(Modifier.padding(start = 8.dp, end = 8.dp, top = 8.dp, bottom = 8.dp)) {
                // The page number is also the way to jump to any page.
                TextButton(
                    onClick = onGoTo,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .semantics {
                            onClick(label = "Go to page") {
                                onGoTo()
                                true
                            }
                        },
                ) {
                    Text(
                        "Page ${page + 1} of $pageCount",
                        style = MaterialTheme.typography.labelLarge,
                        color = theme.accentColor,
                        textAlign = TextAlign.Center,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { onTurn(-1) }, enabled = page > 0) {
                        Icon(ShelfarrIcons.Back, "Previous page", tint = if (page > 0) theme.textColor else theme.hairlineColor)
                    }
                    var scrubbing by remember { mutableStateOf<Float?>(null) }
                    Box(Modifier.weight(1f)) {
                        if (pageCount > 1) {
                            QuietSlider(
                                value = scrubbing ?: page.toFloat(),
                                onValueChange = { scrubbing = it },
                                onValueChangeFinished = {
                                    scrubbing?.let { onShow(it.roundToInt()) }
                                    scrubbing = null
                                },
                                valueRange = 0f..(pageCount - 1).toFloat(),
                                activeColor = theme.accentColor,
                                trackColor = theme.hairlineColor,
                                modifier = Modifier.semantics {
                                    contentDescription = "Page"
                                    stateDescription = "Page ${(scrubbing?.roundToInt() ?: page) + 1} of $pageCount"
                                },
                            )
                        }
                    }
                    IconButton(onClick = { onTurn(1) }, enabled = page < pageCount - 1) {
                        Icon(
                            ShelfarrIcons.Back,
                            "Next page",
                            tint = if (page < pageCount - 1) theme.textColor else theme.hairlineColor,
                            modifier = Modifier.rotate(180f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun GoToPageDialog(pageCount: Int, current: Int, onGo: (Int) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf((current + 1).toString()) }
    val number = text.trim().toIntOrNull()
    val valid = number != null && number in 1..pageCount
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Go to page") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { value -> text = value.filter(Char::isDigit).take(6) },
                label = { Text("Page (1–$pageCount)") },
                isError = text.isNotEmpty() && !valid,
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { if (valid && number != null) onGo(number - 1) }),
            )
        },
        confirmButton = { TextButton(onClick = { if (number != null) onGo(number - 1) }, enabled = valid) { Text("Go") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun InvalidPlaceDialog(place: InvalidPlace, format: ReadingFormat, onChoose: (Int) -> Unit) {
    val kind = if (format == ReadingFormat.PDF) "PDF" else "comic"
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Your saved place isn't in this file") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Your place was saved at ${place.saved}, but this $kind has ${place.pageCount} ${if (place.pageCount == 1) "page" else "pages"}.")
                Text("Your saved place is kept until you turn a page.", style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = { TextButton(onClick = { onChoose(0) }) { Text("Start at page 1") } },
        dismissButton = if (place.pageCount > 1) {
            { TextButton(onClick = { onChoose(place.pageCount - 1) }) { Text("Go to page ${place.pageCount}") } }
        } else {
            null
        },
    )
}
