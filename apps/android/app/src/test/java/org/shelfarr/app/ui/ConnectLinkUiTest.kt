package org.shelfarr.app.ui

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.shelfarr.app.core.ConnectDecision
import org.shelfarr.app.core.ConnectLinks
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** The link handling ShelfarrApp uses, with the decision and dialog wired as in the app. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ConnectLinkUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun address(value: String) = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address
    private val here = address("https://books.example.org")
    private val there = address("https://other.example.org")

    private fun host(session: SessionState, request: MutableStateFlow<ServerAddress?>, connects: MutableList<ServerAddress>) {
        compose.setContent {
            var title by remember { mutableStateOf<String?>(null) }
            var message by remember { mutableStateOf<String?>(null) }
            ShelfarrTheme(AppearanceMode.LIGHT) {
                ConnectLinkEffect(
                    request,
                    decide = { ConnectLinks.decide(it, session) },
                    onConnect = { connects += it },
                    onExplain = { decision: ConnectDecision.Explain ->
                        title = decision.title
                        message = decision.message
                    },
                )
                val shownTitle = title
                val shownMessage = message
                if (shownTitle != null && shownMessage != null) ConnectLinkNotice(shownTitle, shownMessage) { title = null; message = null }
            }
        }
    }

    @Test
    fun `signed out, a link connects once and is consumed`() {
        val request = MutableStateFlow<ServerAddress?>(here)
        val connects = mutableListOf<ServerAddress>()
        host(SessionState.SignedOut, request, connects)
        compose.waitForIdle()
        assertEquals(listOf(here), connects)
        assertNull(request.value)
        compose.waitForIdle()
        assertEquals("Not acted on twice", listOf(here), connects)
    }

    @Test
    fun `signed in elsewhere, a link explains without connecting`() {
        val request = MutableStateFlow<ServerAddress?>(null)
        val connects = mutableListOf<ServerAddress>()
        host(SessionState.SignedIn(Session(here, Me("1"), "t")), request, connects)
        request.value = there
        compose.waitForIdle()
        compose.onNodeWithText("Connected to another server").assertExists()
        assertEquals(emptyList<ServerAddress>(), connects)
        compose.onNodeWithText("OK").performClick()
        compose.onAllNodesWithText("Connected to another server").assertCountEquals(0)

        request.value = here
        compose.waitForIdle()
        compose.onAllNodesWithText("Connected to another server").assertCountEquals(0)
        assertNull(request.value)
    }
}
