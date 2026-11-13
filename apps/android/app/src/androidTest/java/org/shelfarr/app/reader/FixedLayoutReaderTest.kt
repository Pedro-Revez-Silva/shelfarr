package org.shelfarr.app.reader

import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.CRC32
import java.util.zip.Deflater
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Headers
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.CBZ_MEDIA_TYPE
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.PDF_MEDIA_TYPE
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressUpdate
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.READER_FORMATS_HEADER
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.core.ReadingOrder
import org.shelfarr.app.core.ReadingOrderItem
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session

/**
 * PDF and CBZ on a real device: the platform PdfRenderer and image decoder, the real
 * Activity, HTTP, cache and download paths. Fixture files are drawn here; no personal media.
 */
@RunWith(AndroidJUnit4::class)
class FixedLayoutReaderTest {
    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val bands = intArrayOf(Color.rgb(211, 47, 47), Color.rgb(21, 101, 192), Color.rgb(46, 125, 50))
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private var confirmations: String? = null

    /**
     * Hiding the bars shows Android's one-time "Viewing full screen" hint until someone
     * taps Got it. From Android 15 that system window takes input focus, so a key pressed
     * while it is up never reaches the reader. A reader who has seen it once never sees it
     * again; this fixture emulator never taps it, so it is marked as seen and put back after.
     */
    @Before
    fun markFullScreenHintSeen() {
        confirmations = shell("settings get secure $FULL_SCREEN_HINT").trim()
        shell("settings put secure $FULL_SCREEN_HINT confirmed")
    }

    @After
    fun restoreFullScreenHint() {
        val previous = confirmations
        if (previous.isNullOrEmpty() || previous == "null") shell("settings delete secure $FULL_SCREEN_HINT")
        else shell("settings put secure $FULL_SCREEN_HINT $previous")
    }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use {
            it.readBytes().decodeToString()
        }

    private class Fixture(val web: MockWebServer, val writes: CopyOnWriteArrayList<ProgressUpdate>, val session: Session)

    private fun serve(token: String, publications: Map<String, Publication>, files: Map<String, Pair<ByteArray, String>>, orders: Map<String, ReadingOrder> = emptyMap()): Fixture {
        val saved = HashMap<String, Progress?>()
        publications.forEach { (id, publication) -> saved[id] = publication.progress }
        val writes = CopyOnWriteArrayList<ProgressUpdate>()
        val web = MockWebServer()
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer $token") return MockResponse.Builder().code(401).build()
                val path = request.target.substringBefore('?')
                if (path == "/api/consumer/v1/me") return json(ApiJson.encodeToString(Me(token)))
                files[path]?.let { (bytes, type) ->
                    return MockResponse.Builder().code(200).headers(Headers.headersOf("ETag", "\"${bytes.size}\"", "Content-Type", type))
                        .body(Buffer().write(bytes)).build()
                }
                orders[path]?.let { return json(ApiJson.encodeToString(it)) }
                val id = path.removePrefix("/api/consumer/v1/library/").substringBefore('/')
                val publication = publications[id] ?: return MockResponse.Builder().code(404).build()
                return when {
                    path.endsWith("/progress") -> synchronized(saved) {
                        val update = ApiJson.decodeFromString<ProgressUpdate>(request.body!!.utf8())
                        writes += update
                        val progress = Progress(update.assetId, update.locator, null, (saved[id]?.version ?: 0) + 1,
                            clientMutationId = update.clientMutationId, observedAt = update.observedAt)
                        saved[id] = progress
                        json("{\"progress\":${ApiJson.encodeToString(progress)}}")
                    }
                    // Only a client that declares the formats is offered PDF and CBZ files.
                    request.headers[READER_FORMATS_HEADER] != "epub,pdf,cbz" -> json(ApiJson.encodeToString(publication.copy(assets = emptyList())))
                    else -> json(ApiJson.encodeToString(publication.copy(progress = synchronized(saved) { saved[id] })))
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me(token), token)
        app.container.sessions.signIn(session)
        return Fixture(web, writes, session)
    }

    private fun cleanUp(fixture: Fixture) {
        runBlocking {
            app.container.currentAccount()?.let { account ->
                account.close()
                account.directory.deleteRecursively()
            }
            app.container.epubCache.clear(fixture.session.accountKey)
        }
        app.container.sessions.clear()
        runCatching { fixture.web.close() }
    }

