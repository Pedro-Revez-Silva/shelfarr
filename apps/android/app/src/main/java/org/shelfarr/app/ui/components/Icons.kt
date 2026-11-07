package org.shelfarr.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/** The app's drawn icon set: 24dp, 1.6dp rounded strokes, so everything feels hand-set. */
object ShelfarrIcons {
    private fun stroke(name: String, vararg paths: String): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            paths.forEach { data ->
                addPath(
                    pathData = addPathNodes(data),
                    stroke = SolidColor(Color.Black),
                    strokeLineWidth = 1.6f,
                    strokeLineCap = StrokeCap.Round,
                    strokeLineJoin = StrokeJoin.Round,
                )
            }
        }.build()

    private fun fill(name: String, vararg paths: String): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            paths.forEach { data -> addPath(pathData = addPathNodes(data), fill = SolidColor(Color.Black)) }
        }.build()

    val Home by lazy {
        stroke(
            "home",
            "M12 6.5C10 5 7.2 4.4 4.6 4.7c-.4 0-.6.3-.6.7v12c0 .4.3.7.7.7 2.6-.2 5.3.4 7.3 1.9 2-1.5 4.7-2.1 7.3-1.9.4 0 .7-.3.7-.7v-12c0-.4-.2-.7-.6-.7C16.8 4.4 14 5 12 6.5Z",
            "M12 6.5V20",
        )
    }
    val Library by lazy {
        stroke(
            "library",
            "M5 4.5h3.2a.8.8 0 0 1 .8.8v13.4a.8.8 0 0 1-.8.8H5a.8.8 0 0 1-.8-.8V5.3a.8.8 0 0 1 .8-.8Z",
            "M12 4.5h3a.8.8 0 0 1 .8.8v13.4a.8.8 0 0 1-.8.8h-3a.8.8 0 0 1-.8-.8V5.3a.8.8 0 0 1 .8-.8Z",
            "M18.3 5.2l2.6.6a.8.8 0 0 1 .6 1l-2.9 12.4a.8.8 0 0 1-1 .6",
            "M4.2 8.5H9M11.2 8.5h4.6",
        )
    }
    val Settings by lazy {
        stroke(
            "settings",
            "M4 7h9M17 7h3M4 17h3M11 17h9",
            "M15 9.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4Z",
            "M9 19.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4Z",
        )
    }
    val Search by lazy { stroke("search", "M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14Z", "M20 20l-4-4") }
    val Back by lazy { stroke("back", "M15 5l-7 7 7 7") }
    val Close by lazy { stroke("close", "M6 6l12 12M18 6L6 18") }
    val Check by lazy { stroke("check", "M5 12.5l4.5 4.5L19 7") }
    val ChevronRight by lazy { stroke("chevronRight", "M9 5l7 7-7 7") }
    val Contents by lazy { stroke("contents", "M9 6.5h11M9 12h11M9 17.5h7", "M4.5 6.5h.01M4.5 12h.01M4.5 17.5h.01") }
    val Copy by lazy {
        stroke(
            "copy",
            "M9 9h9.2a.8.8 0 0 1 .8.8V19.2a.8.8 0 0 1-.8.8H9.8a.8.8 0 0 1-.8-.8V9Z",
            "M5.8 15H5.6a.8.8 0 0 1-.8-.8V4.8a.8.8 0 0 1 .8-.8H15a.8.8 0 0 1 .8.8v.2",
        )
    }
    val External by lazy { stroke("external", "M14 5h5v5M19 5l-8 8", "M17 14v4.2a.8.8 0 0 1-.8.8H5.8a.8.8 0 0 1-.8-.8V7.8a.8.8 0 0 1 .8-.8H10") }
    val Headphones by lazy {
        stroke(
            "headphones",
            "M4 15v-3a8 8 0 0 1 16 0v3",
            "M4 15.5a1.5 1.5 0 0 1 1.5-1.5H7a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1H5.5A1.5 1.5 0 0 1 4 18.5v-3Z",
            "M20 15.5a1.5 1.5 0 0 0-1.5-1.5H17a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h1.5a1.5 1.5 0 0 0 1.5-1.5v-3Z",
        )
    }
    val Moon by lazy { stroke("moon", "M19.5 14.2A7.8 7.8 0 0 1 9.8 4.5a7.8 7.8 0 1 0 9.7 9.7Z") }
    val Offline by lazy {
        stroke(
            "offline",
            "M3 4l18 16",
            "M8.5 16.2a5 5 0 0 1 5.6-.8M5.2 12.6a10 10 0 0 1 4-2.4M12.8 9.1a10 10 0 0 1 6 3.5",
            "M2 9a15 15 0 0 1 3.8-2.6M10.6 5.1A15 15 0 0 1 22 9",
            "M12 19.5h.01",
        )
    }
    val Alert by lazy { stroke("alert", "M12 8v5", "M12 16.5h.01", "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z") }
    val Play by lazy { fill("play", "M7.5 4.6c0-.9 1-1.5 1.8-1l11 6.9c.7.5.7 1.5 0 2l-11 6.9c-.8.5-1.8-.1-1.8-1V4.6Z") }
    val Pause by lazy {
        fill(
            "pause",
            "M6.5 4h3c.6 0 1 .4 1 1v14c0 .6-.4 1-1 1h-3c-.6 0-1-.4-1-1V5c0-.6.4-1 1-1Z",
            "M14.5 4h3c.6 0 1 .4 1 1v14c0 .6-.4 1-1 1h-3c-.6 0-1-.4-1-1V5c0-.6.4-1 1-1Z",
        )
    }
    val SkipBack by lazy { stroke("skipBack", "M9 3.5L5.5 7 9 10.5", "M5.5 7H13a7 7 0 1 1-7 7") }
    val SkipForward by lazy { stroke("skipForward", "M15 3.5L18.5 7 15 10.5", "M18.5 7H11a7 7 0 1 0 7 7") }
    val PreviousTrack by lazy { stroke("previousTrack", "M6 5v14", "M19 5.5v13L9 12l10-6.5Z") }
    val NextTrack by lazy { stroke("nextTrack", "M18 5v14", "M5 5.5v13L15 12 5 5.5Z") }
    val Download by lazy { stroke("download", "M12 4v11", "M7.5 10.5L12 15l4.5-4.5", "M5 19.5h14") }
    val Downloaded by lazy { stroke("downloaded", "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M8 12.5l2.8 2.8L16.2 9.6") }
    val Sort by lazy { stroke("sort", "M7 5v14M4 16l3 3 3-3", "M13 7h7M13 12h5M13 17h3") }
}
