package org.shelfarr.app.reader

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Headers
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.shelfarr.app.R
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressUpdate
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.ui.player.PlayerState
import org.shelfarr.app.ui.player.PlayerViewModel

/** Exercises the real Activity, HTTP/cache path and WebView, beyond ZIP parsing. */
@RunWith(AndroidJUnit4::class)
class ReaderSmokeTest {
    @Test
    fun rendersNavigatesSavesAndReopensAnEpub() {
        val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
        val epub = epub()
        val saved = AtomicReference<Progress?>(null)
        val writes = java.util.concurrent.CopyOnWriteArrayList<ProgressUpdate>()
        val web = MockWebServer()
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer reader-smoke") {
                    return MockResponse.Builder().code(401).build()
                }
                return when (request.target.substringBefore('?')) {
                    "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me("reader-smoke")))
                    "/api/consumer/v1/library/book" -> json(ApiJson.encodeToString(Publication(
                        id = "book", title = "Reader smoke", bookType = BookType.EBOOK,
                        assets = listOf(Asset("epub", filename = "smoke.epub", mediaType = "application/epub+zip", format = "epub", sizeBytes = epub.size.toLong(), contentUrl = "/book.epub")),
                        progress = saved.get(),
                    )))
                    "/book.epub" -> if (request.headers["If-None-Match"] == "\"smoke\"") {
                        MockResponse.Builder().code(304).build()
                    } else {
                        MockResponse.Builder().code(200).headers(Headers.headersOf("ETag", "\"smoke\"", "Content-Type", "application/epub+zip"))
                            .body(Buffer().write(epub)).build()
                    }
                    "/api/consumer/v1/library/book/progress" -> {
                        val update = ApiJson.decodeFromString<ProgressUpdate>(request.body!!.utf8())
                        writes += update
                        val progress = Progress(
                            update.assetId, update.locator, update.positionSeconds, (saved.get()?.version ?: 0) + 1,
                            clientMutationId = update.clientMutationId, observedAt = update.observedAt,
                        )
                        saved.set(progress)
                        json("{\"progress\":${ApiJson.encodeToString(progress)}}")
                    }
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        app.container.sessions.signIn(Session(server, Me("reader-smoke"), "reader-smoke"))
        val openedAt = System.currentTimeMillis()
        try {
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "book")).use { scenario ->
                awaitText(scenario, "First chapter is rendered")
                screenshot(scenario, "chapter-one.png")
                scenario.onActivity { activity ->
                    val navigator = activity.supportFragmentManager.findFragmentById(R.id.reader_navigator) as EpubNavigatorFragment
                    val state = ViewModelProvider(activity)[ReaderViewModel::class.java].state.value as ReaderState.Ready
                    navigator.lifecycleScope.launch { navigator.go(state.publication.readingOrder[1], animated = false) }
                }
                awaitText(scenario, "Second chapter is rendered")
                await("chapter two progress reached the server") { saved.get()?.locator?.get("href").toString().contains("c2.xhtml") }
                screenshot(scenario, "chapter-two.png")
            }
            // Each write says when the page was reached, on this device's clock.
            val reached = requireNotNull(ActivityTime.parse(saved.get()?.observedAt)) { "observed_at missing: ${writes.last()}" }
            assertTrue("observed at $reached, opened at $openedAt", reached in openedAt..System.currentTimeMillis())
            assertTrue(writes.none { it.resolveConflict == true })
            val beforeReopen = writes.size
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "book")).use { scenario ->
                awaitText(scenario, "Second chapter is rendered")
                screenshot(scenario, "chapter-two-resumed.png")
                // Restoring the saved page is not reading: give the debounce time, then expect silence.
                SystemClock.sleep(6_000)
            }
            // Closing flushes in the background; anything it had to send would have gone by now.
            SystemClock.sleep(1_000)
            assertEquals("reopening sent ${writes.drop(beforeReopen)}", beforeReopen, writes.size)
        } finally {
            runBlocking {
                app.container.currentAccount()?.close()
                app.container.epubCache.clear(Session(server, Me("reader-smoke"), "reader-smoke").accountKey)
            }
            app.container.sessions.clear()
            web.close()
        }
    }

    @Test
    fun downloadsABookAndAudiobookThenOpensBothOffline() {
        val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
        val epub = epub()
        val tracks = listOf(wav(seconds = 3, hertz = 330), wav(seconds = 3, hertz = 440))
        val book = Publication(
            id = "offline-book", title = "Offline smoke", bookType = BookType.EBOOK,
            assets = listOf(Asset("offline-epub", "smoke.epub", "application/epub+zip", "epub", epub.size.toLong(), "/files/epub")),
        )
        val audiobook = Publication(
            id = "offline-audio", title = "Offline audio smoke", bookType = BookType.AUDIOBOOK,
            assets = tracks.mapIndexed { index, bytes -> Asset("track-$index", "$index.wav", "audio/wav", "wav", bytes.size.toLong(), "/files/track-$index", index) },
        )
        val web = MockWebServer()
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer offline-smoke") return MockResponse.Builder().code(401).build()
                val path = request.target.substringBefore('?')
                return when {
                    path == "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me("offline-smoke")))
                    path == "/api/consumer/v1/library/offline-book" -> json(ApiJson.encodeToString(book))
                    path == "/api/consumer/v1/library/offline-audio" -> json(ApiJson.encodeToString(audiobook))
                    path == "/files/epub" -> file(epub, "\"epub\"", "application/epub+zip")
                    path.startsWith("/files/track-") -> file(tracks[path.removePrefix("/files/track-").toInt()], "\"$path\"", "audio/wav")
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me("offline-smoke"), "offline-smoke")
        app.container.sessions.signIn(session)
        try {
            val downloads = requireNotNull(app.container.currentAccount()).downloads
            runBlocking {
                downloads.enqueue(book)
                downloads.enqueue(audiobook)
            }
            await("both downloads are complete") { downloads.ready("offline-book") != null && downloads.ready("offline-audio") != null }

            // The latest synced place is newer than the download's metadata snapshot.
            runBlocking {
                val progress = requireNotNull(app.container.currentAccount()).progress
                progress.sync("offline-book").begin(SavedPosition("offline-epub", buildJsonObject {
                    put("href", "OEBPS/c2.xhtml")
                    put("type", "application/xhtml+xml")
                }), 4)
                progress.sync("offline-audio").begin(SavedPosition("track-1", positionSeconds = 1.0), 5)
            }
            // No server from here on: anything that still opens came from the device.
            web.close()

            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "offline-book")).use { scenario ->
                awaitText(scenario, "Second chapter is rendered")
                scenario.onActivity { activity ->
                    val model = ViewModelProvider(activity)[ReaderViewModel::class.java]
                    assertEquals(ReaderSource.DOWNLOAD, model.fileSource)
                }
                screenshot(scenario, "offline-download.png")
            }

            val player = AtomicReference<PlayerViewModel>()
            InstrumentationRegistry.getInstrumentation().runOnMainSync { player.set(PlayerViewModel(app.container, "offline-audio")) }
            await("the player opens the downloaded audiobook") { player.get().state.value is PlayerState.Active }
            val notice = (player.get().state.value as PlayerState.Active).notice.orEmpty()
            assertTrue(notice, notice.contains("download"))
            // CI's emulator has no audio device, so assert the honest part: local files, prepared, no failure.
            await("downloaded tracks are prepared") {
                val snapshot = app.container.playback.snapshot.value
                snapshot.fromDevice && snapshot.durationMs > 0 && snapshot.problem == null
            }
            assertEquals(listOf("track-0", "track-1"), app.container.playback.snapshot.value.tracks.map { it.id })
            assertEquals(1, app.container.playback.snapshot.value.trackIndex)
        } finally {
            runBlocking {
                app.container.playback.stop()
                app.container.currentAccount()?.let { account ->
                    account.close()
                    account.directory.deleteRecursively()
                }
                app.container.epubCache.clear(session.accountKey)
            }
            app.container.sessions.clear()
            runCatching { web.close() }
        }
    }

    private fun file(bytes: ByteArray, etag: String, type: String) =
        MockResponse.Builder().code(200).headers(Headers.headersOf("ETag", etag, "Content-Type", type)).body(Buffer().write(bytes)).build()

    /** A short mono 16-bit PCM tone, written by hand so the fixture is original. */
    private fun wav(seconds: Int, hertz: Int): ByteArray {
        val rate = 8_000
        val samples = rate * seconds
        val data = java.nio.ByteBuffer.allocate(44 + samples * 2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        data.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVE".toByteArray())
        data.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
        data.put("data".toByteArray()).putInt(samples * 2)
        for (n in 0 until samples) data.putShort((6_000 * kotlin.math.sin(2 * Math.PI * hertz * n / rate)).toInt().toShort())
        return data.array()
    }

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private fun awaitText(scenario: ActivityScenario<ReaderActivity>, text: String) = await("EPUB text: $text") {
        val views = mutableListOf<WebView>()
        scenario.onActivity { activity -> collectWebViews(activity.window.decorView, views) }
        views.any { view ->
            val result = AtomicReference<String>()
            val done = CountDownLatch(1)
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                view.evaluateJavascript("document.body ? document.body.innerText : ''") { result.set(it); done.countDown() }
            }
            done.await(2, TimeUnit.SECONDS) && result.get().orEmpty().contains(text)
        }
    }

    private fun collectWebViews(view: View, found: MutableList<WebView>) {
        if (view is WebView && view.isShown && view.alpha > 0 && view.getGlobalVisibleRect(Rect())) found += view
        if (view is ViewGroup) for (index in 0 until view.childCount) collectWebViews(view.getChildAt(index), found)
    }

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        assertTrue("Timed out waiting for $description", condition())
    }

    private fun screenshot(scenario: ActivityScenario<ReaderActivity>, name: String) {
        // PixelCopy reads the submitted window buffer, rather than racing the
        // compositor. Require actual text pixels as well as the DOM assertion.
        var rendered: Bitmap? = null
        await("a painted EPUB page for $name") {
            val image = captureWindow(scenario) ?: return@await false
            val hasText = hasTextPixels(image)
            if (hasText) rendered = image else image.recycle()
            hasText
        }
        val bitmap = requireNotNull(rendered)
        try {
            // Gradle pulls this before uninstalling the app and clearing its files.
            val output = requireNotNull(InstrumentationRegistry.getArguments().getString("additionalTestOutputDir"))
            val folder = File(output)
            check(folder.isDirectory || folder.mkdirs()) { "Cannot create test output directory" }
            File(folder, name).outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        } finally {
            bitmap.recycle()
        }
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

    private fun hasTextPixels(image: Bitmap): Boolean {
        // The fixture opens with the paper theme and hidden chrome. This region
        // excludes the system bars and progress label, so a blank page fails.
        var ink = 0
        for (y in image.height / 10 until image.height * 3 / 5 step 2) {
            for (x in image.width / 10 until image.width * 9 / 10 step 2) {
                val pixel = image.getPixel(x, y)
                val red = (pixel shr 16) and 255
                val green = (pixel shr 8) and 255
                val blue = pixel and 255
                if (red < 160 && green < 160 && blue < 160 && ++ink > 50) return true
            }
        }
        return false
    }

    private fun epub(): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            fun entry(name: String, value: String, stored: Boolean = false) {
                val bytes = value.toByteArray()
                val item = ZipEntry(name)
                if (stored) {
                    item.method = ZipEntry.STORED
                    item.size = bytes.size.toLong()
                    item.compressedSize = bytes.size.toLong()
                    item.crc = CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(item)
                zip.write(bytes)
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip", stored = true)
            entry("META-INF/container.xml", """<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            entry("OEBPS/content.opf", """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:shelfarr:smoke</dc:identifier><dc:title>Reader smoke</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-07T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>""")
            entry("OEBPS/nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="c1.xhtml">First</a></li><li><a href="c2.xhtml">Second</a></li></ol></nav></body></html>""")
            for ((id, text) in listOf("c1" to "First chapter is rendered", "c2" to "Second chapter is rendered")) {
                entry("OEBPS/$id.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$text</title></head><body><h1>$text</h1><p>This is an original fixture for testing a real EPUB page.</p></body></html>""")
            }
        }
        return output.toByteArray()
    }
}
