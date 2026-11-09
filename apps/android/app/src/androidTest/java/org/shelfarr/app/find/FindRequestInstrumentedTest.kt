package org.shelfarr.app.find

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.RequestAccess
import org.shelfarr.app.core.RequestScopes
import org.shelfarr.app.core.Session
import org.shelfarr.app.ui.MainActivity

/**
 * Requesting through the real app process: the Keystore session, the live account
 * services and MainActivity, against an in-process fixture of the server contract.
 * Synthetic data only; nothing is searched for, bought or acquired.
 */
@RunWith(AndroidJUnit4::class)
class FindRequestInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container
    private val fixture = RequestFixtureApi().start()

    @Before
    fun setUp() = signOut()

    @After
    fun tearDown() {
        signOut()
        fixture.shutdown()
    }

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
    fun addingRequestingKeepsTheLiveAccountAndItsFiles() {
        val before = Session(fixture.address, Me("u1", "Ada"), fixture.issue(), RequestScopes.BASE)
        container.sessions.signIn(before)
        val services = container.currentAccount()!!
        val kept = File(services.directory, "kept-by-upgrade.txt").apply { parentFile?.mkdirs(); writeText("place") }

        runBlocking {
            container.requesting.refresh(before)
            assertEquals(RequestAccess.NotAllowed(), container.requesting.state.value)
            container.requesting.start(before)
            withTimeout(20_000) { container.requesting.state.first { it == RequestAccess.Allowed } }
        }
        val after = container.sessions.signedIn!!
        assertEquals(before.accountKey, after.accountKey)
        assertNotEquals(before.accessToken, after.accessToken)
        assertTrue(after.canRequest)
        assertSame("the account's services are kept, not rebuilt", services, container.currentAccount())
        assertEquals(after.accessToken, services.session.accessToken)
        assertEquals("place", kept.readText())
        assertTrue(before.accessToken in fixture.revoked)
    }

    @Test
    fun findRequestFollowAndOpenInTheRealApp() {
        val scopes = RequestScopes.BASE + RequestScopes.REQUESTING
        container.sessions.signIn(Session(fixture.address, Me("u1", "Ada", scopes = scopes), fixture.issue(scopes), scopes))
        ActivityScenario.launch(MainActivity::class.java).use {
            waitForText("Find")
            compose.onAllNodesWithText("Find").onLast().performClick()
            compose.waitUntil(20_000) { compose.onAllNodes(hasTestTag("find-query")).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("find-query").performTextInput("light")
            compose.onNodeWithTag("find-submit").performClick()
            waitForText("The Lighthouse Keeper")
            capture("find-results.png")
            compose.onNodeWithTag("result:fx:lighthouse").performClick()
            waitForText("Choose a format")
            compose.onNodeWithTag("format:audiobook").performClick()
            compose.onNodeWithTag("request-submit").performClick()
            runCatching { compose.onNodeWithTag("request-submit").performClick() }
            compose.waitUntil(20_000) { compose.onAllNodes(hasTestTag("request-stage")).fetchSemanticsNodes().isNotEmpty() }
            assertEquals(1, fixture.createRequests.get())
            waitForText("Listen now", timeoutMs = 60_000)
            capture("request-ready.png")
            compose.onNodeWithText("Listen now").performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Listen now").fetchSemanticsNodes().isEmpty() }
            capture("request-opened.png")
        }
    }

    private fun waitForText(text: String, timeoutMs: Long = 20_000) {
        compose.waitUntil(timeoutMs) { compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun capture(name: String) {
        val directory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: return
        directory.mkdirs()
        val bitmap = compose.onAllNodes(isRoot()).onLast().captureToImage().asAndroidBitmap()
        File(directory, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
