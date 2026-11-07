package org.shelfarr.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import org.shelfarr.app.ui.LocalServer
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Publication
import org.shelfarr.app.ui.theme.CoverInk
import org.shelfarr.app.ui.theme.CoverSwatches
import org.shelfarr.app.ui.theme.coverSwatchIndex

const val BOOK_ASPECT = 2f / 3f

/** Widens shelf cells with the text-size setting, so titles wrap between words. */
@Composable
fun shelfScale(): Float = LocalDensity.current.fontScale.coerceIn(1f, 1.6f)

/**
 * A publication's jacket. Audiobooks are square and every cover sits on the same
 * baseline, the way things stand on a shelf. A missing or failed cover falls back
 * to a typeset one, so there is never a broken image.
 */
@Composable
fun BookCover(
    publication: Publication,
    modifier: Modifier = Modifier,
    corner: Dp = 4.dp,
    elevation: Dp = 3.dp,
) {
    val ratio = if (publication.bookType == BookType.AUDIOBOOK) 1f else BOOK_ASPECT
    val shape = RoundedCornerShape(corner)
    val server = LocalServer.current
    val imageUrl = remember(publication.coverUrl, server) {
        publication.coverUrl?.let { server?.resolve(it) }?.toString()
    }
    var failed by remember(imageUrl) { mutableStateOf(false) }

    Box(
        modifier = modifier
            .aspectRatio(ratio)
            .shadow(elevation, shape, clip = false, ambientColor = Color(0x33000000), spotColor = Color(0x44000000))
            .clip(shape),
    ) {
        GeneratedCover(publication, Modifier.fillMaxSize())
        if (imageUrl != null && !failed) {
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current).data(imageUrl).build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                onError = { failed = true },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

/** A cover set in type on a muted cloth colour. The colour follows the id, on every client. */
@Composable
fun GeneratedCover(publication: Publication, modifier: Modifier = Modifier) {
    val swatch = CoverSwatches[coverSwatchIndex(publication.id)]
    // A jacket is artwork, so its type follows the jacket, not the text-size setting.
    val density = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale = 1f)) {
        CoverArtwork(publication, swatch, modifier)
    }
}

@Composable
private fun CoverArtwork(publication: Publication, swatch: Color, modifier: Modifier) {
    BoxWithConstraints(modifier.background(swatch)) {
        val width = maxWidth.value
        val unit = maxWidth / 12
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = unit, vertical = unit * 1.1f),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column {
                Box(
                    Modifier
                        .width(unit * 1.6f)
                        .height(1.dp)
                        .background(CoverInk.copy(alpha = 0.7f)),
                )
                Text(
                    text = publication.title,
                    color = CoverInk,
                    style = MaterialTheme.typography.titleLarge.copy(
                        fontSize = (width * 0.125f).coerceIn(10f, 34f).sp,
                        lineHeight = (width * 0.148f).coerceIn(12f, 40f).sp,
                    ),
                    maxLines = 5,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = unit * 0.7f),
                )
            }
            publication.author?.takeIf(String::isNotBlank)?.let { author ->
                Text(
                    text = author,
                    color = CoverInk.copy(alpha = 0.82f),
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontSize = (width * 0.07f).coerceIn(7f, 15f).sp,
                        lineHeight = (width * 0.09f).coerceIn(9f, 19f).sp,
                    ),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Cell for grids and rows: keeps book and audiobook jackets on one baseline. A run
 * of only audiobooks uses [square] cells so the shelf has no empty headroom.
 */
@Composable
fun ShelfCover(publication: Publication, modifier: Modifier = Modifier, square: Boolean = false) {
    val ratio = if (square) 1f else BOOK_ASPECT
    Box(modifier.fillMaxWidth().aspectRatio(ratio), contentAlignment = Alignment.BottomCenter) {
        BookCover(publication, Modifier.fillMaxWidth())
    }
}
