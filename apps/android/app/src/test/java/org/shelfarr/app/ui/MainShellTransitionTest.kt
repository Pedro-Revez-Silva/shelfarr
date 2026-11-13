package org.shelfarr.app.ui

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.navigation.NavType
import androidx.navigation.navArgument
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * Drives the real signed-in shell (tab bar, destination layout and NavHost transitions) through
 * Library → details → system Back → Home, frame by frame. Each destination is a solid
 * colour so the rendered pixels show whether two screens are ever blended together.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class MainShellTransitionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val colours = mapOf(
        HOME to Color(0xFF0000FF),
        LIBRARY to Color(0xFFFF0000),
        DETAILS to Color(0xFF00FF00),
    )

    private fun render() {
        compose.setContent {
            ShelfarrTheme(AppearanceMode.DARK) {
                val navController = androidx.navigation.compose.rememberNavController()
                MainShellLayout(navController, miniPlayer = null) {
                    screen(HOME) { Destination(HOME) }
                    screen(LIBRARY) {
                        Destination(LIBRARY) {
                            var taps by rememberSaveable { mutableIntStateOf(0) }
                            Column {
                                Button(onClick = { navController.navigate("details/one-piece") }) { Text("Open One Piece") }
                                Button(onClick = { taps++ }) { Text("Tapped $taps") }
                            }
                        }
                    }
                    screen(SETTINGS) { Destination(SETTINGS) }
                    screen(DETAILS, listOf(navArgument("id") { type = NavType.StringType })) { Destination(DETAILS) }
                }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun Destination(route: String, content: @androidx.compose.runtime.Composable () -> Unit = {}) {
        Box(Modifier.fillMaxSize().background(colours[route] ?: Color.Gray).testTag(route)) { content() }
    }

    /** One rendered frame: each visible destination's height, and the screen's centre pixel. */
    private data class Frame(val heights: Map<String, Int>, val centre: Int)

    private fun frame(): Frame {
        val heights = colours.keys.mapNotNull { route ->
            compose.onAllNodesWithTag(route).fetchSemanticsNodes().firstOrNull()?.let { route to it.size.height }
        }.toMap()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        return Frame(heights, bitmap.getPixel(bitmap.width / 2, bitmap.height / 2))
    }

    /** Runs [action] with the clock paused and records every frame until the transition settles. */
    private fun transition(action: () -> Unit): List<Frame> {
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        val frames = mutableListOf(frame())
        action()
        repeat(70) {
            compose.mainClock.advanceTimeByFrame()
            frames += frame()
        }
        compose.mainClock.autoAdvance = true
        compose.waitForIdle()
        frames += frame()
        return frames
    }

    /** Channels that stand out from a neutral background; two means two screens are blended. */
    private fun tintedChannels(pixel: Int): Int {
        val channels = listOf((pixel shr 16) and 0xFF, (pixel shr 8) and 0xFF, pixel and 0xFF)
        val floor = channels.min()
        return channels.count { it - floor > 40 }
    }

    private fun assertClean(name: String, frames: List<Frame>) {
        val problems = mutableListOf<String>()
        if (frames.none { it.heights.size == 2 }) problems += "no frame showed the transition in progress"
        frames.forEachIndexed { index, frame ->
            if (tintedChannels(frame.centre) > 1) {
                problems += "frame $index blends two screens (#${Integer.toHexString(frame.centre)})"
            }
        }
        for (route in colours.keys) {
            val heights = frames.mapNotNull { it.heights[route] }.distinct()
            if (heights.size > 1) problems += "$route reflowed while visible, heights $heights"
        }
        assertTrue("$name:\n" + problems.joinToString("\n"), problems.isEmpty())
    }

    @Test
    fun `library to details, system back and Home never blend screens or reflow the outgoing one`() {
        render()
        compose.onNodeWithText("Library").performClick()
        compose.onNodeWithTag(LIBRARY).assertExists()

        assertClean("Library → details", transition { compose.onNodeWithText("Open One Piece").performClick() })
        compose.onNodeWithTag(DETAILS).assertExists()

        assertClean("details → system Back", transition {
            compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        })
        compose.onNodeWithTag(LIBRARY).assertExists()

        assertClean("Library → Home", transition { compose.onNodeWithText("Home").performClick() })
        compose.onNodeWithTag(HOME).assertExists()
        assertEquals(0, compose.onAllNodesWithTag(LIBRARY).fetchSemanticsNodes().size)
    }

    @Test
    fun `a tab keeps its saved state across tab switches`() {
        render()
        compose.onNodeWithText("Library").performClick()
        compose.onNodeWithText("Tapped 0").performClick()
        compose.onNodeWithText("Tapped 1").assertExists()

        compose.onNodeWithText("Home").performClick()
        compose.onNodeWithTag(HOME).assertExists()
        compose.onNodeWithText("Library").performClick()
        compose.onNodeWithText("Tapped 1").assertExists()
    }
}
