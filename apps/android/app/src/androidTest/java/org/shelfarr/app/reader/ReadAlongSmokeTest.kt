package org.shelfarr.app.reader

import android.app.NotificationManager
import android.content.Context
import android.graphics.Rect
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Headers
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
import org.shelfarr.app.core.ReadAlongAudiobook
import org.shelfarr.app.core.ReadAlongCoverage
import org.shelfarr.app.core.ReadAlongSummary
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session

/**
 * Read-along on a device: the real Activity, Readium navigator and WebView, the Media3
 * service and its notification, real HTTP and real files. Narration is generated tones,
 * cue N at 330 + 110N Hz from 2N s to 2N + 1.8 s, so what plays is the cue highlighted.
 */
@RunWith(AndroidJUnit4::class)
class ReadAlongSmokeTest {
    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val web = MockWebServer()
    private val writes = CopyOnWriteArrayList<Pair<String, ProgressUpdate>>()
    private val saved = HashMap<String, Progress>()
    private val narration = tones(8)
    private val pairedTracks = listOf(tones(4, first = 0), tones(4, first = 4))

    private val overlayEpub = epub(overlay = true)
    private val plainEpub = epub(overlay = false)

    @After
    fun tearDown() {
        runBlocking { app.container.playback.stop() }
        web.close()
    }

    private fun summary(source: String, generation: String, manifest: String, audio: Int, audiobook: ReadAlongAudiobook? = null) =
        ReadAlongSummary("available", source, generation, manifest, ReadAlongCoverage(true, 2, 2, cues = 8), 4_000, audio.toLong(), audiobook = audiobook)

    private val garden get() = Publication(
        id = "garden", title = "The Narrated Garden", bookType = BookType.EBOOK, progress = saved["garden"],
        assets = listOf(
            Asset(
                "epub-garden", "garden.epub", "application/epub+zip", "epub", overlayEpub.size.toLong(), "/files/epub-garden",
                readAlong = summary("media_overlay", GARDEN_GENERATION, "/api/consumer/v1/library/garden/assets/epub-garden/read_along", narration.size),
            ),
        ),
    )

    private val lighthouse get() = Publication(
        id = "lighthouse", title = "The Paired Lighthouse", bookType = BookType.EBOOK, progress = saved["lighthouse"],
        assets = listOf(
            Asset(
                "epub-lighthouse", "lighthouse.epub", "application/epub+zip", "epub", plainEpub.size.toLong(), "/files/epub-lighthouse",
                readAlong = summary(
                    "imported", LIGHTHOUSE_GENERATION, "/api/consumer/v1/library/lighthouse/assets/epub-lighthouse/read_along",
                    pairedTracks.sumOf { it.size }, ReadAlongAudiobook("lighthouse-audio", "The Paired Lighthouse"),
                ),
            ),
        ),
    )

    private fun start() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer read-along") return MockResponse.Builder().code(401).build()
                val path = request.target.substringBefore('?')
                return when {
                    path == "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me("read-along")))
                    path == "/api/consumer/v1/library/garden" -> {
                        assertEquals("read-along", request.headers["X-Shelfarr-Reader-Features"])
                        json(ApiJson.encodeToString(garden))
                    }
                    path == "/api/consumer/v1/library/lighthouse" -> json(ApiJson.encodeToString(lighthouse))
                    path == "/api/consumer/v1/library/garden/assets/epub-garden/read_along" -> json(overlayManifest())
                    path == "/api/consumer/v1/library/lighthouse/assets/epub-lighthouse/read_along" -> json(importedManifest())
                    path == "/api/consumer/v1/library/lighthouse-audio/progress" -> json("""{"progress":${saved["lighthouse-audio"]?.let { ApiJson.encodeToString(it) } ?: "null"}}""")
                    path == "/files/epub-garden" -> file(request, overlayEpub, "application/epub+zip")
                    path == "/files/epub-lighthouse" -> file(request, plainEpub, "application/epub+zip")
                    path == "/files/lh-1" -> file(request, pairedTracks[0], "audio/wav")
                    path == "/files/lh-2" -> file(request, pairedTracks[1], "audio/wav")
                    path.endsWith("/read_along/resources/OEBPS/audio/narration.wav") -> file(request, narration, "audio/wav")
                    path.endsWith("/progress") && request.method == "PUT" -> {
                        val id = path.removePrefix("/api/consumer/v1/library/").removeSuffix("/progress")
                        val update = ApiJson.decodeFromString<ProgressUpdate>(request.body!!.utf8())
                        writes += id to update
                        val progress = Progress(
                            update.assetId, update.locator, update.positionSeconds, (saved[id]?.version ?: 0) + 1,
                            clientMutationId = update.clientMutationId, observedAt = update.observedAt,
                        )
                        saved[id] = progress
                        json("{\"progress\":${ApiJson.encodeToString(progress)}}")
                    }
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        app.container.sessions.signIn(Session(server, Me("read-along"), "read-along"))
    }

