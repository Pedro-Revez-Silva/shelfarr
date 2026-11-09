package org.shelfarr.app.find

import android.graphics.Bitmap
import android.graphics.Rect
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
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
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
import kotlin.math.abs
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
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
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.RequestAccess
import org.shelfarr.app.core.RequestScopes
import org.shelfarr.app.core.Session
import org.shelfarr.app.reader.ReaderActivity
import org.shelfarr.app.reader.ReaderState
import org.shelfarr.app.reader.ReaderViewModel
import org.shelfarr.app.ui.MainActivity

/**
 * Requesting through the real app process: the Keystore session, the live account
 * services and MainActivity, against an in-process fixture of the server contract.
 * Synthetic data only; nothing is searched for, bought or acquired. The acquired
 * publication carries a generated file, so opening it is proven by the production
 * player decoding and advancing a WAV and the production reader showing, turning and
 * saving a page of an EPUB, all driven from the visible UI.
 */
@RunWith(AndroidJUnit4::class)
class FindRequestInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val container get() = app.container
    private val fixture = RequestFixtureApi().start()
    private var fullScreenHint: String? = null

    @Before
    fun setUp() {
        signOut()
        // Hiding the bars shows Android's one-time "Viewing full screen" hint; from Android 15
        // that window takes input focus. A reader sees it once; this emulator is marked as having
        // seen it, as FixedLayoutReaderTest does, and the setting is put back afterwards.
        fullScreenHint = shell("settings get secure $FULL_SCREEN_HINT").trim()
        shell("settings put secure $FULL_SCREEN_HINT confirmed")
    }

    @After
    fun tearDown() {
        runBlocking { container.playback.stop() }
        finishReaders()
        signOut()
        fixture.shutdown()
        val previous = fullScreenHint
        if (previous.isNullOrEmpty() || previous == "null") shell("settings delete secure $FULL_SCREEN_HINT")
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
    fun findRequestFollowAndListenInTheRealApp() {
        signInToRequest()
        ActivityScenario.launch(MainActivity::class.java).use {
            val publication = requestUntilReady("audiobook", "Listen now")
            val wav = "wav-$publication"
            val playback = container.playback
            compose.onNodeWithText("Listen now").performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Listen now").fetchSemanticsNodes().isEmpty() }

            // Listen now autoplays: the generated WAV is fetched from the server and decoded.
            awaitUi("the requested audiobook decoding and advancing") {
                val now = playback.snapshot.value
                now.publication?.id == publication && now.isPlaying && now.positionMs >= 1_500 && shown("Pause")
            }
            playback.snapshot.value.let { now ->
                assertEquals(listOf(wav), now.tracks.map { it.id })
                assertFalse("streamed from the server, not a download", now.fromDevice)
                assertNull(now.problem)
                assertTrue("duration ${now.durationMs}", abs(now.durationMs - FixtureMedia.AUDIO_SECONDS * 1_000L) <= 250)
            }
            assertTrue(fixture.assetReads.toString(), fixture.assetReads.any { it.asset == wav && it.method == "GET" && it.bytes > 0 })
            evidence("listening ${playback.snapshot.value.positionMs}ms of ${playback.snapshot.value.durationMs}ms; reads ${fixture.assetReads}")
            capture("request-listening.png")

            compose.onNode(hasContentDescription("Pause")).performClick()
            awaitUi("the Pause button to stop playback") { !playback.snapshot.value.isPlaying && shown("Play") }
            val paused = playback.snapshot.value.positionMs
            assertTrue("paused at $paused", paused >= 1_500)
            // Pausing saves the place at once; it reaches the server after the sync debounce.
            awaitUi("the paused place acknowledged by the server", 30_000) {
                fixture.progressWrites.lastOrNull { it.first == publication }?.second?.let { write ->
                    write.assetId == wav && abs((write.positionSeconds ?: -1.0) * 1_000 - paused) <= 1_000
                } == true
            }
            evidence("paused at ${paused}ms; server place ${fixture.progressWrites.last { it.first == publication }.second}")
            capture("request-paused.png")

            compose.onNode(hasContentDescription("Play")).performClick()
            awaitUi("the audio advancing again after Play") {
                val now = playback.snapshot.value
                now.isPlaying && now.positionMs >= paused + 2_000 && shown("Pause")
            }
            assertNull(playback.snapshot.value.problem)
            evidence("playing again at ${playback.snapshot.value.positionMs}ms after Play")
            capture("request-resumed.png")
        }
    }

    @Test
    fun findRequestFollowAndReadInTheRealApp() {
        signInToRequest()
        ActivityScenario.launch(MainActivity::class.java).use {
            val publication = requestUntilReady("ebook", "Read now")
            val epub = "epub-$publication"
            compose.onNodeWithText("Read now").performClick()

            val reader = awaitReader(null)
            awaitText(reader, FixtureMedia.OPENING_HEADING)
            assertTrue(fixture.assetReads.toString(), fixture.assetReads.any { it.asset == epub && it.method == "GET" && it.bytes == FixtureMedia.epub.size })
            awaitCondition("the opening page laid out") { shown(reader)?.locations?.position != null }
            val opening = shown(reader)!!
            val openingParagraphs = visibleParagraphs(reader)
            assertTrue("the opening page shows the first paragraph: $openingParagraphs", "keeper-0" in openingParagraphs)
            readerScreenshot(reader, "request-read-opening.png")

            // A finger on the right edge of the page, through the input system.
            val tappedAt = System.currentTimeMillis()
            tapRightEdge(reader)
            awaitCondition("the tap to turn to the next page") {
                val now = shown(reader)
                now != null && now != opening && (now.locations.progression ?: 0.0) > (opening.locations.progression ?: 0.0)
            }
            val turned = shown(reader)!!
            awaitCondition("the next page's paragraphs on screen") {
                visibleParagraphs(reader).let { it.isNotEmpty() && "keeper-0" !in it && it != openingParagraphs }
            }
            val turnedParagraphs = visibleParagraphs(reader)
            assertEquals("${turned.href}", "OEBPS/c1.xhtml", turned.href.toString().removePrefix("/"))
            assertTrue("a place through the book: ${turned.locations}", (turned.locations.totalProgression ?: 0.0) > 0.0)
            val sync = requireNotNull(container.currentAccount()).progress.sync(publication)
            awaitCondition("the turned page acknowledged by the server") {
                val write = fixture.progressWrites.lastOrNull { it.first == publication }?.second
                write != null && write.assetId == epub && write.locator == place(turned) &&
                    (ActivityTime.parse(write.observedAt) ?: 0L) >= tappedAt && !runBlocking { sync.snapshot() }.hasUnsyncedChanges
            }
            evidence("opening ${opening.toJSON()} $openingParagraphs; turned ${turned.toJSON()} $turnedParagraphs; server ${fixture.progressWrites.last { it.first == publication }.second}")
            readerScreenshot(reader, "request-read-turned.png")

            // Leave the book with the Back key and open it again from the same request.
            press(reader, KeyEvent.KEYCODE_BACK)
            awaitCondition("the reader closed") { resumedReader() == null }
            waitForText("Read now")
            compose.onNodeWithText("Read now").performClick()
            val reopened = awaitReader(reader)
            awaitText(reopened, FixtureMedia.OPENING_HEADING)
            awaitCondition("the saved page shown again") { visibleParagraphs(reopened) == turnedParagraphs }
            assertEquals(place(turned), place(shown(reopened)!!))
            evidence("reopened ${shown(reopened)!!.toJSON()}; reads ${fixture.assetReads}")
            readerScreenshot(reopened, "request-read-reopened.png")
            press(reopened, KeyEvent.KEYCODE_BACK)
            awaitCondition("the reopened reader closed") { resumedReader() == null }
        }
    }

    private fun signInToRequest() {
        val scopes = RequestScopes.BASE + RequestScopes.REQUESTING
        container.sessions.signIn(Session(fixture.address, Me("u1", "Ada", scopes = scopes), fixture.issue(scopes), scopes))
    }

    /** Finds, requests [format] once despite a second tap, follows it and returns the acquired publication's id. */
    private fun requestUntilReady(format: String, ready: String): String {
        waitForText("Find")
        compose.onAllNodesWithText("Find").onLast().performClick()
        compose.waitUntil(20_000) { compose.onAllNodes(hasTestTag("find-query")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("find-query").performTextInput("light")
        compose.onNodeWithTag("find-submit").performClick()
        waitForText("The Lighthouse Keeper")
        capture("find-results.png")
        compose.onNodeWithTag("result:fx:lighthouse").performClick()
        waitForText("Choose a format")
        compose.onNodeWithTag("format:$format").performClick()
        compose.onNodeWithTag("request-submit").performClick()
        runCatching { compose.onNodeWithTag("request-submit").performClick() }
        compose.waitUntil(20_000) { compose.onAllNodes(hasTestTag("request-stage")).fetchSemanticsNodes().isNotEmpty() }
        assertEquals(1, fixture.createRequests.get())
        waitForText(ready, timeoutMs = 60_000)
        assertEquals("one request per submit", 1, fixture.createRequests.get())
        capture("request-ready-$format.png")
        return requireNotNull(fixture.acquired) { "no publication was acquired" }
    }

    private fun evidence(line: String) = android.util.Log.i("FindRequestEvidence", line)

    private fun shown(description: String) = compose.onAllNodes(hasContentDescription(description)).fetchSemanticsNodes().isNotEmpty()

    /** Waits on the UI, failing at once on a screen that says there is nothing to open. */
    private fun awaitUi(description: String, timeoutMs: Long = 20_000, condition: () -> Boolean) {
        try {
            compose.waitUntil(timeoutMs) {
                for (refusal in listOf("Nothing to play", "Playback stopped")) {
                    if (compose.onAllNodesWithText(refusal, substring = true).fetchSemanticsNodes().isNotEmpty()) {
                        throw AssertionError("\"$refusal\" shown while waiting for $description")
                    }
                }
                container.playback.snapshot.value.problem?.let { throw AssertionError("Playback problem $it while waiting for $description") }
                condition()
            }
        } catch (timeout: ComposeTimeoutException) {
            throw AssertionError("Timed out waiting for $description; playback ${container.playback.snapshot.value}", timeout)
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

    // The reader is its own activity, started by the app rather than by this test.

    private fun resumedReader(): ReaderActivity? {
        var found: ReaderActivity? = null
        instrumentation.runOnMainSync {
            found = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<ReaderActivity>().firstOrNull()
        }
        return found
    }

    private fun awaitReader(previous: ReaderActivity?): ReaderActivity {
        awaitCondition("the reader opened") { resumedReader()?.takeIf { it !== previous } != null }
        return resumedReader()!!
    }

    private fun finishReaders() {
        instrumentation.runOnMainSync {
            Stage.values().flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }
                .filterIsInstance<ReaderActivity>().forEach { it.finish() }
        }
    }

    private fun navigator(reader: ReaderActivity) = reader.supportFragmentManager.findFragmentById(R.id.reader_navigator) as? EpubNavigatorFragment

    private fun shown(reader: ReaderActivity): Locator? {
        val found = AtomicReference<Locator?>()
        instrumentation.runOnMainSync { found.set(navigator(reader)?.currentLocator?.value) }
        return found.get()
    }

    private fun place(locator: Locator) = ApiJson.parseToJsonElement(locator.toJSON().toString())

    private fun visibleParagraphs(reader: ReaderActivity): String = evaluate(reader, VISIBLE_PARAGRAPHS)

    private fun awaitText(reader: ReaderActivity, text: String) =
        awaitCondition("EPUB text: $text") { evaluate(reader, "document.body ? document.body.innerText : ''").contains(text) }

    private fun evaluate(reader: ReaderActivity, script: String): String {
        val views = mutableListOf<WebView>()
        instrumentation.runOnMainSync { collectWebViews(reader.window.decorView, views) }
        return views.firstNotNullOfOrNull { view ->
            val result = AtomicReference<String>()
            val done = CountDownLatch(1)
            instrumentation.runOnMainSync { view.evaluateJavascript(script) { result.set(it); done.countDown() } }
            if (done.await(2, TimeUnit.SECONDS)) result.get()?.takeIf { it != "null" && it != "\"\"" && it != "\"[]\"" } else null
        }.orEmpty()
    }

    private fun collectWebViews(view: View, found: MutableList<WebView>) {
        if (view is WebView && view.isShown && view.alpha > 0 && view.getGlobalVisibleRect(Rect())) found += view
        if (view is ViewGroup) for (index in 0 until view.childCount) collectWebViews(view.getChildAt(index), found)
    }

    /** Waits for the reader window to have input focus, so nothing else (a system hint) takes the key. */
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

    private fun awaitCondition(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
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
            instrumentation.waitForIdleSync()
            val image = instrumentation.uiAutomation.takeScreenshot() ?: return@awaitCondition false
            val ok = textRows(image) >= MIN_TEXT_ROWS
            if (ok) shown = image else image.recycle()
            ok
        }
        val bitmap = requireNotNull(shown)
        try {
            val directory = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir")?.let(::File) ?: return
            check(directory.isDirectory || directory.mkdirs()) { "Cannot create test output directory" }
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
        /** A page of the fixture's text inks well over half of its rows; "Opening…" inks about 3%. */
        const val MIN_TEXT_ROWS = 0.3
        const val VISIBLE_PARAGRAPHS =
            """JSON.stringify(Array.from(document.querySelectorAll('p[id]')).filter(p => { const r = p.getBoundingClientRect(); return r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight; }).map(p => p.id))"""
    }
}
