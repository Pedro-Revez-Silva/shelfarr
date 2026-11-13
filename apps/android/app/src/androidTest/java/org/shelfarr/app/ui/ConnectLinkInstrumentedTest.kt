package org.shelfarr.app.ui

import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.SemanticsNodeInteractionCollection
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ConnectLink
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.ui.theme.AppearanceMode

/**
 * Opens the real MainActivity from `shelfarr://connect` links, cold and warm, the way
 * a browser's "Open Shelfarr" button does. Fixture servers use reserved `.invalid`
 * names, so nothing is reachable and no real account is involved.
 */
@RunWith(AndroidJUnit4::class)
class ConnectLinkInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container
    private val here = address("https://here-fixture.invalid/shelfarr")
    private val there = address("https://there-fixture.invalid")

    private fun address(value: String) = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address

    private fun link(server: ServerAddress): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(ConnectLink.build(server)))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setClass(app, MainActivity::class.java)

    @Before
    fun setUp() = signOut()

    @After
    fun tearDown() = signOut()

    private fun signOut() {
        runBlocking {
            container.currentAccount()?.let { account ->
                account.close()
                account.directory.deleteRecursively()
            }
        }
        container.sessions.clear()
    }

    @Test
    fun aBrowserLinkResolvesToShelfarrOnly() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(ConnectLink.build(here))).addCategory(Intent.CATEGORY_BROWSABLE)
        val matches = app.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .filter { it.activityInfo.packageName == app.packageName }
        assertEquals(listOf(MainActivity::class.java.name), matches.map { it.activityInfo.name })
    }

    @Test
    fun signedOutTheLinkFillsInTheServerAndStartsSigningIn() {
        ActivityScenario.launch<MainActivity>(link(there)).use {
            // Signing in was started for the linked server (unreachable here), with no typing.
            waitForText("Couldn't reach there-fixture.invalid", substring = true)
            waitForText("https://there-fixture.invalid")
            capture("connect-link-signed-out.png")
            assertEquals(SessionState.SignedOut, container.sessions.session.value)
            assertNull(container.sessions.pendingAuthorization(System.currentTimeMillis()))
        }
    }

    @Test
    fun signedInALinkForAnotherServerExplainsAndChangesNothing() {
        val session = Session(here, Me("link-fixture", "Ada"), "link-fixture-token")
        container.sessions.signIn(session)
        container.setAppearance(AppearanceMode.DARK)
        ActivityScenario.launch<MainActivity>(link(there)).use { scenario ->
            waitForText("Connected to another server")
            capture("connect-link-other-server.png")
            assertEquals(SessionState.SignedIn(session), container.sessions.session.value)

            // The explanation survives recreation, and the link isn't acted on twice.
            scenario.recreate()
            waitForText("Connected to another server")
            compose.onAllNodesWithText("OK")[0].performClick()
            compose.waitUntil(10_000) { !compose.onAllNodesWithText("Connected to another server").exists() }

            // A warm link arrives through onNewIntent.
            app.startActivity(link(there).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            waitForText("Connected to another server")
            compose.onAllNodesWithText("OK")[0].performClick()
        }
        assertEquals(SessionState.SignedIn(session), container.sessions.session.value)
        assertEquals(AppearanceMode.DARK, container.appearance.value)
        container.setAppearance(AppearanceMode.SYSTEM)
    }

    @Test
    fun signedInALinkForTheSameServerJustOpensTheApp() {
        val session = Session(here, Me("link-fixture", "Ada"), "link-fixture-token")
        container.sessions.signIn(session)
        ActivityScenario.launch<MainActivity>(link(here)).use {
            waitForText("Settings")
            SystemClock.sleep(1_000)
            assertTrue(!compose.onAllNodesWithText("Connected to another server").exists())
            assertEquals(SessionState.SignedIn(session), container.sessions.session.value)
        }
    }

    @Test
    fun reopeningFromRecentsDoesNotRepeatTheLink() {
        val session = Session(here, Me("link-fixture", "Ada"), "link-fixture-token")
        container.sessions.signIn(session)
        ActivityScenario.launch<MainActivity>(link(there).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)).use {
            waitForText("Settings")
            SystemClock.sleep(1_000)
            assertTrue(!compose.onAllNodesWithText("Connected to another server").exists())
        }
    }

    @Test
    fun malformedLinksAreIgnored() {
        val bad = Intent(Intent.ACTION_VIEW, Uri.parse("shelfarr://connect?server=https%3A%2F%2Fthere-fixture.invalid&token=abc"))
            .setClass(app, MainActivity::class.java)
        ActivityScenario.launch<MainActivity>(bad).use {
            waitForText("Server address")
            SystemClock.sleep(1_000)
            assertTrue(!compose.onAllNodesWithText("there-fixture.invalid", substring = true).exists())
            assertEquals(SessionState.SignedOut, container.sessions.session.value)
        }
    }

    private fun waitForText(text: String, substring: Boolean = false) =
        compose.waitUntil(20_000) { compose.onAllNodesWithText(text, substring = substring).exists() }

    private fun SemanticsNodeInteractionCollection.exists() = fetchSemanticsNodes().isNotEmpty()

    private fun capture(name: String) {
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir") ?: return
        val folder = File(output)
        if (!folder.isDirectory && !folder.mkdirs()) return
        // A dialog is its own root, drawn last.
        val bitmap = compose.onAllNodes(isRoot()).onLast().captureToImage().asAndroidBitmap()
        File(folder, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
