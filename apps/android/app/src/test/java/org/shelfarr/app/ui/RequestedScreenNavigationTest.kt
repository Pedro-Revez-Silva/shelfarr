package org.shelfarr.app.ui

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Real NavHost startup and back navigation, without account or network fixtures. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class)
class RequestedScreenNavigationTest {
    @get:Rule val compose = createComposeRule()
    private val requested = MutableStateFlow<AppScreen?>(null)

    private fun render() {
        compose.setContent {
            MaterialTheme {
                val navController = rememberNavController()
                // Match MainShell: the request precedes NavHost inside Scaffold's
                // deferred content, so its graph isn't installed at first composition.
                RequestedScreenNavigation(navController, requested)
                Scaffold { padding ->
                    NavHost(navController, startDestination = "home", modifier = Modifier.padding(padding)) {
                        composable("home") { Text("Home destination") }
                        composable("downloads") {
                            Column {
                                Text("Downloads destination")
                                Button(onClick = { navController.popBackStack() }) { Text("Back") }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    fun `a cold notification opens Downloads after the graph starts and is consumed once`() {
        requested.value = AppScreen.DOWNLOADS
        render()

        compose.onNodeWithText("Downloads destination").assertExists()
        compose.runOnIdle { assertNull(requested.value) }
        compose.onNodeWithText("Back").performClick()
        compose.onNodeWithText("Home destination").assertExists()
    }

    @Test
    fun `a notification also opens Downloads in an existing app and can be requested again`() {
        render()
        compose.onNodeWithText("Home destination").assertExists()

        repeat(2) {
            compose.runOnIdle { requested.value = AppScreen.DOWNLOADS }
            compose.onNodeWithText("Downloads destination").assertExists()
            compose.runOnIdle { assertNull(requested.value) }
            compose.onNodeWithText("Back").performClick()
            compose.onNodeWithText("Home destination").assertExists()
        }
    }
}
