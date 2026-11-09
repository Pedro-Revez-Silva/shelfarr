package org.shelfarr.app.playback

import android.app.Application
import android.os.Looper
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import java.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContractServer
import org.shelfarr.app.core.HeardPlaceMapper
import org.shelfarr.app.core.LocalProgress
import org.shelfarr.app.core.MemoryStore
import org.shelfarr.app.core.ProgressRemote
import org.shelfarr.app.core.ProgressStore
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadAlong
import org.shelfarr.app.core.ReadAlongFixtures
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.SyncTiming
import org.shelfarr.app.core.TEST_EPOCH
import org.shelfarr.app.core.cueJson

/**
 * Read-along narration through the same controller, checkpoints and sync as audiobooks.
 * Places come only from narration actually heard, with the time it was heard.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ReadAlongPlaybackTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val player = FakeAudioPlayer()
    private val address = (ServerAddress.parse("https://books.example") as ServerAddress.ParseResult.Valid).address
    private val hrefs = listOf("OEBPS/chapter1.xhtml", "OEBPS/chapter2.xhtml")

    /** One device store for every publication, logging each distinct place as it lands on disk. */
    private val store = object : ProgressStore {
        val memory = MemoryStore()
        val writes = mutableListOf<Triple<Long, String, SavedPosition>>()
        override suspend fun get(publicationId: String) = memory.get(publicationId)
        override suspend fun put(record: LocalProgress) {
            val position = record.position
            if (position != null && position != memory.records[record.publicationId]?.position) {
                writes += Triple(SystemClock.elapsedRealtime(), record.publicationId, position)
            }
            memory.put(record)
        }
        override suspend fun unsynced() = memory.unsynced()
    }

    private val ebookServer = ContractServer(now = ::wallClock, assets = setOf(ReadAlongFixtures.EPUB_ID, "epub-lighthouse"))
    private val audioServer = ContractServer(now = ::wallClock, assets = setOf("lh-1", "lh-2"))

    /** What the other publication had on this device when each send left. */
    private val seenAtSend = mutableListOf<Pair<String, Long?>>()

    private fun wallClock() = TEST_EPOCH + SystemClock.elapsedRealtime()

    private val controller = PlaybackController(
        ApplicationProvider.getApplicationContext(),
        scope,
        connect = { player },
        wallClock = ::wallClock,
        elapsed = SystemClock::elapsedRealtime,
    )

    private fun sync(id: String, server: ContractServer, other: String) = ProgressSync(
        id, store,
        ProgressRemote { _, update ->
            seenAtSend += id to store.memory.records[other]?.observedAtEpochMs
            server.save(update)
        },
        scope, now = ::wallClock, timing = SyncTiming(),
    )

    private val ebook = sync("garden-1", ebookServer, "lighthouse-audio-1")
    private val audiobook = sync("lighthouse-audio-1", audioServer, "garden-1")

    @After
    fun tearDown() = scope.cancel()

    private fun idle(ms: Long = 0) {
        val looper = shadowOf(Looper.getMainLooper())
        if (ms > 0) looper.idleFor(Duration.ofMillis(ms)) else looper.idle()
    }

    private fun readAlong(manifest: String, asset: String, generation: String) = ReadAlong.read(manifest.byteInputStream(), asset, generation, address)

    private fun queue(readAlong: ReadAlong, paired: ProgressSync? = null) = NarrationQueue(
        publication = Publication(id = "garden-1", title = "The Narrated Garden", bookType = BookType.EBOOK),
        info = NarrationInfo("garden-1", readAlong.generation),
        sources = readAlong.tracks.map { NarrationSource("narration:${it.index}", "https://books.example/n/${it.index}", it.label) },
        sink = ReadAlongSink(HeardPlaceMapper(readAlong, hrefs, listOf(0.0, 0.5)), ebook, paired),
        fromDevice = false,
        coverUri = null,
    )

    private fun overlay() = readAlong(ReadAlongFixtures.overlayManifest(), ReadAlongFixtures.EPUB_ID, ReadAlongFixtures.GENERATION)

    private fun load(queue: NarrationQueue, start: NarrationStart) = runBlocking {
        controller.loadNarration(queue, start)
        idle()
    }

    private fun ebookPlaces() = store.writes.filter { it.second == "garden-1" }

    private fun JsonObject.point() = this["locations"]!!.jsonObject["readAlong"]!!.jsonObject
    private fun JsonObject.fragment() = this["locations"]!!.jsonObject["fragments"]!!.jsonArray.single().jsonPrimitive.content
    private fun saved(id: String = "garden-1") = store.memory.records[id]

    @Test
    fun `listening checkpoints are at most five seconds apart, each the reached cue with the offset heard`() {
        load(queue(overlay()), NarrationStart(0, 0, resume = false))
        repeat(30) { idle(500) }
        val places = ebookPlaces()
        assertTrue("places: ${places.size}", places.size >= 3)
        assertTrue("gaps ${places.zipWithNext { a, b -> b.first - a.first }}", places.zipWithNext { a, b -> b.first - a.first }.all { it <= 5_000 })
        for ((at, _, position) in places) {
            val locator = position.locator!!
            val offset = locator.point()["offset_ms"]!!.jsonPrimitive.long
            // The element is the cue reached at that offset; the offset is what was heard then.
            assertEquals("c${(offset / 2_000).coerceAtMost(7)}", locator.fragment())
            assertTrue("heard $offset at $at", offset in 0..at)
        }
        val record = saved()!!
        assertEquals(wallClock() - (SystemClock.elapsedRealtime() - places.last().first), record.observedAtEpochMs)
        assertNull("a media overlay writes no audiobook place", saved("lighthouse-audio-1"))
    }

    @Test
    fun `nothing is written before the first cue is reached`() {
        val late = readAlong(
            ReadAlongFixtures.overlayManifest(cues = ReadAlongFixtures.CUES.map { cueJson(it[0], "c${it[1]}", 0, it[2] + 6_000, it[3] + 6_000) }),
            ReadAlongFixtures.EPUB_ID,
            ReadAlongFixtures.GENERATION,
        )
        load(queue(late), NarrationStart(0, 0, resume = false))
        repeat(10) { idle(500) }
        assertTrue(ebookPlaces().isEmpty())
        repeat(6) { idle(500) }
        val first = ebookPlaces().first().third.locator!!
        assertTrue(first.point()["offset_ms"]!!.jsonPrimitive.long >= 6_000)
        assertTrue(first.fragment() in setOf("c0", "c1"))
    }

    @Test
    fun `an imported checkpoint writes the ebook and audiobook with one time, both on this device before either is sent`() {
        val imported = readAlong(ReadAlongFixtures.importedManifest(), "epub-lighthouse", ReadAlongFixtures.OTHER_GENERATION)
        val narration = NarrationQueue(
            publication = Publication(id = "garden-1", title = "The Paired Lighthouse", bookType = BookType.EBOOK),
            info = NarrationInfo("garden-1", imported.generation),
            sources = imported.tracks.map { NarrationSource("narration:${it.index}", "https://books.example/n/${it.index}", it.label) },
            sink = ReadAlongSink(HeardPlaceMapper(imported, hrefs), ebook, audiobook),
            fromDevice = false,
            coverUri = null,
        )
        load(narration, NarrationStart(1, 2_000, resume = false))
        idle(3_000)
        controller.togglePlay()
        idle()
        idle(6_000)
        val book = saved()!!
        val audio = saved("lighthouse-audio-1")!!
        assertEquals(book.observedAtEpochMs, audio.observedAtEpochMs)
        assertEquals("lh-2", audio.position!!.assetId)
        assertEquals(book.position!!.locator!!.point()["offset_ms"]!!.jsonPrimitive.long / 1_000.0, audio.position!!.positionSeconds!!, 0.0005)
        // Pausing sent both; when each left, the other was already saved with the same time.
        assertTrue(seenAtSend.isNotEmpty())
        for ((sender, other) in seenAtSend) {
            val own = saved(sender)!!.observedAtEpochMs
            assertEquals("$sender sent before its pair was saved", own, other)
        }
        assertEquals(ebookServer.stored!!.observedAt, audioServer.stored!!.observedAt)
    }

    @Test
    fun `resuming an exact place rewinds five seconds once and keeps the saved place through the replay`() {
        val heardAt = wallClock() - 120_000
        val exact = SavedPosition(ReadAlongFixtures.EPUB_ID, overlay().locatorFor(0, 13_743, hrefs::get) { null })
        runBlocking { ebook.begin(exact, 2, heardAt, listOf(ReadAlongFixtures.EPUB_ID)) }
        load(queue(overlay()), NarrationStart(0, 13_743, resume = true))
        assertEquals(8_743L, player.positionMs)
        idle(2_000)
        controller.togglePlay() // pause inside the replayed span
        idle()
        assertEquals(exact, saved()!!.position)
        assertEquals(heardAt, saved()!!.observedAtEpochMs)
        controller.togglePlay() // a second resume within the replay does not rewind again
        idle()
        assertEquals(10_743L, player.positionMs)
        idle(1_500)
        controller.togglePlay()
        idle()
        assertEquals(exact, saved()!!.position)
        assertTrue(ebookServer.received.isEmpty())
        // Playing on past the saved place is new listening.
        controller.togglePlay()
        idle(5_000)
        assertTrue(saved()!!.position!!.locator!!.point()["offset_ms"]!!.jsonPrimitive.long > 13_743)
    }

    @Test
    fun `a cue chosen on the page plays exactly there and counts at once`() {
        load(queue(overlay()), NarrationStart(0, 12_000, resume = false))
        assertEquals(12_000L, player.positionMs)
        idle(600)
        val first = ebookPlaces().first()
        assertEquals("c6", first.third.locator!!.fragment())
        assertTrue(first.third.locator!!.point()["offset_ms"]!!.jsonPrimitive.long in 12_000..12_700)
        // While playing, a later choice on the page is again exact and immediate.
        controller.playNarrationAt(0, 4_000)
        idle()
        assertEquals("c2", saved()!!.position!!.locator!!.fragment())
    }

    @Test
    fun `switching from an audiobook to narration saves the audiobook's last place first`() {
        val book = Publication(
            id = "lighthouse-audio-1", title = "Audio", bookType = BookType.AUDIOBOOK,
            assets = listOf(Asset("lh-1", "1.wav", "audio/wav", "wav", 1, "/files/lh-1", 0), Asset("lh-2", "2.wav", "audio/wav", "wav", 1, "/files/lh-2", 1)),
        )
        runBlocking {
            audiobook.begin(null, 0, null, listOf("lh-1", "lh-2"))
            controller.load(book, address, audiobook, null)
        }
        idle(7_250)
        load(queue(overlay()), NarrationStart(0, 0, resume = false))
        assertEquals(SavedPosition("lh-1", positionSeconds = 7.25), saved("lighthouse-audio-1")!!.position)
        assertEquals("garden-1", controller.snapshot.value.publication?.id)
        assertEquals(NarrationInfo("garden-1", ReadAlongFixtures.GENERATION), controller.snapshot.value.narration)
    }

    @Test
    fun `a lost answer is retried with the same body, mutation id and activity time`() {
        ebookServer.failBefore += ApiException.Offline()
        load(queue(overlay()), NarrationStart(0, 4_000, resume = false))
        idle(1_000)
        controller.togglePlay()
        idle()
        val attempt = ebookServer.received.single()
        // The retry waits behind the first attempt and repeats it exactly.
        idle(6_000)
        val retry = ebookServer.received.last()
        assertEquals(attempt, retry)
        assertEquals(attempt.clientMutationId, ebookServer.stored!!.clientMutationId)
        assertTrue(attempt.locator!!.point().containsKey("offset_ms"))
    }

    @Test
    fun `an audiobook place adopted after a conflict is restored, not listened to, also for a lock-screen play`() {
        val book = Publication(
            id = "lighthouse-audio-1", title = "Audio", bookType = BookType.AUDIOBOOK,
            assets = listOf(Asset("lh-1", "1.wav", "audio/wav", "wav", 1, "/files/lh-1", 0), Asset("lh-2", "2.wav", "audio/wav", "wav", 1, "/files/lh-2", 1)),
        )
        runBlocking {
            audiobook.begin(null, 0, null, listOf("lh-1", "lh-2"))
            controller.load(book, address, audiobook, null)
        }
        idle(3_000)
        controller.togglePlay()
        idle()
        // "Use other device": that place and its own time are adopted.
        val adoptedAt = wallClock() - 30_000
        val adopted = SavedPosition("lh-2", positionSeconds = 40.0)
        runBlocking { audiobook.begin(adopted, 5, adoptedAt, listOf("lh-1", "lh-2")) }
        controller.jumpTo(adopted)
        idle()
        assertEquals(1, player.trackIndex)
        assertEquals(35_000L, player.positionMs)
        assertEquals(adopted, saved("lighthouse-audio-1")!!.position)
        player.playFromOutside()
        idle(4_000)
        assertEquals(adopted, saved("lighthouse-audio-1")!!.position)
        assertEquals(adoptedAt, saved("lighthouse-audio-1")!!.observedAtEpochMs)
        idle(2_000)
        assertTrue(saved("lighthouse-audio-1")!!.position!!.positionSeconds!! > 40.0)
    }
}
