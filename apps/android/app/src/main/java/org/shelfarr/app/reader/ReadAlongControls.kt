package org.shelfarr.app.reader

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import org.shelfarr.app.ui.components.ShelfarrIcons

/** "1×", "1.25×": narration speeds as the controls name them. */
internal fun speedLabel(speed: Float): String {
    val rounded = Math.round(speed * 100) / 100f
    val text = if (rounded == rounded.toInt().toFloat()) rounded.toInt().toString() else rounded.toString().trimEnd('0')
    return "$text×"
}

/**
 * Narration inside the reading controls: play and skip, speed, page-follow, and what the
 * narration covers. A book whose narration can't be used says why here, and only here.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun NarrationPanel(ui: ReadAlongUi, theme: ReaderTheme, actions: NarrationActions, modifier: Modifier = Modifier) {
    when (ui) {
        ReadAlongUi.Off -> Unit
        ReadAlongUi.Preparing -> Text(
            "Checking the narration…",
            style = MaterialTheme.typography.bodySmall,
            color = theme.mutedColor,
            modifier = modifier.padding(bottom = 8.dp),
        )
        is ReadAlongUi.Unavailable -> Text(
            ui.message,
            style = MaterialTheme.typography.bodySmall,
            color = theme.mutedColor,
            modifier = modifier.padding(bottom = 8.dp),
        )
        is ReadAlongUi.Ready -> Column(modifier.fillMaxWidth().padding(bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                RoundIcon(ShelfarrIcons.SkipBack, "15", "Back 15 seconds", theme, enabled = ui.started) { actions.skip(back = true) }
                PlayButton(ui, theme, actions::toggle)
                RoundIcon(ShelfarrIcons.SkipForward, "30", "Forward 30 seconds", theme, enabled = ui.started) { actions.skip(back = false) }
                SpeedButton(ui.speed, theme, actions::setSpeed)
                FollowToggle(ui.follow, theme, actions::setFollow)
            }
            ui.problem?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = theme.accentColor,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            ui.offer?.let { OfferCard(it, theme, actions) }
            Text(ui.note, style = MaterialTheme.typography.bodySmall, color = theme.mutedColor)
        }
    }
}

/**
 * With the controls hidden, once narration has been used: Pause or Play, and "Back to the
 * narration" after browsing away from it. Nothing else is added to the page.
 */
@Composable
internal fun NarrationPill(ui: ReadAlongUi.Ready, theme: ReaderTheme, actions: NarrationActions, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(28.dp),
        color = theme.barColor,
        contentColor = theme.textColor,
        border = BorderStroke(1.dp, theme.hairlineColor),
        shadowElevation = 2.dp,
        modifier = modifier,
    ) {
        Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            val label = when {
                ui.playing || ui.buffering -> "Pause"
                ui.finished -> "Play again"
                else -> "Play"
            }
            Row(
                Modifier
                    .heightIn(min = 48.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .clickable(role = Role.Button, onClick = actions::toggle)
                    .semantics { contentDescription = if (ui.playing || ui.buffering) "Pause narration" else "Play narration" }
                    .padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                PlayGlyph(ui, theme, Modifier.size(18.dp))
                Text(label, style = MaterialTheme.typography.labelLarge)
            }
            if (ui.browsing) {
                Box(Modifier.size(width = 1.dp, height = 24.dp).background(theme.hairlineColor))
                TextButton(onClick = actions::backToNarration, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Back to the narration", style = MaterialTheme.typography.labelLarge, color = theme.accentColor)
                }
            }
        }
    }
}

/** A later place heard in the paired audiobook, offered; nothing changes unless the reader goes there. */
@Composable
internal fun OfferCard(offer: AudiobookOffer, theme: ReaderTheme, actions: NarrationActions, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = theme.barColor,
        contentColor = theme.textColor,
        border = BorderStroke(1.dp, theme.hairlineColor),
        modifier = modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        Column(Modifier.padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 4.dp)) {
            Text(
                "You listened further in “${offer.title}”.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(end = 8.dp),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = actions::dismissAudiobookPlace) { Text("Not now", color = theme.mutedColor) }
                TextButton(onClick = actions::useAudiobookPlace) { Text("Go to that place", color = theme.accentColor) }
            }
        }
    }
}

@Composable
private fun PlayButton(ui: ReadAlongUi.Ready, theme: ReaderTheme, onClick: () -> Unit) {
    val description = when {
        ui.playing || ui.buffering -> "Pause narration"
        ui.finished -> "Play narration again"
        else -> "Play narration"
    }
    Box(
        Modifier
            .size(56.dp)
            .clip(CircleShape)
            .background(theme.accentColor)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        PlayGlyph(ui, theme, Modifier.size(24.dp), tint = theme.pageColor)
    }
}

@Composable
private fun PlayGlyph(ui: ReadAlongUi.Ready, theme: ReaderTheme, modifier: Modifier, tint: Color = theme.textColor) {
    if (ui.buffering) {
        CircularProgressIndicator(color = tint, strokeWidth = 2.dp, modifier = modifier)
    } else {
        Icon(if (ui.playing) ShelfarrIcons.Pause else ShelfarrIcons.Play, null, tint = tint, modifier = modifier)
    }
}

@Composable
private fun RoundIcon(icon: ImageVector, label: String, description: String, theme: ReaderTheme, enabled: Boolean, onClick: () -> Unit) {
    val tint = if (enabled) theme.textColor else theme.mutedColor.copy(alpha = 0.5f)
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(28.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, color = tint, modifier = Modifier.padding(top = 6.dp))
    }
}

@Composable
private fun SpeedButton(speed: Float, theme: ReaderTheme, onSpeed: (Float) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(
            onClick = { open = true },
            modifier = Modifier.heightIn(min = 48.dp).widthIn(min = 56.dp).semantics {
                contentDescription = "Narration speed"
                stateDescription = speedLabel(speed)
            },
        ) {
            Text(speedLabel(speed), style = MaterialTheme.typography.labelLarge, color = theme.textColor)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = theme.barColor) {
            ReaderSettings.NarrationSpeeds.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            speedLabel(option),
                            color = if (option == speed) theme.accentColor else theme.textColor,
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    },
                    onClick = {
                        open = false
                        onSpeed(option)
                    },
                )
            }
        }
    }
}

@Composable
private fun FollowToggle(follow: Boolean, theme: ReaderTheme, onFollow: (Boolean) -> Unit) {
    Row(
        Modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(24.dp))
            .clickable(role = Role.Switch) { onFollow(!follow) }
            .semantics { stateDescription = if (follow) "On" else "Off" }
            .padding(start = 8.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Follow the text", style = MaterialTheme.typography.labelLarge, color = theme.textColor)
        Switch(
            checked = follow,
            onCheckedChange = null,
            colors = SwitchDefaults.colors(
                checkedTrackColor = theme.accentColor,
                checkedThumbColor = theme.pageColor,
                uncheckedBorderColor = theme.mutedColor,
                uncheckedThumbColor = theme.mutedColor,
                uncheckedTrackColor = Color.Transparent,
            ),
        )
    }
}
