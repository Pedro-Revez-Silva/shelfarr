package org.shelfarr.app.ui

import android.app.Application
import android.graphics.Bitmap
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Publication
import org.shelfarr.app.ui.details.DetailsScreen
import org.shelfarr.app.ui.details.DetailsState
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * Home → the real details screen → Back, through the production shell, frame by frame.
 *
 * Home is a list of rows in a marker green that nothing in the theme or details screen uses.
 * The details screen is the real one, whose button, cover and spinner are drawn in the
 * accent and cover colours. A frame that holds both the green and those colours shows
 * one screen drawn over the other, which is what a person saw when Back was held: the
 * book's cover, title and button floating over Home's shelves.
 *
 * Back is driven both ways Android sends it: as a predictive gesture (started, progressed,
 * then committed or cancelled — what a held Back button or an edge swipe sends on recent
 * Android versions) and as a plain press.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class DetailsBackTransitionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val book = Publication(
        id = "fixture-volume-one",
        title = "A Synthetic Volume",
        author = "Fixture Author",
        bookType = BookType.EBOOK,
        assets = listOf(Asset("fixture-epub", format = "epub", contentUrl = "/fixture.epub")),
    )

    private var details by mutableStateOf<DetailsState>(DetailsState.Loaded(book))
    private var miniPlayerDisposals = 0
    private lateinit var navController: NavHostController

    private fun render(appearance: AppearanceMode) {
        compose.setContent {
            ShelfarrTheme(appearance) {
                navController = rememberNavController()
                MainShellLayout(navController, miniPlayer = { MiniPlayerStandIn() }) {
                    screen(HOME) { Home() }
                    screen(LIBRARY) { }
                    screen(DETAILS, listOf(navArgument("id") { type = NavType.StringType })) {
                        DetailsScreen(
                            state = details,
                            host = null,
                            onBack = navController::popBackStack,
                            onPrimary = {},
                            onRetry = {},
                        )
                    }
                }
            }
        }
    }

    @Composable
    private fun Home() {
        val list = rememberLazyListState()
        LazyColumn(
            Modifier.fillMaxSize().testTag(HOME_LIST),
            state = list,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(40) { row ->
                Box(Modifier.fillMaxWidth().height(120.dp).padding(horizontal = 16.dp).background(HomeMarker)) {
                    Text("Home row $row", Modifier.padding(8.dp))
                }
            }
        }
    }

    @Composable
    private fun MiniPlayerStandIn() {
        DisposableEffect(Unit) { onDispose { miniPlayerDisposals++ } }
        Box(Modifier.fillMaxWidth().height(64.dp).testTag(MINI_PLAYER))
    }

    // ---- Frames ----

    private data class Frame(val label: String, val home: Int, val details: Int, val bitmap: Bitmap)

    private fun frame(label: String): Frame {
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        // Above the tab bar and mini player, whose selected tab is drawn in the accent.
        val height = (bitmap.height * CONTENT_FRACTION).toInt()
        val pixels = IntArray(bitmap.width * height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, height)
        var home = 0
        var details = 0
        for (pixel in pixels) {
            val r = (pixel shr 16) and 0xFF
            val g = (pixel shr 8) and 0xFF
            val b = pixel and 0xFF
            if (g - r > 60 && g - b > 40) home++
            if (r - b > 60 && r - g > 30) details++
        }
        return Frame(label, home, details, bitmap)
    }

    private fun advance(frames: MutableList<Frame>, label: String, count: Int) {
        repeat(count) {
            compose.mainClock.advanceTimeByFrame()
            frames += frame("$label+${it + 1}")
        }
    }

    /** Pauses the clock, runs [steps] and records every frame until the shell settles. */
    private fun record(steps: (MutableList<Frame>) -> Unit): List<Frame> {
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        val frames = mutableListOf(frame("start"))
        steps(frames)
        advance(frames, "settle", 40)
        compose.mainClock.autoAdvance = true
        compose.waitForIdle()
        frames += frame("idle")
        return frames
    }

    private fun onUi(block: ComponentActivity.() -> Unit) = compose.runOnUiThread { compose.activity.block() }

    private fun gesture(progress: Float) = BackEventCompat(touchX = 8f, touchY = 1200f, progress = progress, swipeEdge = BackEventCompat.EDGE_LEFT)

    /** A held Back: started, dragged through [progress], then released ([commit]) or abandoned. */
    private fun predictiveBack(frames: MutableList<Frame>, commit: Boolean, progress: List<Float> = PROGRESS) {
        onUi { onBackPressedDispatcher.dispatchOnBackStarted(gesture(0f)) }
        advance(frames, "started", 2)
        for (p in progress) {
            onUi { onBackPressedDispatcher.dispatchOnBackProgressed(gesture(p)) }
            advance(frames, "progress $p", 2)
        }
        onUi { if (commit) onBackPressedDispatcher.onBackPressed() else onBackPressedDispatcher.dispatchOnBackCancelled() }
    }

    private fun openDetails() {
        compose.runOnUiThread { navController.navigate("details/${book.id}") }
    }

    private fun save(name: String, frames: List<Frame>) {
        val dir = System.getenv("SHELFARR_TRANSITION_FRAMES")?.let { File(it, name) } ?: return
        dir.mkdirs()
        frames.forEachIndexed { index, frame ->
            val safe = frame.label.replace(Regex("[^A-Za-z0-9.+-]"), "_")
            File(dir, "%03d-%s-h%d-d%d.png".format(index, safe, frame.home, frame.details)).outputStream().use {
                frame.bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
    }

    /** No frame may show Home's shelves and the details screen at once. */
    private fun assertNeverOverlaid(name: String, frames: List<Frame>) {
        save(name, frames)
        val overlaid = frames.withIndex().filter { (_, f) -> f.home > VISIBLE && f.details > VISIBLE }
        val summary = frames.joinToString(" ") { "${it.label}:h${it.home}/d${it.details}" }
        assertTrue(
            "$name: details drawn over Home in ${overlaid.size} frame(s): " +
                overlaid.joinToString { (i, f) -> "#$i ${f.label} home=${f.home} details=${f.details}" } +
                "\nall frames: $summary",
            overlaid.isEmpty(),
        )
        assertTrue("$name: the details screen never showed\n$summary", frames.any { it.details > VISIBLE })
        assertTrue("$name: Home never showed\n$summary", frames.any { it.home > VISIBLE })
    }

    private fun assertBackOnHome(scrolledTo: Int) {
        compose.onNodeWithTag(HOME_LIST).assertExists()
        assertEquals(0, compose.onAllNodesWithText(book.title).fetchSemanticsNodes().size)
        compose.onNodeWithText("Home row $scrolledTo").assertIsDisplayed()
        assertEquals(0, compose.onAllNodesWithText("Home row 0").fetchSemanticsNodes().size)
        compose.onNodeWithText("Home").assertIsDisplayed() // the tab bar is back
        compose.onNodeWithTag(MINI_PLAYER).assertIsDisplayed()
        assertEquals("the mini player must stay composed through navigation", 0, miniPlayerDisposals)
    }

    private fun scrolledHome(appearance: AppearanceMode): Int {
        render(appearance)
        compose.onNodeWithTag(HOME_LIST).performScrollToIndex(SCROLLED)
        compose.onNodeWithText("Home row $SCROLLED").assertIsDisplayed()
        return SCROLLED
    }

    /** The title is both the heading and the generated cover's type. */
    private fun onDetails() {
        assertTrue(compose.onAllNodesWithText(book.title).fetchSemanticsNodes().isNotEmpty())
        compose.onNodeWithContentDescription("Back").assertIsDisplayed()
    }

    // ---- Cases ----

    private fun heldBackFromLoadedDetails(appearance: AppearanceMode) {
        val row = scrolledHome(appearance)
        val frames = record { frames ->
            openDetails()
            advance(frames, "open", 40)
            predictiveBack(frames, commit = true)
        }
        assertNeverOverlaid("held-back-loaded-${appearance.name.lowercase()}", frames)
        assertBackOnHome(row)
    }

    @Test
    fun `held Back from loaded details never draws the book over Home in the dark theme`() =
        heldBackFromLoadedDetails(AppearanceMode.DARK)

    @Test
    fun `held Back from loaded details never draws the book over Home in the light theme`() =
        heldBackFromLoadedDetails(AppearanceMode.LIGHT)

    @Test
    fun `a cancelled held Back stays on details without drawing it over Home`() {
        scrolledHome(AppearanceMode.DARK)
        val frames = record { frames ->
            openDetails()
            advance(frames, "open", 40)
            predictiveBack(frames, commit = false)
        }
        assertNeverOverlaid("held-back-cancelled", frames)
        onDetails()
        compose.onNodeWithText("Home").assertDoesNotExist()

        // And it still goes back afterwards.
        compose.onNodeWithContentDescription("Back").performClick()
        assertBackOnHome(SCROLLED)
    }

    @Test
    fun `held Back while details is still loading, then loaded mid-gesture, never overlays Home`() {
        details = DetailsState.Loading
        val row = scrolledHome(AppearanceMode.DARK)
        val frames = record { frames ->
            openDetails()
            // Back while details is still fading in.
            advance(frames, "open", 12)
            onUi { onBackPressedDispatcher.dispatchOnBackStarted(gesture(0f)) }
            advance(frames, "started", 2)
            for (p in PROGRESS) {
                if (p >= 0.25f) details = DetailsState.Loaded(book)
                onUi { onBackPressedDispatcher.dispatchOnBackProgressed(gesture(p)) }
                advance(frames, "progress $p", 2)
            }
            onUi { onBackPressedDispatcher.onBackPressed() }
        }
        assertNeverOverlaid("held-back-loading", frames)
        assertBackOnHome(row)
    }

    @Test
    fun `a plain Back press, a quick one and the app's Back button never overlay Home`() {
        val row = scrolledHome(AppearanceMode.DARK)

        val plain = record { frames ->
            openDetails()
            advance(frames, "open", 40)
            onUi { onBackPressedDispatcher.onBackPressed() }
        }
        assertNeverOverlaid("plain-back", plain)
        assertBackOnHome(row)

        val quick = record { frames ->
            openDetails()
            advance(frames, "open", 4)
            onUi { onBackPressedDispatcher.onBackPressed() }
        }
        save("quick-back", quick)
        assertTrue(
            "quick-back: details drawn over Home",
            quick.none { it.home > VISIBLE && it.details > VISIBLE },
        )
        assertBackOnHome(row)

        compose.runOnUiThread { navController.navigate("details/${book.id}") }
        onDetails()
        val app = record { frames ->
            compose.onNodeWithContentDescription("Back").performClick()
            advance(frames, "tap", 2)
        }
        assertNeverOverlaid("app-back-button", app)
        assertBackOnHome(row)
    }

    /**
     * Every shell destination paints the screen's background, so even a transition that
     * draws two destinations at once cannot show one through the gaps of the other.
     */
    @Test
    fun `a shell destination is opaque over whatever is beneath it`() {
        compose.setContent {
            ShelfarrTheme(AppearanceMode.DARK) {
                Box(Modifier.fillMaxSize().background(HomeMarker)) {
                    NavHost(rememberNavController(), startDestination = "opaque") {
                        screen("opaque") { DetailsScreen(DetailsState.Loaded(book), null, {}, {}, {}) }
                    }
                }
            }
        }
        onDetails()
        val frame = frame("details")
        save("opaque-destination", listOf(frame))
        assertTrue("details is drawn", frame.details > VISIBLE)
        assertEquals("pixels of what lies beneath showing through details", 0, frame.home)
    }

    private companion object {
        const val HOME_LIST = "home-list"
        const val MINI_PLAYER = "mini-player"
        const val SCROLLED = 12
        const val VISIBLE = 40
        const val CONTENT_FRACTION = 0.8f
        val HomeMarker = Color(0xFF00B050)
        val PROGRESS = listOf(0.1f, 0.25f, 0.4f, 0.55f, 0.7f, 0.85f)
    }
}