    @Test
    fun mediaOverlayNarrationHighlightsFollowsBrowsesAndRestoresSilently() {
        start()
        val openedAt = System.currentTimeMillis()
        ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "garden")).use { scenario ->
            awaitText(scenario, "Cue 1 sounds")
            await("read-along ready") { model(scenario).readAlongUi.value is ReadAlongUi.Ready }
            // Plain reading adds nothing to the page until narration is played.
            assertFalse((model(scenario).readAlongUi.value as ReadAlongUi.Ready).started)
            scenario.onActivity { it.narrationActions.toggle() }
            await("narration playing in the shared service") {
                val snapshot = app.container.playback.snapshot.value
                snapshot.isPlaying && snapshot.narration?.publicationId == "garden"
            }
            // The cue being heard is highlighted by Readium in the page.
            await("a narration highlight in the page") { evaluate(scenario, HIGHLIGHT_COUNT).toIntOrNull() == 1 }
            // Lock screen and notification controls come from the same Media3 session.
            await("a media notification") {
                val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.activeNotifications.any { it.notification.extras.getCharSequence("android.title")?.toString() == "The Narrated Garden" }
            }
            // Heard places reach the server as the reached cue's element plus the exact offset.
            await("a read-along checkpoint on the server") { writes.any { it.first == "garden" && it.second.locator?.readAlong() != null } }
            val heard = writes.last { it.first == "garden" }.second
            val observed = requireNotNull(ActivityTime.parse(heard.observedAt))
            assertTrue(observed in openedAt..System.currentTimeMillis())

            // Browsing while it plays writes nothing and offers the way back.
            val before = writes.size
            scenario.onActivity { activity ->
                val navigator = activity.supportFragmentManager.findFragmentById(R.id.reader_navigator) as EpubNavigatorFragment
                navigator.lifecycleScope.launch { navigator.goForward(animated = false) }
            }
            await("browsing noticed") { (model(scenario).readAlongUi.value as ReadAlongUi.Ready).browsing || !app.container.playback.isListening }
            writes.drop(before).forEach { (_, update) -> assertTrue("browse wrote $update", update.locator?.readAlong() != null) }

            scenario.onActivity { it.narrationActions.toggle() } // pause
            await("paused") { !app.container.playback.snapshot.value.isPlaying }
            await("the pause checkpoint sent") { writes.lastOrNull()?.second?.locator?.readAlong() != null }
        }
        // Reopening at the narration place is not activity: nothing new is written.
        val settled = writes.size
        ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "garden")).use { scenario ->
            awaitText(scenario, "Cue")
            await("read-along ready again") { model(scenario).readAlongUi.value is ReadAlongUi.Ready }
            SystemClock.sleep(6_000)
            assertEquals(settled, writes.size)
        }
    }

    @Test
    fun importedNarrationPlaysOfflineAndWritesBothPlacesWithOneTime() {
        start()
        val services = requireNotNull(app.container.currentAccount())
        runBlocking { services.downloads.enqueue(lighthouse, narration = true) }
        await("book and narration downloaded") { services.downloads.record("lighthouse")?.narration?.isReady == true }
        assertTrue(services.downloads.record("lighthouse")!!.isReady)
        // Now the server is gone: everything plays from this device.
        web.close()
        ActivityScenario.launch<ReaderActivity>(ReaderActivity.intent(app, "lighthouse")).use { scenario ->
            awaitText(scenario, "Cue 1 sounds")
            await("offline read-along ready") { (model(scenario).readAlongUi.value as? ReadAlongUi.Ready)?.fromDevice == true }
            scenario.onActivity { it.narrationActions.toggle() }
            await("narration playing from files") { app.container.playback.snapshot.value.let { it.isPlaying && it.fromDevice } }
            SystemClock.sleep(6_000)
            scenario.onActivity { it.narrationActions.toggle() }
            await("paused") { !app.container.playback.snapshot.value.isPlaying }
        }
        val book = runBlocking { services.progress.sync("lighthouse").snapshot() }
        val audio = runBlocking { services.progress.sync("lighthouse-audio").snapshot() }
        assertTrue(book.position?.locator?.readAlong() != null)
        assertEquals(book.observedAtEpochMs, audio.observedAtEpochMs)
        assertTrue(audio.position?.assetId in setOf("lh-1", "lh-2"))
        assertTrue(book.hasUnsyncedChanges && audio.hasUnsyncedChanges)
    }

    private fun model(scenario: ActivityScenario<ReaderActivity>): ReaderViewModel {
        val found = AtomicReference<ReaderViewModel>()
        scenario.onActivity { found.set(ViewModelProvider(it)[ReaderViewModel::class.java]) }
        return found.get()
    }

    private fun kotlinx.serialization.json.JsonObject.readAlong() = this["locations"]?.jsonObject?.get("readAlong")?.jsonObject

    private fun evaluate(scenario: ActivityScenario<ReaderActivity>, script: String): String {
        val views = mutableListOf<WebView>()
        scenario.onActivity { activity -> collectWebViews(activity.window.decorView, views) }
        return views.firstNotNullOfOrNull { view ->
            val result = AtomicReference<String>()
            val done = CountDownLatch(1)
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                view.evaluateJavascript(script) { result.set(it); done.countDown() }
            }
            if (done.await(2, TimeUnit.SECONDS)) result.get()?.trim('"')?.takeIf { it.isNotEmpty() && it != "0" && it != "null" } else null
        }.orEmpty()
    }

    private fun awaitText(scenario: ActivityScenario<ReaderActivity>, text: String) =
        await("EPUB text: $text") { evaluate(scenario, "document.body ? document.body.innerText : ''").contains(text) }

    private fun collectWebViews(view: View, found: MutableList<WebView>) {
        if (view is WebView && view.isShown && view.getGlobalVisibleRect(Rect())) found += view
        if (view is ViewGroup) for (index in 0 until view.childCount) collectWebViews(view.getChildAt(index), found)
    }

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(150)
        }
        assertTrue("Timed out waiting for $description", condition())
    }

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private fun file(request: RecordedRequest, bytes: ByteArray, type: String): MockResponse {
        val range = request.headers["Range"]?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull()
        if (range != null && range < bytes.size) {
            return MockResponse.Builder().code(206)
                .headers(Headers.headersOf("ETag", "\"${bytes.size}\"", "Content-Type", type, "Content-Range", "bytes $range-${bytes.size - 1}/${bytes.size}"))
                .body(Buffer().write(bytes, range, bytes.size - range)).build()
        }
        return MockResponse.Builder().code(200)
            .headers(Headers.headersOf("ETag", "\"${bytes.size}\"", "Content-Type", type, "Accept-Ranges", "bytes"))
            .body(Buffer().write(bytes)).build()
    }

    /** Cue N (from [first]) sounds 330 + 110N Hz for 1.8 s, then 0.2 s of silence. */
    private fun tones(count: Int, first: Int = 0, rate: Int = 16_000): ByteArray {
        val samples = rate * 2 * count
        val data = ByteBuffer.allocate(samples * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (n in 0 until samples) {
            val cue = first + n / (rate * 2)
            val within = n % (rate * 2)
            val value = if (within < rate * 1.8) 6_000 * kotlin.math.sin(2 * Math.PI * (330 + 110 * cue) * within / rate) else 0.0
            data.putShort(value.toInt().toShort())
        }
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
            .putInt(rate).putInt(rate * 2).putShort(2).putShort(16).put("data".toByteArray()).putInt(samples * 2)
        return header.array() + data.array()
    }

    private fun sentence(cue: Int) = "Cue ${cue + 1} sounds. " + "word ".repeat(70).trim() + "."

    private fun epub(overlay: Boolean): ByteArray {
        val docs = listOf("chapter1.xhtml" to (0..4), "chapter2.xhtml" to (5..7))
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            fun put(name: String, bytes: ByteArray, stored: Boolean = false) {
                val entry = ZipEntry(name)
                if (stored) {
                    entry.method = ZipEntry.STORED
                    entry.size = bytes.size.toLong()
                    entry.compressedSize = bytes.size.toLong()
                    entry.crc = CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
            put("mimetype", "application/epub+zip".toByteArray(), stored = true)
            put("META-INF/container.xml", """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""".toByteArray())
            val items = StringBuilder("""<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>""")
            val spine = StringBuilder()
            docs.forEachIndexed { index, (doc, cues) ->
                items.append("""<item id="doc$index" href="$doc" media-type="application/xhtml+xml"${if (overlay) """ media-overlay="mo$index"""" else ""}/>""")
                spine.append("""<itemref idref="doc$index"/>""")
                put("OEBPS/$doc", """<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter ${index + 1}</title></head><body><h1>Chapter ${index + 1}</h1>${cues.joinToString("") { """<p id="c$it">${sentence(it)}</p>""" }}</body></html>""".toByteArray())
                if (overlay) {
                    items.append("""<item id="mo$index" href="${doc.replace(".xhtml", ".smil")}" media-type="application/smil+xml"/>""")
                    val pars = cues.joinToString("") { """<par><text src="$doc#c$it"/><audio src="audio/narration.wav" clipBegin="${it * 2}s" clipEnd="${it * 2 + 1.8}s"/></par>""" }
                    put("OEBPS/${doc.replace(".xhtml", ".smil")}", """<?xml version="1.0" encoding="UTF-8"?><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq>$pars</seq></body></smil>""".toByteArray())
                }
            }
            if (overlay) items.append("""<item id="narration" href="audio/narration.wav" media-type="audio/wav"/>""")
            put("OEBPS/content.opf", """<?xml version="1.0" encoding="UTF-8"?><package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:test:${if (overlay) "garden" else "lighthouse"}</dc:identifier><dc:title>Read along</dc:title><dc:language>en</dc:language></metadata><manifest>$items</manifest><spine>$spine</spine></package>""".toByteArray())
            put("OEBPS/nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Chapter 1</a></li><li><a href="chapter2.xhtml">Chapter 2</a></li></ol></nav></body></html>""".toByteArray())
            if (overlay) put("OEBPS/audio/narration.wav", narration, stored = true)
        }
        return out.toByteArray()
    }

    private val texts = """[{"href":"OEBPS/chapter1.xhtml","media_type":"application/xhtml+xml"},{"href":"OEBPS/chapter2.xhtml","media_type":"application/xhtml+xml"}]"""
    private val fields = """["text","fragment","audio","begin_ms","end_ms"]"""

    private fun overlayManifest(): String {
        val cues = (0 until 8).joinToString(",") { """[${if (it < 5) 0 else 1},"c$it",0,${it * 2_000},${it * 2_000 + 1_800}]""" }
        return """{"version":1,"generation":"$GARDEN_GENERATION","source":"media_overlay","publication_id":"garden","ebook_asset_id":"epub-garden",
            "text":$texts,"audio":[{"kind":"epub_resource","href":"OEBPS/audio/narration.wav","media_type":"audio/wav","size_bytes":${narration.size},
            "url":"/api/consumer/v1/library/garden/assets/epub-garden/read_along/resources/OEBPS/audio/narration.wav"}],
            "cue_fields":$fields,"cues":[$cues],"coverage":{"complete":true,"text_sections":2,"aligned_sections":2,"cues":8}}"""
    }

    private fun importedManifest(): String {
        val cues = (0 until 8).joinToString(",") { """[${if (it < 5) 0 else 1},"c$it",${it / 4},${(it % 4) * 2_000},${(it % 4) * 2_000 + 1_800}]""" }
        val audio = pairedTracks.mapIndexed { index, bytes ->
            """{"kind":"publication_asset","publication_id":"lighthouse-audio","asset_id":"lh-${index + 1}","filename":"Lighthouse ${index + 1}.wav",
            "media_type":"audio/wav","size_bytes":${bytes.size},"url":"/files/lh-${index + 1}","content_url":"/files/lh-${index + 1}"}"""
        }.joinToString(",")
        return """{"version":1,"generation":"$LIGHTHOUSE_GENERATION","source":"imported","publication_id":"lighthouse","ebook_asset_id":"epub-lighthouse",
            "text":$texts,"audio":[$audio],"cue_fields":$fields,"cues":[$cues],"coverage":{"complete":true,"text_sections":2,"aligned_sections":2,"cues":8}}"""
    }

    private companion object {
        const val GARDEN_GENERATION = "1f7d5b1a0e9c4d3b2a19087f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3"
        const val LIGHTHOUSE_GENERATION = "2e8c6a4b2c0e1f3d5b7a9c8e6f4d2b0a1c3e5f7d9b8a6c4e2f0d1b3a5c7e9f8d"

        /** Readium draws each decoration group as a div named by its group, holding one div per decoration. */
        const val HIGHLIGHT_COUNT = "String(document.querySelectorAll('div[data-group=\"read-along\"] > div').length)"
    }
}
