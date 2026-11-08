package org.shelfarr.app.ui

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.ui.settings.SettingsScreen
import org.shelfarr.app.ui.settings.UpdateActions
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme
import org.shelfarr.app.update.InstallRequest
import org.shelfarr.app.update.UpdateRelease
import org.shelfarr.app.update.UpdateState

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class UpdateSettingsTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val server = (ServerAddress.parse("https://books.example.org") as ServerAddress.ParseResult.Valid).address
    private val session = Session(server, Me("1", "Ada Reader", "ada"), "fixture")
    private val release = UpdateRelease(
        "development", "org.shelfarr.app.debug", 3, "0.1.2-debug",
        "https://updates.example.org/downloads/shelfarr-3.apk".toHttpUrl(), 41_300_000, "0".repeat(64), null, null,
    )

    /** Answers the way the updater does with audio playing: refuse until told to pause. */
    private class Recorder(var playing: Boolean = true) : UpdateActions {
        val installs = mutableListOf<Boolean>()
        var checks = 0
        override fun check() {
            checks++
        }
        override fun install(pausePlayback: Boolean): InstallRequest {
            installs += pausePlayback
            return if (playing && !pausePlayback) InstallRequest.PLAYBACK_ACTIVE else InstallRequest.STARTED
        }
    }

    private fun render(state: UpdateState, actions: UpdateActions) = compose.setContent {
        ShelfarrTheme(AppearanceMode.LIGHT) {
            SettingsScreen(session, AppearanceMode.SYSTEM, "0.1.1-debug", false, {}, {}, update = state, updateActions = actions)
        }
    }

    @Test
    fun `installing while listening asks before pausing, and Not now leaves audio alone`() {
        val actions = Recorder()
        render(UpdateState.Ready(release), actions)
        compose.onNodeWithText("Install update").performClick()
        compose.onNodeWithText("Pause listening to update?").assertExists()
        compose.onNodeWithText("Not now").performClick()
        compose.onAllNodesWithText("Pause listening to update?").assertCountEquals(0)
        assertEquals(listOf(false), actions.installs)

        compose.onNodeWithText("Install update").performClick()
        compose.onNodeWithText("Pause and install").performClick()
        assertEquals(listOf(false, false, true), actions.installs)
    }

    @Test
    fun `installing with nothing playing goes straight to Android`() {
        val actions = Recorder(playing = false)
        render(UpdateState.Ready(release), actions)
        compose.onNodeWithText("Install update").performClick()
        compose.onAllNodesWithText("Pause listening to update?").assertCountEquals(0)
        assertEquals(listOf(false), actions.installs)
    }

    @Test
    fun `a manual check is offered when up to date`() {
        val actions = Recorder()
        render(UpdateState.Idle(lastCheckedAtMs = System.currentTimeMillis()), actions)
        compose.onNodeWithText("Check for updates").performScrollTo().performClick()
        assertEquals(1, actions.checks)
    }

    @Test
    fun `a check can't be started twice`() {
        render(UpdateState.Idle(checking = true), Recorder())
        compose.onNodeWithText("Checking for updates…").performScrollTo().assertExists()
        compose.onNodeWithText("Check for updates").performScrollTo().assertIsNotEnabled()
    }

    @Test
    fun `a build without a feed shows no update controls`() {
        render(UpdateState.Disabled, Recorder())
        compose.onAllNodesWithText("Check for updates").assertCountEquals(0)
        compose.onAllNodesWithText("Updates").assertCountEquals(0)
    }

    @Test
    fun `the Settings tab carries a quiet badge only while an update is on offer`() {
        fun shell(badged: Boolean) = compose.setContent {
            ShelfarrTheme(AppearanceMode.LIGHT) {
                val navController = androidx.navigation.compose.rememberNavController()
                MainShellLayout(navController, miniPlayer = null, badges = if (badged) setOf(SETTINGS) else emptySet()) {
                    screen(HOME) { Box { Text("Home screen") } }
                    screen(LIBRARY) { Box { Text("Library screen") } }
                    screen(SETTINGS) { Box { Text("Settings screen") } }
                }
            }
        }
        val badge = SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Update available")
        shell(badged = true)
        compose.onAllNodes(badge).assertCountEquals(1)
        // The badge never takes the person anywhere on its own.
        compose.onNodeWithText("Home screen").assertExists()
    }
}
