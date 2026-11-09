package org.shelfarr.app.find

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.shared.publication.Locator
import org.shelfarr.app.R
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.RequestAccess
import org.shelfarr.app.core.RequestScopes
import org.shelfarr.app.core.RequestStage
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.reader.ReaderActivity
import org.shelfarr.app.reader.ReaderState
import org.shelfarr.app.reader.ReaderViewModel
import org.shelfarr.app.ui.MainActivity

/**
 * Acceptance against a real, isolated Shelfarr server: nothing in this process stands in
 * for the server, the provider or the book. From a fresh install the visible UI connects
 * to the server, lets the person allow requesting, finds a public-domain title through the
 * server's metadata providers, requests the ebook once, follows the server's own request
 * stages while its jobs search Project Gutenberg, download and file the EPUB, and opens it
 * in the production reader. A page turned by a tap is saved to that server, read back from
 * it, and the book reopens on the same text.
 *
 * Only the two browser approvals happen outside the app: the harness decides each grant
 * for its synthetic account on the server (see the acceptance report). Run it with
 * `-e shelfarrRealServer http://127.0.0.1:PORT` against that harness on an emulator;
 * without the argument there is no server to accept against, so it does not run. It
 * refuses, before touching anything, a device that isn't positively an emulator and a
 * server address other than the emulator's loopback or host alias.
 */
