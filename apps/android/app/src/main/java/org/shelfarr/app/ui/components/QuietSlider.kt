package org.shelfarr.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

/** A thin rule with a small bead: Material's slider behaviour without its bulk. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuietSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    activeColor: Color,
    trackColor: Color,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    valueRange: ClosedFloatingPointRange<Float> = 0f..1f,
    onValueChangeFinished: (() -> Unit)? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
    Slider(
        value = value,
        onValueChange = onValueChange,
        onValueChangeFinished = onValueChangeFinished,
        enabled = enabled,
        valueRange = valueRange,
        interactionSource = interaction,
        modifier = modifier.fillMaxWidth(),
        thumb = { Box(Modifier.size(18.dp).background(activeColor, CircleShape)) },
        track = { state ->
            Canvas(Modifier.fillMaxWidth().height(3.dp)) {
                val span = (state.valueRange.endInclusive - state.valueRange.start).coerceAtLeast(0.0001f)
                val fraction = ((state.value - state.valueRange.start) / span).coerceIn(0f, 1f)
                val y = size.height / 2
                val stop = size.width * if (rtl) 1 - fraction else fraction
                val stroke = size.height
                drawLine(trackColor, Offset(0f, y), Offset(size.width, y), stroke, StrokeCap.Round)
                drawLine(
                    activeColor,
                    Offset(if (rtl) size.width else 0f, y),
                    Offset(stop, y),
                    stroke,
                    StrokeCap.Round,
                )
            }
        },
    )
}
