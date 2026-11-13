package org.shelfarr.app.reader

import android.app.Application
import android.content.Context
import android.os.Looper
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Duration
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.readium.r2.shared.publication.Publication as ReadiumPublication
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.mediatype.MediaType
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.shelfarr.app.AccountServices
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ConsumerApi
import org.shelfarr.app.core.Credential
import org.shelfarr.app.core.DownloadManager
import org.shelfarr.app.core.FileProgressStore
import org.shelfarr.app.core.LibraryCache
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.ProgressRegistry
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadAlong
import org.shelfarr.app.core.ReadAlongFixtures
import org.shelfarr.app.core.ReadAlongSummary
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.TEST_EPOCH
import org.shelfarr.app.core.buildHttpClient
import org.shelfarr.app.playback.FakeAudioPlayer
import org.shelfarr.app.playback.PlaybackController

/**
 * The reader's read-along wiring end to end, without a WebView: account services, the
 * manifest fetched over HTTP, a Media Overlay EPUB parsed by Readium, the shared playback
 * controller and its listening checkpoints, against a scripted Media3 player.
 *
 * Regressions for places adopted while narration is loaded, paused page turns, and the
 * lock screen or a headset playing narration behind the reader's back.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ReadAlongWiringTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val player = FakeAudioPlayer()
    private val context = ApplicationProvider.getApplicationContext<Application>()
    private lateinit var server: ServerAddress
    private lateinit var services: AccountServices
    /** This device's places, readable without suspending the main thread. */
    private val store = org.shelfarr.app.core.MemoryStore()
    private var audiobookProgress: String = """{"progress":null}"""

    private fun wallClock() = TEST_EPOCH + SystemClock.elapsedRealtime()

    private val controller = PlaybackController(context, scope, connect = { player }, wallClock = ::wallClock, elapsed = SystemClock::elapsedRealtime)

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer token") return MockResponse.Builder().code(401).build()
                val body = when (request.target.substringBefore('?')) {
                    GARDEN_MANIFEST -> ReadAlongFixtures.overlayManifest()
                    LIGHTHOUSE_MANIFEST -> ReadAlongFixtures.importedManifest()
                    "/api/consumer/v1/library/lighthouse-audio-1/progress" -> audiobookProgress
                    else -> return MockResponse.Builder().code(404).build()
                }
                return MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()
            }
        }
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        val directory = folder.newFolder("account")
        val client = buildHttpClient({ Credential(server, "token") })
        // Nothing reaches a server in these tests: places stay on this device, as when offline.
        val registry = ProgressRegistry(store, { _, _ -> throw ApiException.Offline() }, scope)
        val downloads = DownloadManager(File(directory, "downloads"), client, server, { throw ApiException.NotFound() }, io)
        services = AccountServices(
            AtomicReference(Session(server, Me("reader"), "token")), ConsumerApi(client), registry, downloads, directory,
            LibraryCache(File(directory, "library.json"), io), FileProgressStore(File(directory, "progress.json")), io, Job(),
        )
    }

    @After
    fun tearDown() {
        scope.cancel()
        io.cancel()
        web.close()
    }

    private fun idle(ms: Long = 0) {
        val looper = shadowOf(Looper.getMainLooper())
        if (ms > 0) looper.idleFor(Duration.ofMillis(ms)) else looper.idle()
    }

    private fun readium(overlay: Boolean): ReadiumPublication = runBlocking {
        val file = folder.newFile().apply { writeBytes(ReadAlongFixtures.epub(overlay)) }
        val http = DefaultHttpClient()
        val retriever = AssetRetriever(context.contentResolver, http)
        val opener = PublicationOpener(DefaultPublicationParser(context, http, retriever, pdfFactory = null))
        val asset = retriever.retrieve(file, MediaType.EPUB).getOrElse { error("not an EPUB") }
        opener.open(asset, allowUserInteraction = false).getOrElse { error("Readium refused the fixture") }
    }

    private fun book(id: String, assetId: String, generation: String, source: String, manifest: String, audiobook: String? = null) = Publication(
        id = id, title = id, bookType = BookType.EBOOK,
        assets = listOf(
            Asset(
                assetId, "$id.epub", "application/epub+zip", "epub", 1_000, "/files/$assetId",
                readAlong = ReadAlongSummary(
                    "available", source, generation, manifest,
                    audiobook = audiobook?.let { org.shelfarr.app.core.ReadAlongAudiobook(it, "The Paired Lighthouse") },
                ),
            ),
        ),
    )

    private val garden = book("garden-1", ReadAlongFixtures.EPUB_ID, ReadAlongFixtures.GENERATION, "media_overlay", GARDEN_MANIFEST)
    private val lighthouse = book(
        "lighthouse-1", "epub-lighthouse", ReadAlongFixtures.OTHER_GENERATION, "imported", LIGHTHOUSE_MANIFEST, audiobook = "lighthouse-audio-1",
    )

    private val hrefs = listOf("OEBPS/chapter1.xhtml", "OEBPS/chapter2.xhtml")

    /** An exact narration place as this app (or the web reader) saves it. */
    private fun heard(manifest: String, asset: String, generation: String, track: Int, ms: Long): SavedPosition {
        val readAlong = ReadAlong.read(manifest.byteInputStream(), asset, generation, server)
        return SavedPosition(asset, readAlong.locatorFor(track, ms, hrefs::get) { null })
    }

    private fun coordinator(publication: Publication, readium: ReadiumPublication, opening: SavedPosition?, observedAt: Long?): ReadAlongCoordinator {
        val sync = services.progress.sync(publication.id)
        runBlocking { sync.begin(opening, 1, observedAt, publication.playableAssets.map { it.id }) }
        val settings = ReaderSettingsStore(context.getSharedPreferences("wiring-${publication.id}", Context.MODE_PRIVATE))
        return ReadAlongCoordinator(scope, controller, services, sync, settings).also { coordinator ->
            runBlocking { coordinator.open(publication, publication.assets.single(), readium, null, false, opening?.locator) }
            idle()
            assertTrue("read-along: ${coordinator.ui.value}", coordinator.ui.value is ReadAlongUi.Ready)
        }
    }

    private fun saved(id: String) = store.records[id]
    private fun JsonObject.offset(): Long? = this["locations"]?.jsonObject?.get("readAlong")?.jsonObject?.get("offset_ms")?.jsonPrimitive?.long
    private fun JsonObject.fragment(): String? = this["locations"]?.jsonObject?.get("fragments")?.jsonArray?.firstOrNull()?.jsonPrimitive?.content

    @Test
    fun `a place adopted while narration is loaded moves the player, Play waits for it, and the replay keeps its time`() {
        val gardenBook = readium(overlay = true)
        val opening = heard(ReadAlongFixtures.overlayManifest(), ReadAlongFixtures.EPUB_ID, ReadAlongFixtures.GENERATION, 0, 4_500)
        val readAlong = coordinator(garden, gardenBook, opening, wallClock() - 600_000)
        readAlong.toggle(null)
        idle()
        assertTrue(player.isPlaying)
        idle(7_000)
        readAlong.toggle(null)
        idle()
        assertFalse(player.isPlaying)

        // "Use other device": the server's place is adopted, with that device's time.
        val adoptedAt = wallClock() - 120_000
        val adopted = heard(ReadAlongFixtures.overlayManifest(), ReadAlongFixtures.EPUB_ID, ReadAlongFixtures.GENERATION, 0, 13_743)
        readAlong.restoreStarting()
        readAlong.toggle(null) // pressed while the adoption is still being saved
        idle()
        assertFalse("Play went ahead before the adopted place was in", player.isPlaying)
        runBlocking { services.progress.sync("garden-1").begin(adopted, 3, adoptedAt, listOf(ReadAlongFixtures.EPUB_ID)) }
        readAlong.restoredTo(adopted.locator)
        idle()
        assertTrue(player.isPlaying)
        // The genuine resume: five seconds before the adopted place, once.
        assertEquals(8_743L, player.positionMs)
        idle(3_500)
        assertEquals(adopted, saved("garden-1")!!.position)
        assertEquals(adoptedAt, saved("garden-1")!!.observedAtEpochMs)
        idle(4_500)
        assertTrue(saved("garden-1")!!.position!!.locator!!.offset()!! > 13_743)
    }

    @Test
    fun `a lock-screen play after an adopted place resumes there, not where the player had paused`() {
        val gardenBook = readium(overlay = true)
        val readAlong = coordinator(garden, gardenBook, null, null)
        readAlong.toggle(PageCues("OEBPS/chapter1.xhtml", "c0", null))
        idle(3_000)
        readAlong.toggle(null)
        idle()
        val adoptedAt = wallClock() - 60_000
        val adopted = heard(ReadAlongFixtures.overlayManifest(), ReadAlongFixtures.EPUB_ID, ReadAlongFixtures.GENERATION, 0, 12_400)
        runBlocking { services.progress.sync("garden-1").begin(adopted, 2, adoptedAt, listOf(ReadAlongFixtures.EPUB_ID)) }
        readAlong.restoredTo(adopted.locator)
        idle()
        // A media command, not the app's own button.
        player.playFromOutside()
        idle()
        assertEquals(7_400L, player.positionMs)
        idle(4_000)
        assertEquals(adoptedAt, saved("garden-1")!!.observedAtEpochMs)
        idle(2_000)
        assertTrue(saved("garden-1")!!.position!!.locator!!.offset()!! > 12_400)
    }

    @Test
    fun `a paused page turn stays the newest place through background and switching, until narration is heard again`() {
        val gardenBook = readium(overlay = true)
        val readAlong = coordinator(garden, gardenBook, null, null)
        readAlong.toggle(PageCues("OEBPS/chapter1.xhtml", "c1", null))
        idle(5_000)
        readAlong.toggle(null)
        idle()
        val pausedAt = player.positionMs
        // Turning pages while paused is reading: a normal place, newer than what was heard.
        val reading = SavedPosition(
            ReadAlongFixtures.EPUB_ID,
            buildJsonObject {
                put("href", "OEBPS/chapter2.xhtml")
                put("type", "application/xhtml+xml")
                putJsonObject("locations") { put("progression", 0.5); put("totalProgression", 0.8) }
            },
        )
        val readAt = wallClock()
        readAlong.onRead()
        runBlocking { services.progress.sync("garden-1").update(reading, readAt) }
        val readTime = saved("garden-1")!!.observedAtEpochMs!!
        assertTrue(readTime >= readAt)
        idle(1_000)
        // Leaving the app, and anything else that checkpoints, sees only the unchanged paused audio.
        controller.checkpointNow()
        idle()
        scope.launch { services.progress.sync("garden-1").flush() }
        idle()
        assertEquals(reading, saved("garden-1")!!.position)
        assertEquals(readTime, saved("garden-1")!!.observedAtEpochMs)
        // So the next Play is from the page read, exactly there.
        readAlong.toggle(PageCues("OEBPS/chapter2.xhtml", "c5", null))
        idle()
        assertEquals(10_000L, player.positionMs)
        readAlong.toggle(null)
        idle()

        // Another paused page turn, then narration actually heard again from a headset: that
        // hearing is the newest activity, so the app's Play then resumes it rather than the page.
        readAlong.onRead()
        runBlocking { services.progress.sync("garden-1").update(reading.copy(locator = JsonObject(reading.locator!! + ("title" to kotlinx.serialization.json.JsonPrimitive("again")))), wallClock()) }
        player.playFromOutside() // a genuine resume: five seconds back, once
        idle(8_000)
        readAlong.toggle(null)
        idle()
        val heardTo = player.positionMs
        assertTrue(heardTo > 12_000)
        readAlong.toggle(PageCues("OEBPS/chapter1.xhtml", "c1", null))
        idle()
        assertEquals(heardTo - 5_000, player.positionMs)
        assertTrue(pausedAt < heardTo)
    }

    @Test
    fun `a later audiobook place is offered even with narration loaded, and taking it moves the loaded player`() {
        val lighthouseBook = readium(overlay = false)
        val opening = heard(ReadAlongFixtures.importedManifest(), "epub-lighthouse", ReadAlongFixtures.OTHER_GENERATION, 0, 2_500)
        val first = coordinator(lighthouse, lighthouseBook, opening, wallClock() - 3_600_000)
        first.toggle(null)
        idle(1_000)
        first.toggle(null)
        idle()
        first.close()
        val listenedAt = System.currentTimeMillis() - 1_000
        audiobookProgress = """{"progress":{"asset_id":"lh-2","position_seconds":7.5,"version":9,"observed_at":"${ActivityTime.format(listenedAt)}"}}"""

        // Back in the book with its narration still loaded and paused.
        val second = coordinator(lighthouse, lighthouseBook, saved("lighthouse-1")!!.position, saved("lighthouse-1")!!.observedAtEpochMs)
        idle()
        val offer = (second.ui.value as ReadAlongUi.Ready).offer
        assertNotNull("no offer: ${second.ui.value}", offer)
        assertEquals(7_500L, offer!!.place.offsetMs)
        val before = saved("lighthouse-1")
        second.useOffer()
        idle()
        assertEquals(1, player.trackIndex)
        assertEquals(2_500L, player.positionMs)
        // Taking the offer writes nothing: it is restoring, not listening.
        assertEquals(before, saved("lighthouse-1"))
        player.playFromOutside()
        idle(3_000)
        assertEquals(before, saved("lighthouse-1"))
        idle(3_000)
        val book = saved("lighthouse-1")!!
        val audio = saved("lighthouse-audio-1")!!
        assertEquals("c7", book.position!!.locator!!.fragment())
        assertEquals("lh-2", audio.position!!.assetId)
        assertEquals(book.observedAtEpochMs, audio.observedAtEpochMs)
    }

    private companion object {
        const val GARDEN_MANIFEST = "/api/consumer/v1/library/garden-1/assets/epub-garden/read_along"
        const val LIGHTHOUSE_MANIFEST = "/api/consumer/v1/library/lighthouse-1/assets/epub-lighthouse/read_along"
    }
}