    private fun pdfPublication(bytes: ByteArray, progress: Progress? = null) = Publication(
        id = "pdf-book", title = "PDF smoke", bookType = BookType.EBOOK, progress = progress,
        assets = listOf(Asset("pdf-1", "smoke.pdf", PDF_MEDIA_TYPE, "pdf", bytes.size.toLong(), "/files/pdf")),
    )

    @Test
    fun rendersTurnsSavesRotatesAndSilentlyReopensAPdf() {
        val pdf = pdf()
        val fixture = serve("pdf-smoke", mapOf("pdf-book" to pdfPublication(pdf)), mapOf("/files/pdf" to (pdf to PDF_MEDIA_TYPE)))
        val openedAt = System.currentTimeMillis()
        try {
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "pdf-book")).use { scenario ->
                awaitPaged(scenario, ReadingFormat.PDF, page = 0)
                awaitBand(scenario, 0, "pdf-page-one.png")
                // A real hardware key, through the Activity, as a keyboard reader would turn.
                press(scenario, KeyEvent.KEYCODE_PAGE_DOWN)
                awaitPaged(scenario, ReadingFormat.PDF, page = 1)
                awaitBand(scenario, 1, "pdf-page-two.png")
                await("page two reached the server") { fixture.writes.isNotEmpty() }
                val write = fixture.writes.last()
                assertEquals("pdf-1", write.assetId)
                assertEquals("document.pdf", write.locator!!["href"]!!.jsonPrimitive.content)
                assertEquals("application/pdf", write.locator!!["type"]!!.jsonPrimitive.content)
                assertEquals(2, write.locator!!["locations"]!!.jsonObject["position"]!!.jsonPrimitive.content.toInt())
                val reached = requireNotNull(ActivityTime.parse(write.observedAt))
                assertTrue("observed at $reached, opened at $openedAt", reached in openedAt..System.currentTimeMillis())

                // A rotation rebuilds everything on the same page and writes nothing.
                val beforeRotation = fixture.writes.size
                scenario.recreate()
                awaitPaged(scenario, ReadingFormat.PDF, page = 1)
                awaitBand(scenario, 1, "pdf-page-two-recreated.png")
                SystemClock.sleep(6_000)
                assertEquals("recreating sent ${fixture.writes.drop(beforeRotation)}", beforeRotation, fixture.writes.size)
            }
            val beforeReopen = fixture.writes.size
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "pdf-book")).use { scenario ->
                awaitPaged(scenario, ReadingFormat.PDF, page = 1)
                awaitBand(scenario, 1, "pdf-page-two-resumed.png")
                SystemClock.sleep(6_000)
            }
            SystemClock.sleep(1_000)
            assertEquals("reopening sent ${fixture.writes.drop(beforeReopen)}", beforeReopen, fixture.writes.size)
        } finally {
            cleanUp(fixture)
        }
    }

    @Test
    fun keepsAnImpossibleSavedPdfPlaceUntilTheReaderTurnsAPage() {
        val pdf = pdf()
        val impossible = Progress("pdf-1", buildJsonObject {
            put("href", "document.pdf")
            put("type", "application/pdf")
            putJsonObject("locations") { put("position", 40) }
        }, version = 3, observedAt = "2026-11-01T10:00:00.000Z")
        val fixture = serve("pdf-invalid", mapOf("pdf-book" to pdfPublication(pdf, impossible)), mapOf("/files/pdf" to (pdf to PDF_MEDIA_TYPE)))
        try {
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "pdf-book")).use { scenario ->
                val state = awaitPaged(scenario, ReadingFormat.PDF, page = 0)
                assertNotNull("The reader is asked where to look", state.invalidPlace)
                // The choice is a dialog in its own window: read it from what is on screen and
                // photograph the whole display, not only the reader's window beneath it.
                listOf(
                    "Your saved place isn't in this file",
                    "Your place was saved at page 40, but this PDF has 3 pages.",
                    "Your saved place is kept until you turn a page.",
                    "Start at page 1",
                    "Go to page 3",
                ).forEach(::awaitOnScreen)
                screen("pdf-invalid-place.png")
                SystemClock.sleep(6_000)
                assertTrue("Nothing replaced the saved place", fixture.writes.isEmpty())
                // Choosing where to look, with a real tap on the choice, is not reading either.
                tap(requireNotNull(onScreen("Go to page 3")))
                await("the choice to close") { onScreen("Your saved place isn't in this file") == null }
                awaitPaged(scenario, ReadingFormat.PDF, page = 2)
                awaitBand(scenario, 2, "pdf-invalid-place-last-page.png")
                SystemClock.sleep(6_000)
                assertTrue(fixture.writes.isEmpty())
                // An actual page turn is, and it replaces the impossible place.
                press(scenario, KeyEvent.KEYCODE_PAGE_UP)
                await("the turn reached the server") { fixture.writes.isNotEmpty() }
                assertEquals(2, fixture.writes.last().locator!!["locations"]!!.jsonObject["position"]!!.jsonPrimitive.content.toInt())
            }
        } finally {
            cleanUp(fixture)
        }
    }

    @Test
    fun downloadsAComicAndAPdfThenReadsBothOffline() {
        val pdf = pdf()
        val comic = comic()
        val orderPath = "/api/consumer/v1/library/comic-book/assets/cbz-1/reading_order"
        val comicBook = Publication(
            id = "comic-book", title = "Comic smoke", bookType = BookType.EBOOK, contentKind = "graphic",
            assets = listOf(Asset("cbz-1", "smoke.cbz", CBZ_MEDIA_TYPE, "cbz", comic.first.size.toLong(), "/files/cbz",
                pageCount = comic.second.size, readingOrderUrl = orderPath)),
        )
        val fixture = serve(
            "comic-smoke",
            mapOf("comic-book" to comicBook, "pdf-book" to pdfPublication(pdf)),
            mapOf("/files/cbz" to (comic.first to CBZ_MEDIA_TYPE), "/files/pdf" to (pdf to PDF_MEDIA_TYPE)),
            mapOf(orderPath to ReadingOrder("cbz-1", "cbz", comic.second)),
        )
        try {
            val downloads = requireNotNull(app.container.currentAccount()).downloads
            runBlocking {
                downloads.enqueue(comicBook)
                downloads.enqueue(pdfPublication(pdf))
            }
            await("both downloads are ready") { downloads.ready("comic-book") != null && downloads.ready("pdf-book") != null }
            assertNotNull(downloads.readingOrderFor(downloads.ready("comic-book")!!, "cbz-1"))
            // No server from here on.
            fixture.web.close()

            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "comic-book")).use { scenario ->
                awaitPaged(scenario, ReadingFormat.CBZ, page = 0)
                scenario.onActivity { assertEquals(ReaderSource.DOWNLOAD, viewModel(it).fileSource) }
                awaitBand(scenario, 0, "comic-offline-page-one.png")
                press(scenario, KeyEvent.KEYCODE_PAGE_DOWN)
                awaitPaged(scenario, ReadingFormat.CBZ, page = 1)
                awaitBand(scenario, 1, "comic-offline-page-two.png")
            }
            // The page is kept on the device, in the comic's own terms, until the server is back.
            val local = runBlocking { requireNotNull(app.container.currentAccount()).progress.sync("comic-book").snapshot() }
            assertEquals(comic.second[1].href, local.position!!.locator!!["href"]!!.jsonPrimitive.content)
            assertEquals(2, local.position!!.locator!!["locations"]!!.jsonObject["position"]!!.jsonPrimitive.content.toInt())
            assertTrue(local.hasUnsyncedChanges)

            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "pdf-book")).use { scenario ->
                awaitPaged(scenario, ReadingFormat.PDF, page = 0)
                scenario.onActivity { assertEquals(ReaderSource.DOWNLOAD, viewModel(it).fileSource) }
                awaitBand(scenario, 0, "pdf-offline-download.png")
            }
        } finally {
            cleanUp(fixture)
        }
    }

    @Test
    fun aComicPageThatCantBeShownKeepsThePlaceAndTheNextKeyGoesPastIt() {
        val comic = comic(damaged = 1)
        val orderPath = "/api/consumer/v1/library/comic-book/assets/cbz-1/reading_order"
        val comicBook = Publication(
            id = "comic-book", title = "Damaged comic", bookType = BookType.EBOOK, contentKind = "graphic",
            assets = listOf(Asset("cbz-1", "damaged.cbz", CBZ_MEDIA_TYPE, "cbz", comic.first.size.toLong(), "/files/cbz",
                pageCount = comic.second.size, readingOrderUrl = orderPath)),
        )
        val fixture = serve(
            "comic-damaged",
            mapOf("comic-book" to comicBook),
            mapOf("/files/cbz" to (comic.first to CBZ_MEDIA_TYPE)),
            mapOf(orderPath to ReadingOrder("cbz-1", "cbz", comic.second)),
        )
        try {
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "comic-book")).use { scenario ->
                awaitPaged(scenario, ReadingFormat.CBZ, page = 0)
                awaitBand(scenario, 0, "comic-damaged-page-one.png")
                // Page Down onto the damaged page: the reader is there, but it was never seen.
                press(scenario, KeyEvent.KEYCODE_PAGE_DOWN)
                awaitPaged(scenario, ReadingFormat.CBZ, page = 1)
                SystemClock.sleep(1_500)
                screenshot(scenario, "comic-damaged-page-two.png")
                scenario.onActivity { viewModel(it).flush() }
                SystemClock.sleep(6_000)
                assertTrue("The damaged page reached the server: ${fixture.writes}", fixture.writes.isEmpty())
                val kept = runBlocking { requireNotNull(app.container.currentAccount()).progress.sync("comic-book").snapshot() }
                assertTrue("The damaged page was saved locally: ${kept.position}", kept.position == null)

                // Page Down again turns from the page on screen, past the damaged one.
                val before = System.currentTimeMillis()
                press(scenario, KeyEvent.KEYCODE_PAGE_DOWN)
                awaitPaged(scenario, ReadingFormat.CBZ, page = 2)
                awaitBand(scenario, 2, "comic-damaged-page-three.png")
                await("page three reached the server") { fixture.writes.isNotEmpty() }
                val write = fixture.writes.single()
                assertEquals(comic.second[2].href, write.locator!!["href"]!!.jsonPrimitive.content)
                assertEquals(3, write.locator!!["locations"]!!.jsonObject["position"]!!.jsonPrimitive.content.toInt())
                val seen = requireNotNull(ActivityTime.parse(write.observedAt))
                assertTrue("seen at $seen, turned at $before", seen in before..System.currentTimeMillis())
            }
        } finally {
            cleanUp(fixture)
        }
    }

    private fun viewModel(activity: ReaderActivity) = ViewModelProvider(activity)[ReaderViewModel::class.java]

    /**
     * A hardware key goes to the window with input focus. Wait until that is the reader
     * (not a dialog closing or a system window) and then press it, as a keyboard would.
     */
    private fun press(scenario: ActivityScenario<ReaderActivity>, keyCode: Int) {
        await("the reader window to have input focus before ${KeyEvent.keyCodeToString(keyCode)}") {
            var focused = false
            scenario.onActivity { focused = it.hasWindowFocus() }
            focused
        }
        instrumentation.sendKeyDownUpSync(keyCode)
    }

    private fun awaitPaged(scenario: ActivityScenario<ReaderActivity>, format: ReadingFormat, page: Int): ReaderState.Paged {
        val found = AtomicReference<ReaderState.Paged>()
        await("a $format reader on page ${page + 1}") {
            var ok = false
            scenario.onActivity { activity ->
                val model = viewModel(activity)
                val state = model.state.value
                if (state is ReaderState.Paged && state.format == format && model.page.value == page) {
                    found.set(state)
                    ok = true
                }
                if (state is ReaderState.Failed || state is ReaderState.Damaged) throw AssertionError("Reader failed: $state")
            }
            ok
        }
        return found.get()
    }

    /** The page's coloured band is really on screen, drawn by the platform renderer. */
    private fun awaitBand(scenario: ActivityScenario<ReaderActivity>, page: Int, name: String) {
        var shown: Bitmap? = null
        await("page ${page + 1}'s band on screen for $name") {
            val image = captureWindow(scenario) ?: return@await false
            val ok = countNear(image, bands[page]) > 2_000 && bands.indices.filter { it != page }.all { countNear(image, bands[it]) < 200 }
            if (ok) shown = image else image.recycle()
            ok
        }
        save(requireNotNull(shown), name)
    }

    private fun screenshot(scenario: ActivityScenario<ReaderActivity>, name: String) {
        var shown: Bitmap? = null
        await("a window for $name") { captureWindow(scenario)?.also { shown = it } != null }
        save(requireNotNull(shown), name)
    }

    /** The whole display, dialogs and system windows included, once the UI is idle. */
    private fun screen(name: String) {
        instrumentation.waitForIdleSync()
        runCatching { instrumentation.uiAutomation.waitForIdle(500, 10_000) }
        save(requireNotNull(instrumentation.uiAutomation.takeScreenshot()) { "No screenshot for $name" }, name)
    }

    /** A node showing exactly [text] to the user, in any window on screen. */
    private fun onScreen(text: String): AccessibilityNodeInfo? = shownNodes().firstOrNull { it.text?.toString() == text }

    private fun awaitOnScreen(text: String) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (onScreen(text) != null) return
            SystemClock.sleep(150)
        }
        assertNotNull("\"$text\" on screen; showing ${shownNodes().mapNotNull { it.text?.toString() }.toList()}", onScreen(text))
    }

    /**
     * Every node visible to the user, walked window by window. Compose draws its nodes as
     * virtual views, which the platform's search by text does not reach.
     */
    private fun shownNodes(): Sequence<AccessibilityNodeInfo> {
        val automation = instrumentation.uiAutomation
        val info = automation.serviceInfo
        if (info.flags and AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS == 0) {
            automation.serviceInfo = info.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
        }
        val roots = automation.windows.mapNotNull { it.root }.ifEmpty { listOfNotNull(automation.rootInActiveWindow) }
        return sequence {
            val pending = ArrayDeque(roots)
            while (pending.isNotEmpty()) {
                val node = pending.removeFirst()
                if (node.isVisibleToUser) yield(node)
                for (index in 0 until node.childCount) node.getChild(index)?.let(pending::addLast)
            }
        }
    }

    /** A finger on the middle of [node], through the input system, as a reader would tap it. */
    private fun tap(node: AccessibilityNodeInfo) {
        val bounds = Rect().also(node::getBoundsInScreen)
        val x = bounds.exactCenterX()
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

    private fun save(bitmap: Bitmap, name: String) {
        try {
            val output = requireNotNull(InstrumentationRegistry.getArguments().getString("additionalTestOutputDir"))
            val folder = File(output)
            check(folder.isDirectory || folder.mkdirs()) { "Cannot create test output directory" }
            File(folder, name).outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally {
            bitmap.recycle()
        }
    }

    private fun countNear(image: Bitmap, color: Int): Int {
        var count = 0
        for (y in 0 until image.height step 3) for (x in 0 until image.width step 3) {
            val pixel = image.getPixel(x, y)
            if (kotlin.math.abs(Color.red(pixel) - Color.red(color)) < 30 && kotlin.math.abs(Color.green(pixel) - Color.green(color)) < 30 &&
                kotlin.math.abs(Color.blue(pixel) - Color.blue(color)) < 30
            ) count++
        }
        return count
    }

    private fun captureWindow(scenario: ActivityScenario<ReaderActivity>): Bitmap? {
        var bitmap: Bitmap? = null
        val result = AtomicInteger(-1)
        val copied = CountDownLatch(1)
        scenario.onActivity { activity ->
            val view = activity.window.decorView
            val image = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            bitmap = image
            PixelCopy.request(activity.window, image, { code -> result.set(code); copied.countDown() }, Handler(Looper.getMainLooper()))
        }
        if (copied.await(3, TimeUnit.SECONDS) && result.get() == PixelCopy.SUCCESS) return bitmap
        bitmap?.recycle()
        return null
    }

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(150)
        }
        assertTrue("Timed out waiting for $description", condition())
    }

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    /** Three letter-size pages, each with its own coloured band, written by the platform's PdfDocument. */
    private fun pdf(): ByteArray {
        val document = PdfDocument()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        bands.forEachIndexed { index, color ->
            val page = document.startPage(PdfDocument.PageInfo.Builder(612, 792, index + 1).create())
            page.canvas.drawColor(Color.WHITE)
            paint.color = color
            page.canvas.drawRect(0f, 0f, 612f, 300f, paint)
            paint.color = Color.BLACK
            paint.textSize = 40f
            page.canvas.drawText("Fixture page ${index + 1}", 60f, 380f, paint)
            document.finishPage(page)
        }
        return ByteArrayOutputStream().also { document.writeTo(it); document.close() }.toByteArray()
    }

    /**
     * A ZIP32 comic, written byte by byte, with the reading order the server would describe.
     * With [damaged], that page's stored bytes no longer match its checksum: the comic opens,
     * but that one page can't be shown.
     */
    private fun comic(damaged: Int? = null): Pair<ByteArray, List<ReadingOrderItem>> {
        val pages = bands.mapIndexed { index, color ->
            val bitmap = Bitmap.createBitmap(600, 900, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(color)
            val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            // Named so the server's natural order is this order; one escaped name, one stored page.
            Triple(if (index == 1) "02 spread/page.png" else "0${index + 1}.png", bytes, if (index == 1) 0 else 8)
        }
        val out = ByteArrayOutputStream()
        fun le(value: Long, size: Int) = out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array(), 0, size)
        val entries = pages.map { (name, data, method) ->
            val offset = out.size().toLong()
            val payload = if (method == 8) Deflater(Deflater.DEFAULT_COMPRESSION, true).run {
                setInput(data); finish()
                val buffer = ByteArrayOutputStream(); val chunk = ByteArray(8192)
                while (!finished()) buffer.write(chunk, 0, deflate(chunk))
                end(); buffer.toByteArray()
            } else data
            val crc = CRC32().apply { update(data) }.value
            val nameBytes = name.toByteArray()
            le(0x04034b50, 4); le(20, 2); le(0, 2); le(method.toLong(), 2); le(0, 4); le(crc, 4)
            le(payload.size.toLong(), 4); le(data.size.toLong(), 4); le(nameBytes.size.toLong(), 2); le(0, 2)
            out.write(nameBytes); out.write(payload)
            listOf(name, offset, crc, payload.size.toLong(), data.size.toLong(), method)
        }
        val directory = out.size().toLong()
        entries.forEach { (name, offset, crc, compressed, size, method) ->
            val nameBytes = (name as String).toByteArray()
            le(0x02014b50, 4); le(20, 2); le(20, 2); le(0, 2); le((method as Int).toLong(), 2); le(0, 4)
            le(crc as Long, 4); le(compressed as Long, 4); le(size as Long, 4); le(nameBytes.size.toLong(), 2)
            le(0, 2); le(0, 2); le(0, 2); le(0, 2); le(0, 4); le(offset as Long, 4); out.write(nameBytes)
        }
        val directorySize = out.size() - directory
        le(0x06054b50, 4); le(0, 4); le(entries.size.toLong(), 2); le(entries.size.toLong(), 2)
        le(directorySize, 4); le(directory, 4); le(0, 2)
        val items = entries.mapIndexed { index, (name, offset, crc, compressed, size, method) ->
            ReadingOrderItem(
                position = index + 1,
                href = (name as String).toByteArray().joinToString("") { byte ->
                    val char = (byte.toInt() and 0xff).toChar()
                    if (char.code < 128 && (char.isLetterOrDigit() || char in "-._~/")) char.toString() else "%%%02X".format(byte.toInt() and 0xff)
                },
                mediaType = "image/png",
                sizeBytes = size as Long,
                compressedSize = compressed as Long,
                compressionMethod = method as Int,
                localHeaderOffset = offset as Long,
                crc32 = "%08x".format(crc as Long),
            )
        }
        val bytes = out.toByteArray()
        if (damaged != null) {
            val item = items[damaged]
            check(item.compressionMethod == 0) { "Only a stored page is damaged byte for byte" }
            val name = Uri.decode(item.href).toByteArray()
            val at = (item.localHeaderOffset + 30 + name.size + 100).toInt()
            bytes[at] = (bytes[at] + 1).toByte()
        }
        return bytes to items
    }
}

private operator fun <T> List<T>.component6(): T = this[5]

private const val FULL_SCREEN_HINT = "immersive_mode_confirmations"
