package org.shelfarr.app.ui.settings

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.shelfarr.app.core.Session
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme
import org.shelfarr.app.update.UpdateState
import org.shelfarr.app.update.hasUpdate

@Composable
fun SettingsScreen(
    session: Session,
    appearance: AppearanceMode,
    version: String,
    disconnecting: Boolean,
    onAppearance: (AppearanceMode) -> Unit,
    onDisconnect: () -> Unit,
    downloadsSummary: String = "Nothing downloaded",
    onDownloads: () -> Unit = {},
    update: UpdateState = UpdateState.Disabled,
    updateActions: UpdateActions = UpdateActions.None,
    nowMs: Long = System.currentTimeMillis(),
    autoDownloadUpdates: Boolean = false,
) {
    var confirming by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp),
    ) {
        Text(
            "Settings",
            style = MaterialTheme.typography.headlineLarge,
            modifier = Modifier.padding(top = 12.dp, bottom = 20.dp),
        )

        // Something to act on comes first; otherwise updates sit quietly below.
        if (update.hasUpdate) Section("App update") { UpdateSection(update, nowMs, updateActions, autoDownloadUpdates) }

        Section("Account") {
            Text(session.user.displayName, style = MaterialTheme.typography.titleMedium)
            session.user.username?.let {
                Text("@$it", style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
            }
            Spacer(Modifier.height(6.dp))
            Text(session.server.display, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
        }

        Section("Appearance") {
            AppearanceMode.entries.forEach { mode ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(48.dp)
                        .clickable(role = Role.RadioButton) { onAppearance(mode) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = mode == appearance, onClick = null)
                    Text(
                        when (mode) {
                            AppearanceMode.SYSTEM -> "Match this device"
                            AppearanceMode.LIGHT -> "Light"
                            AppearanceMode.DARK -> "Dark"
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(start = 12.dp),
                    )
                }
            }
        }

        Section("On this device") {
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clickable(role = Role.Button, onClick = onDownloads),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Downloads", style = MaterialTheme.typography.bodyMedium)
                    Text(downloadsSummary, style = MaterialTheme.typography.bodySmall, color = ShelfarrTheme.extended.inkMuted)
                }
                Icon(ShelfarrIcons.ChevronRight, null, tint = ShelfarrTheme.extended.inkMuted)
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "Downloads stay until you remove them, and transfer while Shelfarr is open. " +
                    "Other books open from a temporary copy that Android may clear, and other audio streams from your server. " +
                    "Your reading place is kept here and syncs when you're connected.",
                style = MaterialTheme.typography.bodySmall,
                color = ShelfarrTheme.extended.inkMuted,
            )
        }

        if (update != UpdateState.Disabled && !update.hasUpdate) {
            Section("Updates") { UpdateSection(update, nowMs, updateActions, autoDownloadUpdates) }
        }

        Spacer(Modifier.height(8.dp))
        OutlinedButton(
            onClick = { confirming = true },
            enabled = !disconnecting,
            border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
            modifier = Modifier.fillMaxWidth().height(52.dp),
        ) {
            Text(
                if (disconnecting) "Disconnecting…" else "Disconnect this device",
                color = MaterialTheme.colorScheme.error,
            )
        }
        Spacer(Modifier.height(16.dp))
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Text("Shelfarr $version", style = MaterialTheme.typography.labelSmall, color = ShelfarrTheme.extended.inkMuted)
        }
        Spacer(Modifier.height(24.dp))
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Disconnect this device?") },
            text = {
                Text("This signs out, stops playback and downloads, and removes downloads, book copies and saved places from this device. Your library stays on your server.")
            },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    onDisconnect()
                }) { Text("Disconnect", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Column(Modifier.padding(bottom = 22.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title,
            style = MaterialTheme.typography.labelMedium,
            color = ShelfarrTheme.extended.inkMuted,
            modifier = Modifier.semantics { heading() },
        )
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainer,
            shape = MaterialTheme.shapes.large,
            border = BorderStroke(1.dp, ShelfarrTheme.extended.hairline),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(16.dp)) { content() }
        }
    }
}
