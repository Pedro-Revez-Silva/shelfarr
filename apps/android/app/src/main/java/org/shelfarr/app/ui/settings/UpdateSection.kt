package org.shelfarr.app.ui.settings

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.shelfarr.app.ui.formatAgo
import org.shelfarr.app.ui.formatBytes
import org.shelfarr.app.ui.theme.ShelfarrTheme
import org.shelfarr.app.update.InstallRequest
import org.shelfarr.app.update.UpdateRelease
import org.shelfarr.app.update.UpdateState

/** What the update section can ask for. */
interface UpdateActions {
    fun check() {}
    fun download() {}
    fun cancelDownload() {}
    fun install(pausePlayback: Boolean): InstallRequest = InstallRequest.IGNORED
    fun openInstallPermission() {}
    fun dismissPermission() {}
    fun showPrompt() {}
    fun cancelInstall() {}
    fun setAutoDownload(enabled: Boolean) {}

    companion object {
        val None = object : UpdateActions {}
    }
}

/**
 * The app's own updates, at the foot of Settings. Quiet when there is nothing to do;
 * nothing here starts an installation unless the person asks, and downloads start on
 * their own only when [autoDownload] is on.
 */
@Composable
internal fun UpdateSection(state: UpdateState, nowMs: Long, actions: UpdateActions, autoDownload: Boolean = false) {
    var askToPause by remember { mutableStateOf(false) }
    fun install(pausePlayback: Boolean) {
        if (actions.install(pausePlayback) == InstallRequest.PLAYBACK_ACTIVE) askToPause = true
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (state) {
            UpdateState.Disabled -> Unit
            is UpdateState.Idle -> {
                val status = when {
                    state.checking -> "Checking for updates…"
                    state.notice != null -> state.notice
                    state.lastCheckedAtMs != null -> "Up to date · checked ${formatAgo(state.lastCheckedAtMs, nowMs)}"
                    else -> "Shelfarr checks your server for updates while you use it."
                }
                Text(status, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
                state.problem?.let { Problem(it) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedAction(
                        if (state.problem != null) "Try again" else "Check for updates",
                        enabled = !state.checking,
                        onClick = actions::check,
                    )
                    if (state.checking) {
                        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.padding(start = 12.dp).size(20.dp))
                    }
                }
            }
            is UpdateState.Available -> {
                Headline("Update available", state.release)
                ReleaseNotes(state.release)
                state.problem?.let { Problem(it) }
                FilledAction(
                    "${if (state.problem != null) "Try again" else "Download"} · ${formatBytes(state.release.sizeBytes)}",
                    onClick = actions::download,
                )
            }
            is UpdateState.Downloading -> {
                Headline("Downloading update", state.release)
                val total = state.release.sizeBytes
                LinearProgressIndicator(
                    progress = { (state.bytesDone.toFloat() / total).coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                    color = MaterialTheme.colorScheme.primary,
                    trackColor = ShelfarrTheme.extended.hairline,
                    strokeCap = StrokeCap.Round,
                    gapSize = 0.dp,
                    drawStopIndicator = {},
                )
                Muted("${formatBytes(state.bytesDone)} of ${formatBytes(total)}")
                OutlinedAction("Cancel", onClick = actions::cancelDownload)
            }
            is UpdateState.Ready -> {
                Headline("Ready to install", state.release)
                state.notice?.let { Problem(it) }
                Muted(
                    "Android will ask you to confirm. Shelfarr closes while it updates; " +
                        "your sign-in, downloads and places stay on this device.",
                )
                FilledAction("Install update", onClick = { install(pausePlayback = false) })
            }
            is UpdateState.NeedsPermission -> {
                Headline("Allow Shelfarr to install updates", state.release)
                Muted(
                    "Android needs your permission, once, before Shelfarr can install its own updates. " +
                        "Turn on \"Allow from this source\", then come back.",
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledAction("Open Android settings", onClick = actions::openInstallPermission)
                    TextButton(onClick = actions::dismissPermission, modifier = Modifier.heightIn(min = 48.dp)) { Text("Not now") }
                }
            }
            is UpdateState.Installing -> {
                Headline("Installing update", state.release)
                Muted(
                    if (state.awaitingConfirmation) {
                        "Confirm the installation in Android's prompt."
                    } else {
                        "Waiting for Android…"
                    },
                )
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (state.canShowPrompt) FilledAction("Show prompt", onClick = actions::showPrompt)
                    OutlinedAction("Cancel", onClick = actions::cancelInstall)
                }
            }
        }
        if (state != UpdateState.Disabled) AutoDownloadRow(autoDownload, actions::setAutoDownload)
    }

    if (askToPause) {
        AlertDialog(
            onDismissRequest = { askToPause = false },
            title = { Text("Pause listening to update?") },
            text = { Text("Installing the update closes Shelfarr. Your listening place is saved before it does.") },
            confirmButton = {
                TextButton(onClick = {
                    askToPause = false
                    install(pausePlayback = true)
                }) { Text("Pause and install") }
            },
            dismissButton = { TextButton(onClick = { askToPause = false }) { Text("Not now") } },
        )
    }
}

/** Opt-in: downloads may start on their own; installing still always waits for the person. */
@Composable
private fun AutoDownloadRow(enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(value = enabled, role = Role.Switch, onValueChange = onChange)
            .padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text("Download updates automatically", style = MaterialTheme.typography.bodyMedium)
            Muted("On Wi-Fi and other unmetered networks. Installing always waits for you.")
        }
        Switch(checked = enabled, onCheckedChange = null)
    }
}

@Composable
private fun Headline(title: String, release: UpdateRelease) {
    Text(title, style = MaterialTheme.typography.titleMedium)
    Text("Version ${release.versionName}", style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
}

@Composable
private fun ReleaseNotes(release: UpdateRelease) {
    val notes = release.releaseNotes ?: return
    var expanded by remember(release) { mutableStateOf(false) }
    var clipped by remember(release) { mutableStateOf(false) }
    Text(
        notes,
        style = MaterialTheme.typography.bodySmall,
        maxLines = if (expanded) Int.MAX_VALUE else 4,
        overflow = TextOverflow.Ellipsis,
        onTextLayout = { if (!expanded) clipped = it.hasVisualOverflow },
    )
    if (!expanded && clipped) {
        TextButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp)) { Text("What's new") }
    }
}

@Composable
private fun Muted(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
}

@Composable
private fun Problem(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
}

@Composable
private fun FilledAction(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.heightIn(min = 48.dp),
    ) { Text(text, style = MaterialTheme.typography.labelLarge) }
}

@Composable
private fun OutlinedAction(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.heightIn(min = 48.dp),
    ) { Text(text, style = MaterialTheme.typography.labelLarge) }
}
