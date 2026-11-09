package org.shelfarr.app.ui

import android.app.Application
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.navigation.compose.rememberNavController
import com.github.takahirom.roborazzi.captureRoboImage
import java.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ConsumerApi
import org.shelfarr.app.core.Credential
import org.shelfarr.app.core.DeviceAuthorizer
import org.shelfarr.app.core.FormatState
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.NewRequest
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.RequestFixtureApi
import org.shelfarr.app.core.RequestScopes
import org.shelfarr.app.core.RequestingAccess
import org.shelfarr.app.core.RequestingBackend
import org.shelfarr.app.core.SecureStore
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionManager
import org.shelfarr.app.core.buildHttpClient
import org.shelfarr.app.ui.find.FindBackend
import org.shelfarr.app.ui.find.FindViewModel
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * Drives Find → format → request → follow → open through the app's own shell, Find
 * graph and view model, over real HTTP to an in-process fixture of the server contract.
 * Only the account plumbing (Keystore, transfers) is replaced. Nothing is acquired.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class FindFlowTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val fixture = RequestFixtureApi().start()
    private val sessions = SessionManager(object : SecureStore {
        val values = HashMap<String, String>()
        override fun read(name: String) = synchronized(values) { values[name] }
        override fun write(name: String, value: String) = synchronized(values) { values[name] = value }
        override fun delete(name: String) = synchronized(values) { values.remove(name); Unit }
    })
    private val api = ConsumerApi(buildHttpClient(sessions) { sessions.markExpired(it) })
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val requesting = RequestingAccess(
        object : RequestingBackend {
            override val sessions = this@FindFlowTest.sessions
            override val api = this@FindFlowTest.api
            override val authorizer = DeviceAuthorizer(api)
            override fun apiFor(credential: Credential) = ConsumerApi(buildHttpClient({ credential }))
        },
        scope,
        "Shelfarr Android",
    )
    private val opened = mutableListOf<Publication>()
    private val browser = mutableListOf<String>()
    private lateinit var find: FindViewModel

    private val backend = object : FindBackend {
        private fun session() = sessions.signedIn ?: throw ApiException.Unauthorized()
        override val access get() = requesting.state
        override suspend fun refreshAccess() = requesting.refresh(session())
        override suspend fun allowRequesting() = requesting.start(session())
        override fun cancelApproval() = requesting.cancel()
        override suspend fun refreshScopes() {
            sessions.refreshUser(api.me(session().server), session())
            refreshAccess()
        }
        override suspend fun discover(query: String) = api.discover(session().server, query)
        override suspend fun requests() = api.requests(session().server)
        override suspend fun request(id: String) = api.request(session().server, id)
        override suspend fun create(request: NewRequest) = api.createRequest(session().server, request)
        override suspend fun cancel(id: String) = api.cancelRequest(session().server, id)
        override suspend fun publication(id: String) = api.publication(session().server, id)
    }

    @After
    fun tearDown() {
        scope.cancel()
        fixture.shutdown()
        RuntimeEnvironment.setFontScale(1f)
    }

    private fun signIn(scopes: List<String> = RequestScopes.BASE) {
        sessions.signIn(Session(fixture.address, Me("u1", "Ada Reader", "ada", scopes), fixture.issue(scopes), scopes))
    }

    private fun render(dark: Boolean = false) {
        find = FindViewModel(backend, pollIntervalMs = 40)
        compose.setContent {
            ShelfarrTheme(if (dark) AppearanceMode.DARK else AppearanceMode.LIGHT) {
                val navController = rememberNavController()
                FindNavigation(find, navController, openBrowser = { browser += it })
                MainShellLayout(navController, miniPlayer = null) {
                    screen(HOME) { Text("Home") }
                    findScreens(find, navController, fixture.address.host, "Ada Reader", openWebsite = {}, openPublication = { opened += it }, openDetails = {})
                }
                androidx.compose.runtime.LaunchedEffect(Unit) { navController.navigate(FIND) }
            }
        }
    }

    /** Lets real HTTP replies and the view model's short delays run on the paused main looper. */
    private fun waitFor(what: String, timeoutMs: Long = 10_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
            compose.waitForIdle()
            if (runCatching(condition).getOrDefault(false)) return
            Thread.sleep(20)
        }
        throw AssertionError("Timed out waiting for $what")
    }

    private fun hasNode(text: String) = compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty()

    @Test
    fun `a late tap after acknowledgement cannot submit the same format again`() {
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        render()
        waitFor("search") { hasNode("Title or author") }
        compose.runOnIdle { find.setQuery("light"); find.search() }
        waitFor("results") { find.find.value.results.isNotEmpty() }
        compose.runOnIdle {
            find.choose(find.find.value.results.first())
            find.selectFormat(BookType.AUDIOBOOK)
            find.submit()
        }
        waitFor("the acknowledged request") {
            !find.title.value.submitting && find.title.value.item?.format(BookType.AUDIOBOOK)?.state == FormatState.REQUESTED
        }

        // The reply can finish before a stale button tap or navigation transition does.
        compose.runOnIdle { find.submit() }
        waitFor("the late tap to finish") { !find.title.value.submitting }
        assertEquals(1, fixture.createRequests.get())

        // The other format is still a separate, deliberate request.
        compose.runOnIdle { find.selectFormat(BookType.EBOOK); find.submit() }
        waitFor("the other format") {
            !find.title.value.submitting && find.title.value.item?.format(BookType.EBOOK)?.state == FormatState.REQUESTED
        }
        assertEquals(2, fixture.createRequests.get())
    }

    @Test
    fun `a read-only connection opts in, then finds, requests, follows and opens an audiobook`() {
        signIn()
        val original = sessions.signedIn!!
        render()
        waitFor("the opt-in explanation") { hasNode("Allow requesting") }
        compose.onNodeWithText("Your library, downloads and saved places stay exactly as they are", substring = true).assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/screenshots/20-find-allow-requesting.png")

        compose.onNodeWithTag("find-explainer-action").performClick()
        waitFor("the approval code") { hasNode("ABCD-EFGH") }
        compose.onRoot().captureRoboImage("build/screenshots/21-find-approving.png")
        assertEquals(1, browser.size)
        waitFor("approval to finish") { compose.onAllNodesWithText("Title or author").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(original.accountKey, sessions.signedIn!!.accountKey)
        assertTrue(sessions.signedIn!!.canRequest)

        compose.onNodeWithTag("find-query").performTextInput("light")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("search results") { hasNode("The Lighthouse Keeper") }
        compose.onNodeWithText("Ebook or audiobook").assertIsDisplayed()
        compose.onRoot().captureRoboImage("build/screenshots/22-find-results.png")

        compose.onNodeWithTag("result:fx:lighthouse").performClick()
        waitFor("the title page") { hasNode("Choose a format") }
        compose.onNodeWithTag("format:audiobook").performClick()
        compose.onNodeWithText("Request audiobook").assertIsEnabled()
        compose.onRoot().captureRoboImage("build/screenshots/23-find-choose-format.png")

        // A burst of taps must make one request.
        val submit = compose.onNodeWithTag("request-submit")
        submit.performClick()
        runCatching { submit.performClick() }
        runCatching { submit.performClick() }
        waitFor("the request page") { compose.onAllNodes(hasTestTag("request-stage")).fetchSemanticsNodes().isNotEmpty() }
        assertEquals(1, fixture.createRequests.get())

        waitFor("downloading") { hasNode("Downloading ·") }
        compose.onRoot().captureRoboImage("build/screenshots/24-request-downloading.png")
        waitFor("the audiobook to be ready") { hasNode("Listen now") }
        compose.onRoot().captureRoboImage("build/screenshots/25-request-ready.png")
        compose.onNodeWithTag("request-open").performClick()
        waitFor("the publication to open") { opened.isNotEmpty() }
        assertEquals("pub-r", opened.single().id.take(5))

        // Back on Find, the request is listed as ready and the title shows the audiobook as in the library.
        compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        waitFor("Find again") { hasNode("Your requests") }
        compose.onNodeWithText("Audiobook · Ready").assertIsDisplayed()
    }

    @Test
    fun `existing, already-requested and offline states are explained, and nothing is requested twice`() {
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        render()
        waitFor("search") { hasNode("Title or author") }
        compose.onNodeWithTag("find-query").performTextInput("r")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("results") { hasNode("Rivers Remember") }
        compose.onNodeWithText("Ebook in your library · Audiobook can be requested").assertIsDisplayed()
        compose.onNodeWithText("Ebook can be requested · Audiobook already requested").assertIsDisplayed()

        compose.onNodeWithTag("result:fx:elsewhere").performClick()
        waitFor("title page") { hasNode("Choose a format") }
        compose.onNodeWithText("Already requested on this server. It will appear in the library.").assertIsDisplayed()
        // Only the ebook can be chosen; it is chosen for you.
        compose.onNodeWithText("Request ebook").assertIsDisplayed()
        compose.onNodeWithTag("format:audiobook").performClick()
        compose.onNodeWithText("Request ebook").assertIsDisplayed()

        fixture.shutdown()
        compose.onNodeWithTag("request-submit").performClick()
        waitFor("the offline message") { hasNode("You're offline. Requesting needs a connection") }
        compose.onNodeWithText("Request ebook").assertIsEnabled()
        assertEquals(0, fixture.createRequests.get())
        compose.onRoot().captureRoboImage("build/screenshots/26-find-offline-request.png")
    }

    @Test
    fun `search offline and empty results say what happened`() {
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        render(dark = true)
        waitFor("search") { hasNode("Title or author") }
        compose.onNodeWithTag("find-query").performTextInput("zzz")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("no results") { hasNode("Nothing found for “zzz”") }
        fixture.searchFails = true
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("catalogue failure") { hasNode("couldn't reach its book catalogues") }
        fixture.shutdown()
        compose.onNodeWithText("Try again").performClick()
        waitFor("offline") { hasNode("You're offline. Finding new books needs a connection") }
        compose.onRoot().captureRoboImage("build/screenshots/27-find-offline-dark.png")
    }

    @Test
    fun `a request that finds nothing, and cancelling one, are plain`() {
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        fixture.outcome = "not_found"
        render()
        waitFor("search") { hasNode("Title or author") }
        compose.onNodeWithTag("find-query").performTextInput("light")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("results") { hasNode("The Lighthouse Keeper") }
        compose.onNodeWithTag("result:fx:lighthouse").performClick()
        waitFor("title") { hasNode("Request ebook") }
        compose.onNodeWithTag("request-submit").performClick()
        waitFor("not found") { hasNode("No copy found yet") }
        compose.onNodeWithTag("request-cancel").performClick()
        compose.onAllNodesWithText("Cancel request")[1].performClick()
        waitFor("stopped") { hasNode("Stopped") }
        compose.onAllNodes(hasTestTag("request-cancel")).fetchSemanticsNodes().let { assertTrue(it.isEmpty()) }
    }

    @Test
    fun `a request the server can't progress alone waits for its admin without claiming copies`() =
        attentionFlow(fontScale = 1f, shot = "30-request-attention")

    @Test
    fun `at the largest text size a request waiting for the admin stays readable and cancellable`() =
        attentionFlow(fontScale = 2f, shot = "31-request-attention-large-text")

    /** As a real server with no acquisition source reports it: still searching, flagged, no reason given. */
    private fun attentionFlow(fontScale: Float, shot: String) {
        RuntimeEnvironment.setFontScale(fontScale)
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        fixture.outcome = "attention"
        render()
        waitFor("search") { hasNode("Title or author") }
        compose.onNodeWithTag("find-query").performTextInput("light")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("results") { hasNode("The Lighthouse Keeper") }
        compose.onNodeWithTag("result:fx:lighthouse").performClick()
        waitFor("title") { hasNode("Choose a format") }
        compose.onNodeWithTag("request-submit").performScrollTo().performClick()
        waitFor("the admin's attention") { hasNode("Waiting for the server's admin") }
        compose.onNodeWithTag("request-stage").performScrollTo().assertIsDisplayed()
        // The API doesn't say why, and a real server with no source looked the same:
        // the page must not claim copies were found, and offers nothing to open.
        assertTrue(hasNode("Shelfarr needs someone to look at this request."))
        assertTrue(!hasNode("found"))
        assertTrue(!hasNode("Read now") && !hasNode("Listen now"))
        compose.onNodeWithTag("request-cancel").performScrollTo().assertIsDisplayed().assertIsEnabled()
        compose.onRoot().captureRoboImage("build/screenshots/$shot.png")
        assertEquals("following the request never sends another", 1, fixture.createRequests.get())
    }

    @Test
    fun `an older server explains itself and a lost permission returns to the opt-in`() {
        fixture.oldServer = true
        signIn()
        render()
        waitFor("old server") { hasNode("Requesting isn't available on") }
        compose.onNodeWithText("Open the website").assertIsDisplayed()
        assertTrue(fixture.deviceRequests.isEmpty())
    }

    @Test
    fun `revoked requesting scope sends the person back to the opt-in`() {
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        render()
        waitFor("search") { hasNode("Title or author") }
        // The server now only grants reading on this token.
        val token = sessions.signedIn!!.accessToken
        fixture.tokens[token] = "u1" to RequestScopes.BASE
        compose.onNodeWithTag("find-query").performTextInput("light")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("the opt-in") { compose.onAllNodes(hasTestTag("find-explainer-action")).fetchSemanticsNodes().isNotEmpty() }
        assertTrue(!sessions.signedIn!!.canRequest)
        assertEquals(token, sessions.signedIn!!.accessToken)
    }

    @Test
    fun `at the largest text size the format choice and request button stay reachable`() {
        RuntimeEnvironment.setFontScale(2f)
        signIn(RequestScopes.BASE + RequestScopes.REQUESTING)
        render()
        waitFor("search") { hasNode("Title or author") }
        compose.onNodeWithTag("find-query").performTextInput("light")
        compose.onNodeWithTag("find-submit").performClick()
        waitFor("results") { hasNode("The Lighthouse Keeper") }
        compose.onNodeWithTag("result:fx:lighthouse").performClick()
        waitFor("title") { hasNode("Choose a format") }
        compose.onNodeWithTag("format:audiobook").performScrollTo().performClick()
        compose.onNodeWithTag("request-submit").performScrollTo().assertIsDisplayed().assertIsEnabled()
        compose.onRoot().captureRoboImage("build/screenshots/28-find-large-text-format.png")
        compose.onNodeWithTag("request-submit").performClick()
        waitFor("request page") { compose.onAllNodes(hasTestTag("request-stage")).fetchSemanticsNodes().isNotEmpty() }
        waitFor("downloading") { hasNode("Downloading ·") }
        compose.onRoot().captureRoboImage("build/screenshots/29-request-large-text.png")
        assertEquals(1, fixture.createRequests.get())
    }
}
