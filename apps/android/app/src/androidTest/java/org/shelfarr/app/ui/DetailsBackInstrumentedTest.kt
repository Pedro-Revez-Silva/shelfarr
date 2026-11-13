package org.shelfarr.app.ui

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.KeyEvent
import androidx.activity.BackEventCompat
import androidx.compose.ui.test.SemanticsNodeInteractionCollection
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContinueList
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.ui.theme.AppearanceMode

/**
 * Home → details → Back in the real app, read from what the display actually shows.
 *
 * Home's shelves hold books whose generated covers share one cloth colour; the opened
 * book has another, and its details screen has the accent button. A screenshot that
 * holds both Home's cloth and that button shows details drawn over Home, as a person
 * saw it while holding Back. Back is held the way Android sends it (started, progress,
 * then released or abandoned), pressed as a key, and tapped in the app.
 */
@RunWith(AndroidJUnit4::class)
class DetailsBackInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container
    private val web = MockWebServer()
    private var appearance = AppearanceMode.SYSTEM

    private val epub = Asset("detail-epub", "d.epub", "application/epub+zip", "epub", 2_000, "/files/epub")
    private val opened = Publication(
        id = "detail-book", title = "Fixture detail book", author = "Fixture Author",
        bookType = BookType.EBOOK, assets = listOf(epub),
    )

    // These ids give the same generated cover colour (see coverSwatchIndex), unlike [opened].
    private val shelf = listOf("shelf-3", "shelf-5", "shelf-10", "shelf-16", "shelf-21", "shelf-27").mapIndexed { index, id ->
        Publication(id, "Shelf book ${index + 1}", "Fixture Author", bookType = BookType.EBOOK, assets = listOf(epub.copy(id = "$id-epub")))
    }

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer details-back-fixture") return MockResponse.Builder().code(401).build()
                return when (request.target.substringBefore('?')) {
                    "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me("details-back-fixture")))
                    "/api/consumer/v1/continue" -> json(ApiJson.encodeToString(ContinueList()))
                    "/api/consumer/v1/library" -> json(ApiJson.encodeToString(LibraryPage(listOf(opened) + shelf)))
                    // Details arrive late, so each visit opens on the loading state first.
                    "/api/consumer/v1/library/detail-book" ->
                        json(ApiJson.encodeToString(opened), delayMs = 400)
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        appearance = container.appearance.value
        container.setAppearance(AppearanceMode.DARK)
        container.askedForNotifications = true
        container.sessions.signIn(Session(server, Me("details-back-fixture"), "details-back-fixture"))
    }

    @After
    fun tearDown() {
        runBlocking {
            container.currentAccount()?.let { account ->
                account.close()
                account.directory.deleteRecursively()
            }
        }
        container.sessions.clear()
        container.setAppearance(appearance)
        runCatching { web.close() }
    }

    @Test
    fun heldBackPressAndAppBackNeverDrawDetailsOverHome() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            openDetails()
            val held = mutableListOf(shot("held-0-details"))
            scenario.onActivity { it.onBackPressedDispatcher.dispatchOnBackStarted(gesture(0f)) }
            for (progress in listOf(0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f, 0.9f)) {
                scenario.onActivity { it.onBackPressedDispatcher.dispatchOnBackProgressed(gesture(progress)) }
                compose.waitForIdle()
                held += shot("held-${(progress * 100).toInt()}")
            }
            held += stepped("held-released") { scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() } }
            assertNeverOverlaid("held Back", held)
            onHome()

            openDetails()
            val cancelled = mutableListOf(shot("cancelled-0-details"))
            scenario.onActivity { it.onBackPressedDispatcher.dispatchOnBackStarted(gesture(0f)) }
            for (progress in listOf(0.2f, 0.4f, 0.6f, 0.8f)) {
                scenario.onActivity { it.onBackPressedDispatcher.dispatchOnBackProgressed(gesture(progress)) }
                compose.waitForIdle()
                cancelled += shot("cancelled-${(progress * 100).toInt()}")
            }
            cancelled += stepped("cancelled-abandoned") { scenario.onActivity { it.onBackPressedDispatcher.dispatchOnBackCancelled() } }
            assertNeverOverlaid("abandoned held Back", cancelled)
            waitForText("Start reading")

            val key = mutableListOf(shot("key-0-details"))
            key += stepped("key-pressed") { instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK) }
            assertNeverOverlaid("Back key", key)
            onHome()

            // Back while details is still loading and fading in.
            val quick = stepped("quick-key") {
                compose.onAllNodesWithText(opened.title)[0].performClick()
                repeat(6) { compose.mainClock.advanceTimeByFrame() }
                instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            }
            assertTrue("quick Back drew details over Home", quick.none { it.overlaid })
            onHome()

            openDetails()
            val button = mutableListOf(shot("app-0-details"))
            button += stepped("app-back") { compose.onAllNodesWithContentDescription("Back")[0].performClick() }
            assertNeverOverlaid("the app's Back button", button)
            onHome()
        }
    }

    // ---- Driving ----

    private fun gesture(progress: Float) = BackEventCompat(8f, 1200f, progress, BackEventCompat.EDGE_LEFT)

    private fun openDetails() {
        waitForText(opened.title)
        compose.onAllNodesWithText(opened.title)[0].performClick()
        waitForText("Start reading")
        compose.waitForIdle()
        // The opening fade-in has run its course once the screen shows only details.
        awaitShot("details settled", onDetailsOnly)
    }

    private fun onHome() {
        waitForText("Shelf book 1")
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Start reading").fetchSemanticsNodes().isEmpty() }
        awaitShot("Home settled", onHomeOnly)
    }

    private fun waitForText(text: String) =
        compose.waitUntil(20_000) { compose.onAllNodesWithText(text).exists() }

    private fun SemanticsNodeInteractionCollection.exists() = fetchSemanticsNodes().isNotEmpty()

    // ---- What the display shows ----

    private data class Frame(val name: String, val home: Int, val details: Int) {
        val overlaid get() = home > VISIBLE && details > VISIBLE
    }

    /**
     * The composited display, between Home's wordmark and the bottom bars, which are
     * drawn in the accent too.
     */
    private fun shot(name: String): Frame {
        val raw = requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "No screenshot" }
        val bitmap = raw.copy(Bitmap.Config.ARGB_8888, false)
        val top = (bitmap.height * 0.12f).toInt()
        val height = (bitmap.height * 0.8f).toInt() - top
        val pixels = IntArray(bitmap.width * height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, top, bitmap.width, height)
        var home = 0
        var details = 0
        for (pixel in pixels) {
            if (near(pixel, HOME_CLOTH)) home++
            if (near(pixel, ACCENT)) details++
        }
        val frame = Frame(name, home, details)
        save(frame, bitmap)
        return frame
    }

    /**
     * Runs [action], then steps the test's frame clock (which drives the app's animations
     * under test) one frame at a time, capturing the display after each frame.
     */
    private fun stepped(name: String, action: () -> Unit): List<Frame> {
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        try {
            action()
            return List(STEPS) { index ->
                compose.mainClock.advanceTimeByFrame()
                compose.waitForIdle()
                instrumentation.waitForIdleSync()
                shot("$name-$index")
            }
        } finally {
            compose.mainClock.autoAdvance = true
            compose.waitForIdle()
        }
    }

    private val onHomeOnly: (Frame) -> Boolean = { it.home > VISIBLE && it.details == 0 }
    private val onDetailsOnly: (Frame) -> Boolean = { it.details > VISIBLE && it.home == 0 }

    private fun awaitShot(description: String, condition: (Frame) -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        var last: Frame
        do {
            last = shot("await")
            if (condition(last)) return
        } while (SystemClock.uptimeMillis() < deadline)
        throw AssertionError("Timed out waiting for $description: $last")
    }

    private fun near(pixel: Int, colour: Int): Boolean =
        Math.abs(((pixel shr 16) and 0xFF) - ((colour shr 16) and 0xFF)) <= TOLERANCE &&
            Math.abs(((pixel shr 8) and 0xFF) - ((colour shr 8) and 0xFF)) <= TOLERANCE &&
            Math.abs((pixel and 0xFF) - (colour and 0xFF)) <= TOLERANCE

    private fun assertNeverOverlaid(name: String, frames: List<Frame>) {
        val summary = frames.joinToString(" ") { "${it.name}:h${it.home}/d${it.details}" }
        val overlaid = frames.filter { it.overlaid }
        assertTrue("$name drew details over Home in ${overlaid.size} screenshot(s)\n$summary", overlaid.isEmpty())
        assertTrue("$name: details never showed\n$summary", frames.any { it.details > VISIBLE })
        assertTrue("$name: Home never showed\n$summary", frames.any { it.home > VISIBLE })
    }

    private var saved = 0

    private fun save(frame: Frame, bitmap: Bitmap) {
        if (frame.name == "await") return
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir") ?: return
        val folder = File(output, "details-back")
        if (!folder.isDirectory && !folder.mkdirs()) return
        val file = File(folder, "%03d-%s-h%d-d%d.png".format(saved++, frame.name, frame.home, frame.details))
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun json(body: String, delayMs: Long = 0) = MockResponse.Builder()
        .code(200)
        .addHeader("Content-Type", "application/json")
        .body(body)
        .headersDelay(delayMs, TimeUnit.MILLISECONDS)
        .build()

    private companion object {
        /** The dark theme's accent, which details' primary button is drawn in. */
        const val ACCENT = 0xEE9270
        /** The generated cover cloth shared by Home's shelf books (CoverSwatches[1]). */
        const val HOME_CLOTH = 0x3F4A30
        const val TOLERANCE = 8
        const val VISIBLE = 2_000
        const val STEPS = 40
    }
}
