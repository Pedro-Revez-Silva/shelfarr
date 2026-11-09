package org.shelfarr.app.core

import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Read-along narration kept with a downloaded book, over real HTTP and files. The book is
 * readable as soon as its own file is complete; narration is offered offline only when its
 * manifest and every file are present for one generation.
 */
class NarrationDownloadTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private val scopes = mutableListOf<CoroutineScope>()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()
    private val routes = HashMap<String, (RecordedRequest) -> MockResponse>()

    private val gardenEpub = ReadAlongFixtures.epub(overlay = true)
    private val lighthouseEpub = ReadAlongFixtures.epub(overlay = false)
    private val track1 = ReadAlongFixtures.wav(8_000)
    private val track2 = ReadAlongFixtures.wav(8_000).also { it[it.size - 1] = 7 }

    private var gardenGeneration = ReadAlongFixtures.GENERATION
    private var publications = mapOf<String, Publication>()

    private fun summary(source: String, generation: String, manifest: String, audio: Long) =
        ReadAlongSummary("available", source, generation, manifest, audioBytes = audio)

    private fun garden() = Publication(
        id = "garden-1", title = "The Narrated Garden", bookType = BookType.EBOOK,
        assets = listOf(
            Asset(
                ReadAlongFixtures.EPUB_ID, "garden.epub", "application/epub+zip", "epub", gardenEpub.size.toLong(), "/files/epub-garden",
                readAlong = summary("media_overlay", gardenGeneration, GARDEN_MANIFEST, ReadAlongFixtures.narration.size.toLong()),
            ),
        ),
    )

    private fun lighthouse() = Publication(
        id = "lighthouse-1", title = "The Paired Lighthouse", bookType = BookType.EBOOK,
        assets = listOf(
            Asset(
                "epub-lighthouse", "lighthouse.epub", "application/epub+zip", "epub", lighthouseEpub.size.toLong(), "/files/epub-lighthouse",
                readAlong = summary("imported", ReadAlongFixtures.OTHER_GENERATION, LIGHTHOUSE_MANIFEST, (track1.size + track2.size).toLong()),
            ),
        ),
    )

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                // Only this account's credential, on every request.
                if (request.headers["Authorization"] != "Bearer secret") return MockResponse.Builder().code(401).build()
                val route = routes[request.target.substringBefore('?')] ?: return MockResponse.Builder().code(404).build()
                return route(request)
            }
        }
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        routes["/files/epub-garden"] = { bytes(gardenEpub, "\"g\"") }
        routes["/files/epub-lighthouse"] = { bytes(lighthouseEpub, "\"l\"") }
        routes["/files/lh-1"] = { bytes(track1, "\"lh1\"") }
        routes["/files/lh-2"] = { bytes(track2, "\"lh2\"") }
        routes[GARDEN_MANIFEST] = { json(ReadAlongFixtures.overlayManifest(generation = gardenGeneration)) }
        routes[LIGHTHOUSE_MANIFEST] = { json(ReadAlongFixtures.importedManifest(trackSizes = listOf(track1.size, track2.size))) }
        publications = mapOf("garden-1" to garden(), "lighthouse-1" to lighthouse())
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        web.close()
    }

    private fun bytes(data: ByteArray, etag: String) = MockResponse.Builder().code(200).addHeader("ETag", etag).body(Buffer().write(data)).build()
    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private val root get() = File(folder.root, "acct/downloads")

    private fun manager(): DownloadManager {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scopes += it }
        return DownloadManager(
            root = root,
            client = buildHttpClient({ Credential(server, "secret") }),
            server = server,
            fetchPublication = { id -> publications[id] ?: throw ApiException.NotFound() },
            scope = scope,
            usableSpace = { Long.MAX_VALUE },
        ).also { runBlocking { it.start() } }
    }

    private fun DownloadManager.await(id: String, condition: (DownloadRecord) -> Boolean): DownloadRecord = runBlocking {
        withTimeout(15_000) { records.first { it[id]?.let(condition) == true } }[id]!!
    }

    private fun narrationFiles(id: String): List<String> {
        val book = File(root, folderOf(id))
        return book.listFiles().orEmpty().map { it.name }.filter { it.startsWith("ra-") }.sorted()
    }

    private fun folderOf(id: String) = java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).take(16).joinToString("") { "%02x".format(it) }

    @Test
    fun `media overlay narration is copied out of the downloaded EPUB and plays offline only when whole`() {
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        val record = downloads.await("garden-1") { it.narration?.isReady == true }
        assertTrue(record.isReady)
        val local = requireNotNull(downloads.narrationFor(record))
        assertEquals(ReadAlongFixtures.GENERATION, local.generation)
        assertArrayEquals(ReadAlongFixtures.narration, local.tracks.single().readBytes())
        // The stored manifest is the server's and still checks out against this edition.
        val manifest = local.manifest.inputStream().use { ReadAlong.read(it, ReadAlongFixtures.EPUB_ID, ReadAlongFixtures.GENERATION, server) }
        assertEquals(8, manifest.cueCount)
        // No narration bytes were fetched twice: the audio came from the EPUB on this device.
        assertFalse(requests.any { it.target.contains("/read_along/resources/") })
        assertEquals(record.files.single().sizeBytes + ReadAlongFixtures.narration.size, record.bytesDone)
        // A missing file after a restart is never offered, and the book still reads offline.
        local.tracks.single().delete()
        val restarted = manager()
        val reloaded = restarted.record("garden-1")!!
        assertTrue(reloaded.isReady)
        assertEquals(NarrationState.FAILED, reloaded.narration!!.state)
        assertEquals(DownloadProblem.MISSING, reloaded.narration!!.problem)
        assertNull(restarted.narrationFor(reloaded))
        assertNotNull(restarted.fileFor(reloaded, ReadAlongFixtures.EPUB_ID))
    }

    @Test
    fun `an imported alignment's audiobook files are fetched with this account, and a failure leaves the book readable`() {
        routes["/files/lh-2"] = { MockResponse.Builder().code(404).build() }
        val downloads = manager()
        runBlocking { downloads.enqueue(lighthouse(), narration = true) }
        val failed = downloads.await("lighthouse-1") { it.narration?.state == NarrationState.FAILED }
        assertTrue(failed.isReady)
        assertEquals(DownloadProblem.NOT_FOUND, failed.narration!!.problem)
        assertNull(downloads.narrationFor(failed))
        assertNotNull(downloads.fileFor(failed, "epub-lighthouse"))
        assertTrue(failed.narration!!.tracks[0].complete)
        // Retrying resumes: the complete first file is not fetched again.
        routes["/files/lh-2"] = { bytes(track2, "\"lh2\"") }
        val before = requests.count { it.target == "/files/lh-1" }
        runBlocking { downloads.retry("lighthouse-1") }
        val ready = downloads.await("lighthouse-1") { it.narration?.isReady == true }
        assertEquals(before, requests.count { it.target == "/files/lh-1" })
        val local = downloads.narrationFor(ready)!!
        assertArrayEquals(track1, local.tracks[0].readBytes())
        assertArrayEquals(track2, local.tracks[1].readBytes())
        assertTrue(requests.all { it.headers["Authorization"] == "Bearer secret" })
    }

    @Test
    fun `a text-only download fetches no narration`() {
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = false) }
        val ready = downloads.await("garden-1") { it.isReady }
        Thread.sleep(200)
        assertNull(ready.narration)
        assertFalse(requests.any { it.target.contains("read_along") })
        assertTrue(narrationFiles("garden-1").isEmpty())
    }

    @Test
    fun `a newer generation is fetched beside the old one, which stays in use until the new one is whole`() {
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        downloads.await("garden-1") { it.narration?.isReady == true }
        val oldFiles = narrationFiles("garden-1")

        gardenGeneration = "3".repeat(64)
        publications = mapOf("garden-1" to garden())
        routes[GARDEN_MANIFEST] = { MockResponse.Builder().code(500).build() }
        runBlocking { downloads.enqueue(garden(), narration = true) }
        val failed = downloads.await("garden-1") { it.narrationUpdate?.state == NarrationState.FAILED || it.narration?.state == NarrationState.FAILED }
        // The update failed; the complete earlier narration is untouched and still offered.
        assertEquals(ReadAlongFixtures.GENERATION, downloads.narrationFor(failed)!!.generation)
        assertEquals(oldFiles, narrationFiles("garden-1"))

        routes[GARDEN_MANIFEST] = { json(ReadAlongFixtures.overlayManifest(generation = gardenGeneration)) }
        runBlocking { downloads.retry("garden-1") }
        val updated = downloads.await("garden-1") { it.narration?.generation == gardenGeneration && it.narration?.isReady == true }
        assertNull(updated.narrationUpdate)
        assertEquals(gardenGeneration, downloads.narrationFor(updated)!!.generation)
        // Only now are the old generation's files gone.
        assertTrue(narrationFiles("garden-1").none { it in oldFiles })
    }

    /** Holds the manifest request open until [release], counting down [started] when it arrives. */
    private fun holdManifest(path: String, body: () -> String): Pair<CountDownLatch, CountDownLatch> {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        routes[path] = {
            started.countDown()
            release.await(10, TimeUnit.SECONDS)
            json(body())
        }
        return started to release
    }

    @Test
    fun `removing narration while its manifest is still being fetched leaves nothing to save or promote`() {
        val (started, release) = holdManifest(LIGHTHOUSE_MANIFEST) { ReadAlongFixtures.importedManifest(trackSizes = listOf(track1.size, track2.size)) }
        val downloads = manager()
        runBlocking { downloads.enqueue(lighthouse(), narration = true) }
        assertTrue(started.await(10, TimeUnit.SECONDS))
        // Suspended in the manifest fetch: no narration work is recorded yet.
        assertNull(downloads.record("lighthouse-1")!!.narrationWork)
        runBlocking { downloads.removeNarration("lighthouse-1") }
        release.countDown()
        runBlocking { delay(500) }
        val record = downloads.record("lighthouse-1")!!
        assertTrue(record.isReady)
        assertFalse(record.withNarration)
        assertNull(record.narration)
        assertNull(record.narrationUpdate)
        assertTrue(narrationFiles("lighthouse-1").isEmpty())
        assertFalse(requests.any { it.target.startsWith("/files/lh-") })
    }

    @Test
    fun `removing the book during the manifest fetch can't bring narration back`() {
        val (started, release) = holdManifest(GARDEN_MANIFEST) { ReadAlongFixtures.overlayManifest() }
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        assertTrue(started.await(10, TimeUnit.SECONDS))
        runBlocking { downloads.remove("garden-1") }
        release.countDown()
        runBlocking { delay(500) }
        assertNull(downloads.record("garden-1"))
        assertFalse(File(root, folderOf("garden-1")).exists())
    }

    @Test
    fun `stopping an update during its manifest fetch keeps the earlier ready generation`() {
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        downloads.await("garden-1") { it.narration?.isReady == true }
        val oldFiles = narrationFiles("garden-1")
        gardenGeneration = "4".repeat(64)
        publications = mapOf("garden-1" to garden())
        val (started, release) = holdManifest(GARDEN_MANIFEST) { ReadAlongFixtures.overlayManifest(generation = gardenGeneration) }
        runBlocking { downloads.enqueue(garden(), narration = true) }
        assertTrue(started.await(10, TimeUnit.SECONDS))
        runBlocking { downloads.removeNarration("garden-1", removeAll = false) }
        release.countDown()
        runBlocking { delay(500) }
        val record = downloads.record("garden-1")!!
        assertEquals(ReadAlongFixtures.GENERATION, downloads.narrationFor(record)!!.generation)
        assertNull(record.narrationUpdate)
        assertEquals(oldFiles, narrationFiles("garden-1"))
    }

    @Test
    fun `cancelling a ready book's narration transfer, as the notification does, keeps the book`() {
        val (started, release) = holdManifest(GARDEN_MANIFEST) { ReadAlongFixtures.overlayManifest() }
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        assertTrue(started.await(10, TimeUnit.SECONDS))
        assertTrue(downloads.record("garden-1")!!.let { it.isReady && it.isActive })
        runBlocking { downloads.cancel("garden-1") }
        release.countDown()
        runBlocking { delay(500) }
        val record = downloads.record("garden-1")!!
        assertTrue(record.isReady)
        assertFalse(record.isActive)
        assertNotNull(downloads.fileFor(record, ReadAlongFixtures.EPUB_ID))
        assertTrue(narrationFiles("garden-1").isEmpty())
    }

    @Test
    fun `removing narration keeps the book`() {
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        downloads.await("garden-1") { it.narration?.isReady == true }
        runBlocking { downloads.removeNarration("garden-1") }
        val record = downloads.record("garden-1")!!
        assertTrue(record.isReady)
        assertNull(downloads.narrationFor(record))
        assertTrue(narrationFiles("garden-1").isEmpty())
        assertNotNull(downloads.fileFor(record, ReadAlongFixtures.EPUB_ID))
    }

    private companion object {
        const val GARDEN_MANIFEST = "/api/consumer/v1/library/garden-1/assets/epub-garden/read_along"
        const val LIGHTHOUSE_MANIFEST = "/api/consumer/v1/library/lighthouse-1/assets/epub-lighthouse/read_along"
    }
}
