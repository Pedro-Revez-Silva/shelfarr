package org.shelfarr.app.reader

import android.graphics.Bitmap
import android.os.SystemClock
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
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Headers
import okio.Buffer
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.shelfarr.app.R
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressUpdate
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session

/** Exercises the real Activity, HTTP/cache path and WebView, beyond ZIP parsing. */
@RunWith(AndroidJUnit4::class)
class ReaderSmokeTest {
    @Test
    fun rendersNavigatesSavesAndReopensAnEpub() {
        val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
        val epub = epub()
        val saved = AtomicReference<Progress?>(null)
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
                        val progress = Progress(update.assetId, update.locator, update.positionSeconds, (saved.get()?.version ?: 0) + 1, clientMutationId = update.clientMutationId)
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
        try {
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "book")).use { scenario ->
                awaitText(scenario, "First chapter is rendered")
                screenshot(app, "chapter-one.png")
                scenario.onActivity { activity ->
                    val navigator = activity.supportFragmentManager.findFragmentById(R.id.reader_navigator) as EpubNavigatorFragment
                    val state = ViewModelProvider(activity)[ReaderViewModel::class.java].state.value as ReaderState.Ready
                    navigator.lifecycleScope.launch { navigator.go(state.publication.readingOrder[1], animated = false) }
                }
                awaitText(scenario, "Second chapter is rendered")
                screenshot(app, "chapter-two.png")
                await("chapter two progress reached the server") { saved.get()?.locator?.get("href").toString().contains("c2.xhtml") }
            }
            ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "book")).use { scenario ->
                awaitText(scenario, "Second chapter is rendered")
                screenshot(app, "chapter-two-resumed.png")
            }
        } finally {
            runBlocking {
                app.container.currentAccount()?.close()
                app.container.epubCache.clear(Session(server, Me("reader-smoke"), "reader-smoke").accountKey)
            }
            app.container.sessions.clear()
            web.close()
        }
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
        if (view is WebView && view.isShown && view.width > 0 && view.height > 0) found += view
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

    private fun screenshot(app: ShelfarrApplication, name: String) {
        val folder = File(app.getExternalFilesDir(null), "reader-smoke").apply { mkdirs() }
        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()?.let { bitmap ->
            File(folder, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
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
