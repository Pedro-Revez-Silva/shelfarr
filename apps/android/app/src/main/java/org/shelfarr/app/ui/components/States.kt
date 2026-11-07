package org.shelfarr.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** A quiet centred message for empty and failed screens. */
@Composable
fun MessageState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    action: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Box(modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.widthIn(max = 360.dp),
        ) {
            icon?.let {
                Icon(it, null, tint = ShelfarrTheme.extended.inkMuted, modifier = Modifier.size(28.dp))
            }
            Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                color = ShelfarrTheme.extended.inkMuted,
                textAlign = TextAlign.Center,
            )
            if (action != null && onAction != null) {
                OutlinedButton(onClick = onAction, modifier = Modifier.padding(top = 10.dp)) { Text(action) }
            }
        }
    }
}

@Composable
fun LoadingState(modifier: Modifier = Modifier, label: String = "Loading") {
    Box(
        modifier
            .fillMaxSize()
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
    }
}

@Composable
fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    icon: ImageVector? = null,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier.height(52.dp),
        shape = MaterialTheme.shapes.medium,
        colors = ButtonDefaults.buttonColors(),
    ) {
        icon?.let {
            Icon(it, null, modifier = Modifier.size(20.dp).padding(end = 2.dp))
            Box(Modifier.size(8.dp))
        }
        Text(text, style = MaterialTheme.typography.labelLarge)
    }
}

/** Reading progress as a thin rule, the only "data" a cover ever carries. */
@Composable
fun ProgressRule(fraction: Float, modifier: Modifier = Modifier) {
    LinearProgressIndicator(
        progress = { fraction.coerceIn(0f, 1f) },
        modifier = modifier.fillMaxWidth().height(3.dp),
        color = MaterialTheme.colorScheme.primary,
        trackColor = ShelfarrTheme.extended.hairline,
        strokeCap = StrokeCap.Round,
        gapSize = 0.dp,
        drawStopIndicator = {},
    )
}

@Composable
fun SkeletonBlock(modifier: Modifier = Modifier) {
    Box(modifier.background(ShelfarrTheme.extended.sunken, RoundedCornerShape(4.dp)))
}

data class ErrorCopy(val title: String, val message: String, val retryable: Boolean = true)

/** Plain-language wording for every failure a screen can show. */
fun errorCopy(error: Throwable, host: String?): ErrorCopy {
    val server = host ?: "your server"
    return when (error) {
        is ApiException.Offline -> {
            if (error.certificate) {
                ErrorCopy("Can't verify this server", "The security certificate for $server couldn't be trusted.")
            } else {
                ErrorCopy("Can't reach $server", "Check your connection, or whether the server is up, and try again.")
            }
        }
        is ApiException.Server -> ErrorCopy("$server had a problem", "It answered with error ${error.status}. Try again in a moment.")
        is ApiException.NotFound -> ErrorCopy("Not available", "This isn't on $server any more.", retryable = false)
        is ApiException.Forbidden -> ErrorCopy("Not allowed", "This account doesn't have access to that.", retryable = false)
        is ApiException.Unauthorized -> ErrorCopy("Signed out", "Your sign-in has ended.", retryable = false)
        is ApiException.RedirectBlocked -> ErrorCopy(
            "Server moved",
            "$server redirects to ${error.location}. For your security Shelfarr won't follow that. Use the new address instead.",
            retryable = false,
        )
        is ApiException.Protocol -> ErrorCopy("Unexpected response", "$server sent something Shelfarr couldn't read.")
        else -> ErrorCopy("Something went wrong", "Please try again.")
    }
}
