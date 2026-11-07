package org.shelfarr.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

enum class AppearanceMode { SYSTEM, LIGHT, DARK }

/** Brand colours Material's scheme has no slot for. */
@Immutable
data class ExtendedColors(
    val inkMuted: Color,
    val hairline: Color,
    val sunken: Color,
    val accentSoft: Color,
)

val LocalExtendedColors = staticCompositionLocalOf {
    ExtendedColors(LightTokens.inkMuted, LightTokens.hairline, LightTokens.sunken, LightTokens.accentSoft)
}

private val lightScheme: ColorScheme = lightColorScheme(
    primary = LightTokens.accent,
    onPrimary = LightTokens.onAccent,
    primaryContainer = LightTokens.accentSoft,
    onPrimaryContainer = LightTokens.ink,
    secondary = LightTokens.ink,
    onSecondary = LightTokens.background,
    secondaryContainer = LightTokens.accentSoft,
    onSecondaryContainer = LightTokens.ink,
    tertiary = LightTokens.accent,
    background = LightTokens.background,
    onBackground = LightTokens.ink,
    surface = LightTokens.background,
    onSurface = LightTokens.ink,
    surfaceVariant = LightTokens.sunken,
    onSurfaceVariant = LightTokens.inkMuted,
    surfaceContainerLowest = LightTokens.surface,
    surfaceContainerLow = LightTokens.surface,
    surfaceContainer = LightTokens.surface,
    surfaceContainerHigh = LightTokens.surface,
    surfaceContainerHighest = LightTokens.sunken,
    outline = LightTokens.inkMuted,
    outlineVariant = LightTokens.hairline,
    error = LightTokens.danger,
    onError = LightTokens.onAccent,
)

private val darkScheme: ColorScheme = darkColorScheme(
    primary = DarkTokens.accent,
    onPrimary = DarkTokens.onAccent,
    primaryContainer = DarkTokens.accentSoft,
    onPrimaryContainer = DarkTokens.ink,
    secondary = DarkTokens.ink,
    onSecondary = DarkTokens.background,
    secondaryContainer = DarkTokens.accentSoft,
    onSecondaryContainer = DarkTokens.ink,
    tertiary = DarkTokens.accent,
    background = DarkTokens.background,
    onBackground = DarkTokens.ink,
    surface = DarkTokens.background,
    onSurface = DarkTokens.ink,
    surfaceVariant = DarkTokens.sunken,
    onSurfaceVariant = DarkTokens.inkMuted,
    surfaceContainerLowest = DarkTokens.sunken,
    surfaceContainerLow = DarkTokens.surface,
    surfaceContainer = DarkTokens.surface,
    surfaceContainerHigh = DarkTokens.surface,
    surfaceContainerHighest = DarkTokens.hairline,
    outline = DarkTokens.inkMuted,
    outlineVariant = DarkTokens.hairline,
    error = DarkTokens.danger,
    onError = DarkTokens.onAccent,
)

private val shapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(18.dp),
    extraLarge = RoundedCornerShape(24.dp),
)

@Composable
private fun rememberTypography(): Typography {
    val assets = LocalContext.current.assets
    return remember(assets) {
        val display = FontFamily(Font("fonts/NewsreaderDisplay-Medium.ttf", assets, FontWeight.Medium))
        val serif = FontFamily(
            Font("fonts/Newsreader-Regular.ttf", assets, FontWeight.Normal),
            Font("fonts/Newsreader-Italic.ttf", assets, FontWeight.Normal, FontStyle.Italic),
            Font("fonts/Newsreader-SemiBold.ttf", assets, FontWeight.SemiBold),
        )
        val sans = FontFamily.Default
        fun heading(size: Int, line: Int, tracking: Double = -0.2) = TextStyle(
            fontFamily = display,
            fontWeight = FontWeight.Medium,
            fontSize = size.sp,
            lineHeight = line.sp,
            letterSpacing = tracking.sp,
        )
        fun label(size: Int, line: Int, weight: FontWeight = FontWeight.Medium, tracking: Double = 0.1) = TextStyle(
            fontFamily = sans,
            fontWeight = weight,
            fontSize = size.sp,
            lineHeight = line.sp,
            letterSpacing = tracking.sp,
        )
        Typography(
            displayLarge = heading(44, 50, -0.6),
            displayMedium = heading(38, 44, -0.5),
            displaySmall = heading(32, 38, -0.4),
            headlineLarge = heading(30, 36, -0.3),
            headlineMedium = heading(26, 32),
            headlineSmall = heading(22, 28),
            titleLarge = heading(20, 26, -0.1),
            titleMedium = TextStyle(fontFamily = serif, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, lineHeight = 22.sp),
            titleSmall = TextStyle(fontFamily = serif, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, lineHeight = 19.sp),
            bodyLarge = TextStyle(fontFamily = serif, fontSize = 18.sp, lineHeight = 27.sp),
            bodyMedium = label(15, 22, FontWeight.Normal),
            bodySmall = label(13, 18, FontWeight.Normal),
            labelLarge = label(15, 20, FontWeight.Medium),
            labelMedium = label(13, 16, FontWeight.Medium),
            labelSmall = label(11, 14, FontWeight.Medium, 0.6),
        )
    }
}

@Composable
fun ShelfarrTheme(
    appearance: AppearanceMode = AppearanceMode.SYSTEM,
    content: @Composable () -> Unit,
) {
    val dark = when (appearance) {
        AppearanceMode.SYSTEM -> isSystemInDarkTheme()
        AppearanceMode.LIGHT -> false
        AppearanceMode.DARK -> true
    }
    val extended = if (dark) {
        ExtendedColors(DarkTokens.inkMuted, DarkTokens.hairline, DarkTokens.sunken, DarkTokens.accentSoft)
    } else {
        ExtendedColors(LightTokens.inkMuted, LightTokens.hairline, LightTokens.sunken, LightTokens.accentSoft)
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalExtendedColors provides extended) {
        MaterialTheme(
            colorScheme = if (dark) darkScheme else lightScheme,
            typography = rememberTypography(),
            shapes = shapes,
            content = content,
        )
    }
}

object ShelfarrTheme {
    val extended: ExtendedColors
        @Composable get() = LocalExtendedColors.current
}
