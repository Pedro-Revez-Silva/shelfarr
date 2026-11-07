package org.shelfarr.app.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Mirror of `apps/design/tokens.json`. `apps/scripts/check-design-tokens.py`
 * fails the build when these values drift from that file.
 */
object LightTokens {
    val background = Color(0xFFFBF7F0)
    val surface = Color(0xFFFFFDF9)
    val sunken = Color(0xFFF3ECE0)
    val ink = Color(0xFF211C16)
    val inkMuted = Color(0xFF665B4E)
    val hairline = Color(0xFFE6DCCB)
    val accent = Color(0xFFA33A22)
    val onAccent = Color(0xFFFFF9F2)
    val accentSoft = Color(0xFFF6E3D8)
    val danger = Color(0xFF9B1C1C)
}

object DarkTokens {
    val background = Color(0xFF16130F)
    val surface = Color(0xFF211C17)
    val sunken = Color(0xFF0F0D0A)
    val ink = Color(0xFFF2EADD)
    val inkMuted = Color(0xFFB3A797)
    val hairline = Color(0xFF38302A)
    val accent = Color(0xFFEE9270)
    val onAccent = Color(0xFF2B1208)
    val accentSoft = Color(0xFF3D261C)
    val danger = Color(0xFFF2A3A3)
}

/** Backgrounds for generated covers, chosen by [coverSwatchIndex]. */
val CoverSwatches = listOf(
    Color(0xFF6E2A20),
    Color(0xFF3F4A30),
    Color(0xFF26384A),
    Color(0xFF7A5518),
    Color(0xFF4E2F44),
    Color(0xFF3F4649),
)

val CoverInk = Color(0xFFF7EFE2)

/** FNV-1a over UTF-8, so a book gets the same generated cover on every client. */
fun coverSwatchIndex(id: String): Int {
    var hash = 0x811C9DC5.toInt()
    for (byte in id.encodeToByteArray()) {
        hash = hash xor (byte.toInt() and 0xFF)
        hash *= 0x01000193
    }
    return ((hash.toLong() and 0xFFFFFFFFL) % CoverSwatches.size).toInt()
}