@RunWith(AndroidJUnit4::class)
class RealServerRequestTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val arguments = InstrumentationRegistry.getArguments()
    private val container get() = app.container
    private val server: String? = arguments.getString("shelfarrRealServer")
    private val query = arguments.getString("shelfarrRealQuery") ?: "A Modest Proposal"
    private val title = arguments.getString("shelfarrRealTitle") ?: "A Modest Proposal"
    private val author = arguments.getString("shelfarrRealAuthor") ?: "Jonathan Swift"
    /** The first words of the body text, reached by turning pages from the cover. */
    private val bodyStart = arguments.getString("shelfarrRealBodyStart") ?: "It is a melancholy object"
    private val readyTimeoutMs = (arguments.getString("shelfarrRealReadyTimeoutSeconds")?.toLong() ?: 600L) * 1_000
    /** Set only once this is known to be an emulator and an isolated server: until then nothing is touched. */
    private var armed = false
    /** The full-screen hint setting as found, when this run changed it; null when it didn't. */
    private var fullScreenHint: String? = null

    @Before
    fun setUp() {
        // JUnit still runs @After after a skip or a refusal here; `armed` stays false then.
        assumeTrue("Needs an isolated acceptance server (-e shelfarrRealServer)", server != null)
        // This signs out, launches the app, changes a secure setting and talks to a server.
        // Refuse anything but a positively identified emulator, whoever started the run.
        val qemu = listOf("ro.kernel.qemu", "ro.boot.qemu").map { shell("getprop $it").trim() }
        assertTrue(
            "Emulator only: refusing on ${Build.FINGERPRINT} (hardware ${Build.HARDWARE}, qemu $qemu)",
            "1" in qemu && Build.HARDWARE in setOf("ranchu", "goldfish"),
        )
        // Only a server reached through the emulator's own loopback or host alias: a disposable
        // instance forwarded for this run, never a household server's address.
        val host = server?.let { runCatching { java.net.URI(it).host }.getOrNull() }
        assertTrue("An isolated server on 127.0.0.1, localhost or 10.0.2.2 only, not $server", host in setOf("127.0.0.1", "localhost", "10.0.2.2"))
        armed = true
        evidence("armed on ${Build.FINGERPRINT} for $server")
        signOut()
        fullScreenHint = shell("settings get secure $FULL_SCREEN_HINT").trim()
        shell("settings put secure $FULL_SCREEN_HINT confirmed")
    }

    @After
    fun tearDown() {
        if (!armed) return
        finishActivities()
        // Disconnecting revokes this run's token on the acceptance server.
        runBlocking { container.sessions.signedIn?.let { runCatching { container.currentAccount()?.api?.revoke(it.server) } } }
        signOut()
        val previous = fullScreenHint ?: return
        if (previous.isEmpty() || previous == "null") shell("settings delete secure $FULL_SCREEN_HINT")
        else shell("settings put secure $FULL_SCREEN_HINT $previous")
    }

    private fun signOut() {
        runBlocking {
            container.currentAccount()?.let { account ->
                account.close()
                container.epubCache.clear(account.session.accountKey)
                account.directory.deleteRecursively()
            }
        }
        container.sessions.clear()
    }

    @Test
    fun connectFindRequestAndReadARealBook() {
        // Opened, and later returned to, the way the launcher does it.
        app.startActivity(launcherIntent())
        awaitCondition("the app opened") { appInFront() }
        try {
            connect()
            allowRequesting()
            val publication = findAndRequestOnce()
            read(publication)
        } catch (failure: Throwable) {
            failureEvidence()
            throw failure
        }
    }

    private fun launcherIntent() =
        Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setClass(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)

    /** What was on screen when the run failed, so a live failure can be classified. Never the approval code. */
    private fun failureEvidence() {
        if (!appInFront()) {
            // Another app (the browser) is in front; its address bar can show the code.
            evidence("failure: the app was not in front; no display saved")
            return
        }
        runCatching {
            val code = Regex("\\b[A-Z0-9]{4}-[A-Z0-9]{4}\\b")
            val nodes = compose.onAllNodes(SemanticsMatcher("any") { true }).fetchSemanticsNodes()
            var showsCode = false
            nodes.forEach { node ->
                val texts = node.config.getOrElseNullable(SemanticsProperties.Text) { null }.orEmpty().map { it.text } +
                    node.config.getOrElseNullable(SemanticsProperties.ContentDescription) { null }.orEmpty()
                texts.filter(String::isNotBlank).forEach { text ->
                    if (code.containsMatchIn(text) || text.startsWith("Confirmation code") || text.startsWith("Code ")) showsCode = true
                    evidence("failure screen: ${code.replace(text, "[code]").let { if (it.startsWith("Confirmation code") || it.startsWith("Code ")) "[code]" else it }}")
                }
            }
            if (showsCode) evidence("failure display not saved: it shows an approval code") else displayCapture("real-failure-display.png", reader = false)
        }.onFailure { evidence("failure evidence unavailable: $it") }
    }

    /** Server address, local HTTP for the emulator's loopback, Continue, browser approval. */
    private fun connect() {
        waitForText("Server address")
        compose.onNode(hasSetTextAction()).performTextInput(requireNotNull(server))
        compose.onNodeWithText("Allow local HTTP").performClick()
        capture("real-connect-address.png")
        // The keyboard is open over Continue; its Go key submits, as a person would.
        compose.onNode(hasSetTextAction()).performImeAction()
        // The app shows the code and opens the server's approval page in the browser.
        // The code itself is never logged or captured.
        awaitCondition("the device approval screen or the browser", 30_000) {
            !appInFront() || runCatching { compose.onAllNodesWithText("Approve this device").fetchSemanticsNodes().isNotEmpty() }.getOrDefault(false)
        }
        awaitCondition("the server's approval of this device", 300_000) { container.sessions.session.value is SessionState.SignedIn }
        bringAppToFront()
        val session = requireNotNull(container.sessions.signedIn)
        assertEquals(server, session.server.toString().removeSuffix("/"))
        assertEquals("acceptance_reader", session.user.username)
        assertFalse("a new connection reads and listens only: ${session.scopes}", session.canRequest)
        assertEquals(RequestScopes.BASE.sorted(), session.scopes.sorted())
        evidence("signed in as ${session.user.username} scopes=${session.scopes}")
    }

    /** Find explains requesting; one approval (despite a second tap) adds it in place. */
    private fun allowRequesting() {
        waitForText("Find")
        compose.onAllNodesWithText("Find").onLast().performClick()
        compose.waitUntil(30_000) { compose.onAllNodes(hasTestTag("find-explainer-action")).fetchSemanticsNodes().isNotEmpty() }
        waitForText("Allow requesting")
        assertTrue("no searching before approval", compose.onAllNodes(hasTestTag("find-query")).fetchSemanticsNodes().isEmpty())
        capture("real-find-allow-requesting.png")
        val before = requireNotNull(container.sessions.signedIn)
        val services = requireNotNull(container.currentAccount())
        compose.onNodeWithTag("find-explainer-action").performClick()
        runCatching { compose.onNodeWithTag("find-explainer-action").performClick() }
        awaitCondition("requesting approved on the server", 300_000) { container.requesting.state.value == RequestAccess.Allowed }
        bringAppToFront()
        val after = requireNotNull(container.sessions.signedIn)
        assertEquals(before.accountKey, after.accountKey)
        assertNotEquals("a replacement credential", before.accessToken, after.accessToken)
        assertTrue(after.canRequest)
        assertSame("the account's services are kept, not rebuilt", services, container.currentAccount())
        evidence("requesting allowed in place; scopes=${after.scopes}")
    }

    /** Searches the server's providers, requests the ebook once and follows it until ready. */
    private fun findAndRequestOnce(): String {
        compose.waitUntil(30_000) { compose.onAllNodes(hasTestTag("find-query")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("find-query").performTextInput(query)
        compose.onNodeWithTag("find-submit").performClick()
        val result = SemanticsMatcher("a result for $title by $author") { node ->
            val tag = node.config.getOrElseNullable(SemanticsProperties.TestTag) { null }
            val texts = node.config.getOrElseNullable(SemanticsProperties.Text) { null }.orEmpty().map { it.text }
            tag?.startsWith("result:") == true && title in texts && texts.any { author in it }
        }
        compose.waitUntil(90_000) { compose.onAllNodes(result).fetchSemanticsNodes().isNotEmpty() }
        capture("real-find-results.png")
        val chosen = compose.onAllNodes(result).onFirst()
        evidence("chose ${chosen.fetchSemanticsNode().config[SemanticsProperties.TestTag]}")
        chosen.performClick()
        waitForText("Choose a format")
        compose.onNodeWithTag("format:ebook").performClick()
        capture("real-request-format.png")
        compose.onNodeWithTag("request-submit").performClick()
        runCatching { compose.onNodeWithTag("request-submit").performClick() }
        compose.waitUntil(30_000) { compose.onAllNodes(hasTestTag("request-stage")).fetchSemanticsNodes().isNotEmpty() }

        // Follow the server's stages as the page shows them, until it offers Read now.
        val seen = mutableListOf<String>()
        val deadline = SystemClock.elapsedRealtime() + readyTimeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val stage = compose.onAllNodes(hasTestTag("request-stage")).fetchSemanticsNodes().firstOrNull()
                ?.config?.getOrElseNullable(SemanticsProperties.Text) { null }?.joinToString(" — ") { it.text }
            if (stage != null && stage != seen.lastOrNull()) {
                seen += stage
                evidence("stage: $stage")
                capture("real-request-stage-${seen.size}.png")
                for (stop in listOf("No copy found yet", "Available to buy", "Stopped", "Finished", "Waiting for the server's admin")) {
                    assertFalse("the request ended at \"$stage\"", stage.startsWith(stop))
                }
            }
            if (compose.onAllNodesWithText("Read now").fetchSemanticsNodes().isNotEmpty()) break
            SystemClock.sleep(250)
        }
        assertTrue("Read now offered after $seen", compose.onAllNodesWithText("Read now").fetchSemanticsNodes().isNotEmpty())
        capture("real-request-ready-ebook.png")

        val account = requireNotNull(container.currentAccount())
        val mine = runBlocking { account.api.requests(account.session.server) }.filter { it.title == title || it.title.equals(title, ignoreCase = true) }
        assertEquals("one request for the title despite two taps: $mine", 1, mine.size)
        val request = mine.single()
        assertEquals(RequestStage.AVAILABLE, request.stage)
        evidence("request ${request.id} ${request.stage} publication=${request.publicationId}; stages seen $seen")
        return requireNotNull(request.publicationId)
    }

    private fun read(publication: String) {
        val account = requireNotNull(container.currentAccount())
        val item = runBlocking { account.publication(publication) }
        val epub = item.assets.single { it.format == "epub" }
        evidence("publication ${item.title} by ${item.author}: ${epub.filename} ${epub.sizeBytes} bytes")
        compose.onNodeWithText("Read now").performClick()

        val reader = awaitReader(null)
        awaitCondition("the EPUB's text loaded", 60_000) { evaluate(reader, "document.body ? document.body.innerHTML.length : 0").toIntOrNull()?.let { it > 0 } == true }
        awaitCondition("the opening page laid out") { shown(reader)?.locations?.position != null }
        val opening = shown(reader)!!
        assertTrue("reader state ${readerState(reader)}", readerState(reader) is ReaderState.Ready)
        evidence("opening ${opening.toJSON()}")
        coverScreenshot(reader, "real-read-opening.png")

        // Turn pages with taps on the right edge until the body text begins on screen.
        var previous = opening
        var turns = 0
        while (!pageText(reader).first.startsWith(bodyStart)) {
            assertTrue("reached \"$bodyStart\" within $MAX_TURNS_TO_BODY page turns", turns < MAX_TURNS_TO_BODY)
            tapRightEdge(reader)
            turns++
            val before = previous
            awaitCondition("page turn $turns") { shown(reader).let { it != null && it != before && it.after(before) } }
            awaitCondition("page turn $turns laid out") { pageText(reader).first.isNotEmpty() || shown(reader)?.href?.toString()?.endsWith("wrap0000.xhtml") == true }
            previous = shown(reader)!!
            evidence("turn $turns ${previous.toJSON()} first=\"${pageText(reader).first}\"")
        }
        val body = shown(reader)!!
        val bodyPage = pageText(reader)
        assertTrue("the book's own words: ${evaluate(reader, "document.body.innerText.length")}", evaluate(reader, "document.body.innerText").contains(bodyStart))
        readerScreenshot(reader, "real-read-body.png")

        // One more page into the text: the place to save and reopen.
        val tappedAt = System.currentTimeMillis()
        tapRightEdge(reader)
        awaitCondition("the next page of the text") { shown(reader).let { it != null && it != body && it.after(body) } }
        awaitCondition("the next page's words on screen") { pageText(reader).let { it.first.isNotEmpty() && it != bodyPage } }
        val turned = shown(reader)!!
        val turnedPage = pageText(reader)
        assertEquals("still in the body text", body.href, turned.href)
        assertTrue("inside the chapter: ${turned.locations}", (turned.locations.progression ?: 0.0) > 0.0)
        assertFalse(turnedPage.first.startsWith(bodyStart))

        // The device saves the place and the server acknowledges exactly it.
        val sync = account.progress.sync(publication)
        awaitCondition("the turned page saved to the server", 60_000) {
            val saved = runCatching { runBlocking { account.api.progress(account.session.server, publication) } }.getOrNull()
            saved != null && saved.assetId == epub.id && saved.locator == place(turned) &&
                (ActivityTime.parse(saved.observedAt) ?: 0L) >= tappedAt && !runBlocking { sync.snapshot() }.hasUnsyncedChanges
        }
        val saved = runBlocking { account.api.progress(account.session.server, publication) }!!
        evidence("turned ${turned.toJSON()} page=$turnedPage; server version=${saved.version} observed_at=${saved.observedAt} locator=${saved.locator}")
        readerScreenshot(reader, "real-read-turned.png")

        // Leave with Back and open the book again from the request.
        press(reader, KeyEvent.KEYCODE_BACK)
        awaitCondition("the reader closed") { resumedReader() == null }
        waitForText("Read now")
        compose.onNodeWithText("Read now").performClick()
        val reopened = awaitReader(reader)
        awaitCondition("the saved page's words shown again", 60_000) { pageText(reopened) == turnedPage }
        assertEquals(place(turned), place(shown(reopened)!!))
        evidence("reopened ${shown(reopened)!!.toJSON()} page=${pageText(reopened)}")
        readerScreenshot(reopened, "real-read-reopened.png")
        press(reopened, KeyEvent.KEYCODE_BACK)
        awaitCondition("the reopened reader closed") { resumedReader() == null }
    }

    private fun Locator.after(other: Locator): Boolean {
        val total = locations.totalProgression
        val previous = other.locations.totalProgression
        if (total != null && previous != null && total != previous) return total > previous
        if (href != other.href) return true
        return (locations.progression ?: 0.0) > (other.locations.progression ?: 0.0)
    }

    private fun evidence(line: String) = android.util.Log.i("RealServerEvidence", line)

    private fun waitForText(text: String, timeoutMs: Long = 30_000) {
        compose.waitUntil(timeoutMs) { compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun appInFront(): Boolean {
        var resumed = false
        instrumentation.runOnMainSync {
            resumed = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).isNotEmpty()
        }
        return resumed
    }

    /** Back from the browser, as a person switches back to the app. */
    private fun bringAppToFront() {
        if (!appInFront()) app.startActivity(launcherIntent())
        awaitCondition("the app in front again") { appInFront() }
        instrumentation.waitForIdleSync()
    }

    private fun capture(name: String) {
        val directory = outputDirectory() ?: return
        val bitmap = compose.onAllNodes(isRoot()).onLast().captureToImage().asAndroidBitmap()
        File(directory, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun outputDirectory(): File? =
        arguments.getString("additionalTestOutputDir")?.let(::File)?.also { check(it.isDirectory || it.mkdirs()) { "Cannot create test output directory" } }

    private fun resumedReader(): ReaderActivity? {
        var found: ReaderActivity? = null
        instrumentation.runOnMainSync {
            found = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<ReaderActivity>().firstOrNull()
        }
        return found
    }

    private fun awaitReader(previous: ReaderActivity?): ReaderActivity {
        awaitCondition("the reader opened", 60_000) { resumedReader()?.takeIf { it !== previous } != null }
        return resumedReader()!!
    }

    private fun finishActivities() {
        instrumentation.runOnMainSync {
            Stage.values().filter { it != Stage.DESTROYED }.flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }
                .forEach { it.finish() }
        }
        instrumentation.waitForIdleSync()
    }

    private fun navigator(reader: ReaderActivity) = reader.supportFragmentManager.findFragmentById(R.id.reader_navigator) as? EpubNavigatorFragment

    private fun shown(reader: ReaderActivity): Locator? {
        val found = AtomicReference<Locator?>()
        instrumentation.runOnMainSync { found.set(navigator(reader)?.currentLocator?.value) }
        return found.get()
    }

    private fun place(locator: Locator) = ApiJson.parseToJsonElement(locator.toJSON().toString())

    /** The first and last words visible on the page, read from the laid-out DOM. */
    private fun pageText(reader: ReaderActivity): Pair<String, String> {
        val raw = evaluate(reader, VISIBLE_TEXT)
        if (raw.isEmpty()) return "" to ""
        // Only the document of the place the navigator reports counts as the page shown.
        val resource = shown(reader)?.href?.toString()?.substringAfterLast('/') ?: return "" to ""
        // evaluateJavascript hands back the JSON string that JSON.stringify produced.
        val values = ApiJson.parseToJsonElement(ApiJson.parseToJsonElement(raw).jsonPrimitive.content).jsonArray.map { it.jsonPrimitive.content }
        if (!values[2].endsWith(resource)) return "" to ""
        return values[0] to values[1]
    }

    private fun evaluate(reader: ReaderActivity, script: String): String {
        val views = mutableListOf<WebView>()
        instrumentation.runOnMainSync { collectWebViews(reader.window.decorView, views) }
        // Readium keeps the neighbouring resources' WebViews laid out; read the one on screen.
        val center = Rect()
        instrumentation.runOnMainSync { reader.window.decorView.getGlobalVisibleRect(center) }
        val onScreen = views.map { view ->
            val visible = Rect()
            instrumentation.runOnMainSync { view.getGlobalVisibleRect(visible) }
            view to visible
        }.filter { (_, visible) -> visible.contains(center.centerX(), center.centerY()) }
            .sortedByDescending { (_, visible) -> visible.width() * visible.height() }
            .map { it.first }
        return onScreen.take(1).firstNotNullOfOrNull { view ->
            val result = AtomicReference<String>()
            val done = CountDownLatch(1)
            instrumentation.runOnMainSync { view.evaluateJavascript(script) { result.set(it); done.countDown() } }
            if (done.await(2, TimeUnit.SECONDS)) result.get()?.takeIf { it != "null" && it != "\"\"" } else null
        }.orEmpty()
    }

    private fun collectWebViews(view: View, found: MutableList<WebView>) {
        if (view is WebView && view.isShown && view.alpha > 0 && view.getGlobalVisibleRect(Rect())) found += view
        if (view is ViewGroup) for (index in 0 until view.childCount) collectWebViews(view.getChildAt(index), found)
    }

    private fun awaitFocus(reader: ReaderActivity) =
        awaitCondition("the reader window to have input focus") {
            var focused = false
            instrumentation.runOnMainSync { focused = reader.hasWindowFocus() }
            focused
        }

    private fun press(reader: ReaderActivity, keyCode: Int) {
        awaitFocus(reader)
        instrumentation.sendKeyDownUpSync(keyCode)
    }

    private fun tapRightEdge(reader: ReaderActivity) {
        awaitFocus(reader)
        val bounds = Rect()
        instrumentation.runOnMainSync { reader.window.decorView.getGlobalVisibleRect(bounds) }
        val x = bounds.left + bounds.width() * 0.92f
        val y = bounds.exactCenterY()
        val down = SystemClock.uptimeMillis()
        listOf(MotionEvent.ACTION_DOWN to down, MotionEvent.ACTION_UP to down + 80).forEach { (action, time) ->
            val event = MotionEvent.obtain(down, time, action, x, y, 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            try {
                assertTrue("The tap at ($x, $y) was not delivered", instrumentation.uiAutomation.injectInputEvent(event, true))
            } finally {
                event.recycle()
            }
        }
    }

    private fun awaitCondition(description: String, timeoutMs: Long = 30_000, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        assertTrue("Timed out waiting for $description", condition())
    }

    private fun readerState(reader: ReaderActivity): ReaderState {
        val found = AtomicReference<ReaderState>()
        instrumentation.runOnMainSync { found.set(ViewModelProvider(reader)[ReaderViewModel::class.java].state.value) }
        return found.get()
    }

    /** The display as it is, for a page whose content is an image (the cover). */
    private fun displayCapture(name: String, reader: Boolean = true) {
        if (reader) assertEquals("the preparing screen is gone", 0, compose.onAllNodesWithText("Opening", substring = true).fetchSemanticsNodes().size)
        instrumentation.waitForIdleSync()
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            evidence("$name inked rows ${"%.3f".format(textRows(image))} (not asserted)")
            val directory = outputDirectory() ?: return
            File(directory, name).outputStream().use { check(image.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally {
            image.recycle()
        }
    }

    /**
     * The opening page is the book's cover image, not text: wait until the display carries
     * the drawn cover (its title lettering inks about a quarter of the rows) and save that.
     *
     * Under a Compose test rule every Compose root in this process runs on the test's frame
     * clock, which advances only when the test synchronises with Compose. Waiting without
     * that froze the reader's own overlay on "Opening…" (0.034 inked rows) for 90 seconds
     * while the window kept rendering frames, until the next Compose query. Each attempt
     * here lets that clock run, as it always does on a device.
     */
    private fun coverScreenshot(reader: ReaderActivity, name: String) {
        assertTrue("reader state ${readerState(reader)}", readerState(reader) is ReaderState.Ready)
        val started = SystemClock.elapsedRealtime()
        val framesAtStart = framesRendered()
        var shown: Bitmap? = null
        var waiting = 0
        awaitCondition("the cover drawn on the display for $name", COVER_TIMEOUT_MS) {
            compose.waitForIdle()
            val image = instrumentation.uiAutomation.takeScreenshot() ?: return@awaitCondition false
            val rows = textRows(image)
            val ok = rows >= MIN_COVER_ROWS
            if (ok) shown = image else image.recycle().also { if (waiting++ == 0) evidence("$name not drawn yet: inked rows ${"%.3f".format(rows)}; frames $framesAtStart") }
            ok
        }
        evidence("$name drawn after ${SystemClock.elapsedRealtime() - started}ms without input; frames $framesAtStart -> ${framesRendered()}")
        val bitmap = requireNotNull(shown)
        try {
            evidence("$name inked rows ${"%.3f".format(textRows(bitmap))}")
            val directory = outputDirectory() ?: return
            File(directory, name).outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally {
            bitmap.recycle()
        }
    }

    /** "Total frames rendered" from the app's own gfxinfo: whether the window is drawing at all. */
    private fun framesRendered(): String =
        shell("dumpsys gfxinfo ${app.packageName}").lineSequence().filter { "Total frames rendered" in it }.joinToString("|") { it.trim() }

    /**
     * The reader open (not preparing), and a page of text both in the window's submitted
     * buffer and on the display itself. Text rows must fill much of the page, so neither
     * the "Opening…" screen nor a blank or stale frame passes. The display image is saved.
     */
    private fun readerScreenshot(reader: ReaderActivity, name: String) {
        assertTrue("reader state ${readerState(reader)}", readerState(reader) is ReaderState.Ready)
        assertEquals("the preparing screen is gone", 0, compose.onAllNodesWithText("Opening", substring = true).fetchSemanticsNodes().size)
        awaitCondition("a painted page of text in the reader's window for $name") {
            captureWindow(reader)?.let { image -> textRows(image).also { image.recycle() } >= MIN_TEXT_ROWS } == true
        }
        var shown: Bitmap? = null
        awaitCondition("a page of text on the display for $name") {
            compose.waitForIdle()
            val image = instrumentation.uiAutomation.takeScreenshot() ?: return@awaitCondition false
            val ok = textRows(image) >= MIN_TEXT_ROWS
            if (ok) shown = image else image.recycle()
            ok
        }
        val bitmap = requireNotNull(shown)
        try {
            evidence("$name inked rows ${"%.3f".format(textRows(bitmap))}")
            val directory = outputDirectory() ?: return
            File(directory, name).outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally {
            bitmap.recycle()
        }
    }

    private fun captureWindow(reader: ReaderActivity): Bitmap? {
        var bitmap: Bitmap? = null
        val result = AtomicInteger(-1)
        val copied = CountDownLatch(1)
        instrumentation.runOnMainSync {
            val view = reader.window.decorView
            if (view.width == 0 || view.height == 0) {
                copied.countDown()
                return@runOnMainSync
            }
            val image = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            bitmap = image
            PixelCopy.request(reader.window, image, { code -> result.set(code); copied.countDown() }, Handler(Looper.getMainLooper()))
        }
        if (copied.await(3, TimeUnit.SECONDS) && result.get() == PixelCopy.SUCCESS) return bitmap
        bitmap?.recycle()
        return null
    }

    /** The share of rows, between a tenth and nine tenths of the height, that carry dark text pixels. */
    private fun textRows(image: Bitmap): Double {
        var rows = 0
        var inked = 0
        for (y in image.height / 10 until image.height * 9 / 10 step 4) {
            rows++
            var ink = 0
            for (x in image.width / 10 until image.width * 9 / 10 step 2) {
                val pixel = image.getPixel(x, y)
                if ((pixel shr 16 and 255) < 120 && (pixel shr 8 and 255) < 120 && (pixel and 255) < 120) ink++
            }
            if (ink >= 3) inked++
        }
        return inked.toDouble() / rows
    }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes().decodeToString() }

    private companion object {
        const val FULL_SCREEN_HINT = "immersive_mode_confirmations"
        const val MIN_TEXT_ROWS = 0.3
        /** The "Opening…" frame inks 3% of rows; this Gutenberg cover about 25%. */
        const val MIN_COVER_ROWS = 0.15
        const val COVER_TIMEOUT_MS = 30_000L
        const val MAX_TURNS_TO_BODY = 8

        /**
         * The first and last visible words: for the first and last text nodes with a line
         * box inside the viewport, the caret position at that line's start or end.
         */
        const val VISIBLE_TEXT = """JSON.stringify((() => {
            const w = innerWidth, h = innerHeight, nodes = [];
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            for (let n = walker.nextNode(); n; n = walker.nextNode()) {
                if (!n.textContent.trim()) continue;
                const range = document.createRange(); range.selectNodeContents(n);
                const boxes = Array.from(range.getClientRects()).filter(r => r.width > 0 && r.right > 0 && r.left < w && r.bottom > 0 && r.top < h);
                if (boxes.length) nodes.push([n, boxes]);
            }
            if (!nodes.length) return ['', '', location.pathname];
            const words = (s) => s.replace(/\s+/g, ' ').trim();
            const at = (x, y) => document.caretRangeFromPoint(x, y);
            const [firstNode, firstBoxes] = nodes[0];
            const start = at(firstBoxes[0].left + 1, firstBoxes[0].top + firstBoxes[0].height / 2);
            const startOffset = start && start.startContainer === firstNode ? start.startOffset : 0;
            const [lastNode, lastBoxes] = nodes[nodes.length - 1];
            const lastBox = lastBoxes[lastBoxes.length - 1];
            const end = at(lastBox.right - 1, lastBox.top + lastBox.height / 2);
            const endOffset = end && end.startContainer === lastNode ? end.startOffset : lastNode.textContent.length;
            return [words(firstNode.textContent.slice(startOffset)).slice(0, 60), words(lastNode.textContent.slice(0, endOffset)).slice(-60), location.pathname];
        })())"""
    }
}
