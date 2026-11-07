package org.shelfarr.app.ui.setup

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.shelfarr.app.ui.components.PrimaryButton
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.formatDuration
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** Centres a narrow column on tablets, and fills the width on phones. */
@Composable
private fun SetupFrame(content: @Composable () -> Unit) {
    Surface(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .imePadding()
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.TopCenter,
        ) {
            Column(
                Modifier
                    .widthIn(max = 440.dp)
                    .fillMaxWidth()
                    .padding(horizontal = 28.dp, vertical = 24.dp),
            ) { content() }
        }
    }
}

@Composable
fun ServerSetupScreen(
    state: SetupState,
    canUseLocalHttp: Boolean,
    onAddressChange: (String) -> Unit,
    onAllowLocalHttpChange: (Boolean) -> Unit,
    onConnect: () -> Unit,
) {
    val connecting = state.phase is SetupPhase.Connecting
    SetupFrame {
        Spacer(Modifier.height(72.dp))
        Text(
            "Shelfarr",
            style = MaterialTheme.typography.displayLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.height(12.dp))
        Text(
            if (state.expiredFor != null) {
                "Your sign-in has ended, ${state.expiredFor}. Connect again to carry on where you left off."
            } else {
                "Your library, to read and to listen to."
            },
            style = MaterialTheme.typography.bodyLarge,
            color = ShelfarrTheme.extended.inkMuted,
        )
        Spacer(Modifier.height(48.dp))

        OutlinedTextField(
            value = state.address,
            onValueChange = onAddressChange,
            label = { Text("Server address") },
            placeholder = { Text("books.example.org") },
            singleLine = true,
            isError = state.errorMessage != null,
            enabled = !connecting,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Go,
            ),
            keyboardActions = KeyboardActions(onGo = { onConnect() }),
            colors = OutlinedTextFieldDefaults.colors(unfocusedBorderColor = ShelfarrTheme.extended.hairline),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            state.errorMessage ?: "The address you use to open Shelfarr in a browser.",
            style = MaterialTheme.typography.bodySmall,
            color = if (state.errorMessage != null) MaterialTheme.colorScheme.error else ShelfarrTheme.extended.inkMuted,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )

        if (canUseLocalHttp) {
            Spacer(Modifier.height(16.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Switch) { onAllowLocalHttpChange(!state.allowLocalHttp) }
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Allow local HTTP", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "Development builds only. Unencrypted, for hosts on your own network.",
                        style = MaterialTheme.typography.bodySmall,
                        color = ShelfarrTheme.extended.inkMuted,
                    )
                }
                Switch(checked = state.allowLocalHttp, onCheckedChange = null)
            }
        }

        Spacer(Modifier.height(24.dp))
        PrimaryButton(
            text = if (connecting) "Connecting…" else "Continue",
            onClick = onConnect,
            enabled = !connecting,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
fun AuthorizeScreen(
    phase: SetupPhase.Authorizing,
    onOpenBrowser: () -> Unit,
    onCancel: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    SetupFrame {
        Spacer(Modifier.height(56.dp))
        Text(
            "Approve this device",
            style = MaterialTheme.typography.displaySmall,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "Sign in to ${phase.server.host} in your browser and confirm the code below.",
            style = MaterialTheme.typography.bodyLarge,
            color = ShelfarrTheme.extended.inkMuted,
        )
        Spacer(Modifier.height(36.dp))

        Surface(
            color = ShelfarrTheme.extended.sunken,
            contentColor = MaterialTheme.colorScheme.onBackground,
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                Modifier.padding(start = 20.dp, end = 8.dp, top = 18.dp, bottom = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    phase.userCode,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 26.sp,
                    letterSpacing = 2.sp,
                    modifier = Modifier
                        .weight(1f)
                        .semantics { contentDescription = "Confirmation code ${phase.userCode.toList().joinToString(" ")}" },
                )
                IconButton(onClick = { clipboard.setText(AnnotatedString(phase.userCode)) }) {
                    Icon(ShelfarrIcons.Copy, "Copy code")
                }
            }
        }

        Spacer(Modifier.height(20.dp))
        PrimaryButton(
            text = "Open browser",
            icon = ShelfarrIcons.External,
            onClick = onOpenBrowser,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(20.dp))

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Text(
                "Waiting for approval · code expires in ${formatDuration(phase.secondsLeft * 1_000)}",
                style = MaterialTheme.typography.bodySmall,
                color = ShelfarrTheme.extended.inkMuted,
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "On another device? Go to ${phase.verificationUri}",
            style = MaterialTheme.typography.bodySmall,
            color = ShelfarrTheme.extended.inkMuted,
        )
        Spacer(Modifier.height(20.dp))
        TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
    }
}

@Composable
fun AuthorizationEndedScreen(phase: SetupPhase.Ended, onRetry: () -> Unit, onChangeServer: () -> Unit) {
    SetupFrame {
        Spacer(Modifier.height(72.dp))
        Text(
            if (phase.denied) "Approval was declined" else "That code expired",
            style = MaterialTheme.typography.displaySmall,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(Modifier.height(12.dp))
        Text(
            if (phase.denied) {
                "${phase.server.host} didn't approve this device. Nothing was connected."
            } else {
                "Codes last a few minutes. Get a new one to try again."
            },
            style = MaterialTheme.typography.bodyLarge,
            color = ShelfarrTheme.extended.inkMuted,
            textAlign = TextAlign.Start,
        )
        Spacer(Modifier.height(32.dp))
        PrimaryButton("Get a new code", onRetry, Modifier.fillMaxWidth())
        Spacer(Modifier.height(10.dp))
        OutlinedButton(onClick = onChangeServer, modifier = Modifier.fillMaxWidth().height(52.dp)) {
            Text("Use a different server")
        }
    }
}
