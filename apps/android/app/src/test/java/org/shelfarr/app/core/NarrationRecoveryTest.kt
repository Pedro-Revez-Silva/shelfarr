package org.shelfarr.app.core

import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArraySet
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
import mockwebserver3.SocketEffect
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
 * A narration request stopped before its manifest was pinned is durable intent: it survives
 * interruption, restarts and an expired sign-in, and resumes for the same account, without
 * looking ready, dropping the request, touching the book or anything another account holds.
 *
 * Every relaunch is a fresh [DownloadManager] over the same files, as after process death.
 * The fixture server answers only the tokens an account currently holds.
 */
class NarrationRecoveryTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private val scopes = mutableListOf<CoroutineScope>()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()
    private val routes = HashMap<String, (RecordedRequest) -> MockResponse>()

    /** Tokens the server currently accepts. An expired sign-in is a token removed from here. */
    private val accepted = CopyOnWriteArraySet(listOf(ACCOUNT_A_TOKEN))

    private val gardenEpub = ReadAlongFixtures.epub(overlay = true)
    private val lighthouseEpub = ReadAlongFixtures.epub(overlay = false)
    private val track1 = ReadAlongFixtures.wav(8_000)
    private val track2 = ReadAlongFixtures.wav(8_000).also { it[it.size - 1] = 7 }
    private var gardenGeneration = ReadAlongFixtures.GENERATION

    private fun garden() = Publication(
        id = "garden-1", title = "The Narrated Garden", bookType = BookType.EBOOK,
        assets = listOf(
            Asset(
                ReadAlongFixtures.EPUB_ID, "garden.epub", "application/epub+zip", "epub", gardenEpub.size.toLong(), "/files/epub-garden",
                readAlong = ReadAlongSummary("available", "media_overlay", gardenGeneration, GARDEN_MANIFEST, audioBytes = ReadAlongFixtures.narration.size.toLong()),
            ),
        ),
    )

    private fun lighthouse() = Publication(
        id = "lighthouse-1", title = "The Paired Lighthouse", bookType = BookType.EBOOK,
        assets = listOf(
            Asset(
                "epub-lighthouse", "lighthouse.epub", "application/epub+zip", "epub", lighthouseEpub.size.toLong(), "/files/epub-lighthouse",
                readAlong = ReadAlongSummary("available", "imported", ReadAlongFixtures.OTHER_GENERATION, LIGHTHOUSE_MANIFEST, audioBytes = (track1.size + track2.size).toLong()),
            ),
        ),
    )

    private fun audiobook() = Publication(
        id = "lighthouse-audio-1", title = "The Paired Lighthouse", bookType = BookType.AUDIOBOOK,
        assets = listOf(
            Asset("lh-1", "Lighthouse 1.wav", "audio/wav", "wav", track1.size.toLong(), "/files/lh-1", 0),
            Asset("lh-2", "Lighthouse 2.wav", "audio/wav", "wav", track2.size.toLong(), "/files/lh-2", 1),
        ),
    )

    private fun publications() = mapOf("garden-1" to garden(), "lighthouse-1" to lighthouse(), "lighthouse-audio-1" to audiobook())

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val token = request.headers["Authorization"]?.removePrefix("Bearer ")
                if (token !in accepted) return MockResponse.Builder().code(401).build()
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
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        web.close()
    }

    private fun bytes(data: ByteArray, etag: String) = MockResponse.Builder().code(200).addHeader("ETag", etag).body(Buffer().write(data)).build()
    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private fun root(account: String) = File(folder.root, "accounts/$account/downloads")

    /** A fresh manager over [account]'s files, holding [token], as a new process would build it. */
    private fun manager(account: String = "account-a", token: String = ACCOUNT_A_TOKEN): DownloadManager {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scopes += it }
        return DownloadManager(
            root = root(account),
            client = buildHttpClient({ Credential(server, token) }),
            server = server,
            fetchPublication = { id -> publications()[id] ?: throw ApiException.NotFound() },
            scope = scope,
            usableSpace = { Long.MAX_VALUE },
        ).also { runBlocking { it.start() } }
    }

    private fun DownloadManager.await(id: String, condition: (DownloadRecord) -> Boolean): DownloadRecord = runBlocking {
        withTimeout(15_000) { records.first { it[id]?.let(condition) == true } }[id]!!
    }

    /** Holds [path]'s next answer until released, counting down once the request arrives. */
    private fun hold(path: String, answer: () -> MockResponse): Pair<CountDownLatch, CountDownLatch> {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val normal = routes.getValue(path)
        routes[path] = {
            started.countDown()
            release.await(10, TimeUnit.SECONDS)
            routes[path] = normal
            answer()
        }
        return started to release
    }

    private fun folderOf(id: String) =
        java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).take(16).joinToString("") { "%02x".format(it) }

    private fun narrationFiles(account: String, id: String) =
        File(root(account), folderOf(id)).listFiles().orEmpty().map { it.name }.filter { it.startsWith("ra-") }.sorted()

    private fun manifestRequests(path: String) = requests.count { it.target.substringBefore('?') == path }

    /** A ready book whose narration request is in flight, its manifest request held open. */
    private fun readyBookAskingForNarration(downloads: DownloadManager, book: Publication, manifest: String): CountDownLatch {
        runBlocking { downloads.enqueue(book, narration = false) }
        downloads.await(book.id) { it.isReady }
        val (started, release) = hold(manifest) { json(if (manifest == GARDEN_MANIFEST) ReadAlongFixtures.overlayManifest(generation = gardenGeneration) else ReadAlongFixtures.importedManifest(trackSizes = listOf(track1.size, track2.size))) }
        runBlocking { downloads.enqueue(book, narration = true) }
        assertTrue("the manifest was never asked for", started.await(10, TimeUnit.SECONDS))
        val asking = downloads.record(book.id)!!
        assertTrue(asking.isReady && asking.isActive && asking.narrationRequested)
        return release
    }

    /** The stopped request as the person sees it: a ready book, nothing that looks like narration, a reason. */
    private fun assertStoppedBeforeManifest(downloads: DownloadManager, id: String, problem: DownloadProblem) {
        val record = downloads.record(id)!!
        assertTrue("the book must stay ready: $record", record.isReady)
        assertNotNull(downloads.fileFor(record, record.files.single().assetId))
        assertFalse("a stopped request isn't running", record.isActive)
        assertTrue(record.withNarration && record.narrationRequested)
        assertEquals(problem, record.narrationProblem)
        assertEquals(problem, record.narrationStopProblem)
        assertTrue(record.narrationFailedFor(setOf(problem)))
        // Nothing was pinned for this request, so nothing about it can look downloaded.
        assertNull(record.narrationUpdate)
        assertTrue(record.narration == null || record.narration!!.isReady)
    }

    @Test
    fun `an interruption before the manifest keeps the request and why, through restarts, and resumes from a fresh start`() {
        val first = manager()
        val release = readyBookAskingForNarration(first, garden(), GARDEN_MANIFEST)
        runBlocking { first.close() }
        release.countDown()

        // A new process with no host scheduled says what happened instead of restarting it unasked.
        val second = manager()
        assertTrue(second.record("garden-1")!!.isActive)
        runBlocking { second.interruptInherited() }
        assertStoppedBeforeManifest(second, "garden-1", DownloadProblem.INTERRUPTED)
        assertNull(second.narrationFor(second.record("garden-1")!!))
        assertTrue(narrationFiles("account-a", "garden-1").isEmpty())

        // Still there after another restart, and nothing restarted it on its own.
        val asked = manifestRequests(GARDEN_MANIFEST)
        runBlocking { second.close() }
        val third = manager()
        runBlocking { third.interruptInherited() }
        assertStoppedBeforeManifest(third, "garden-1", DownloadProblem.INTERRUPTED)
        assertEquals(asked, manifestRequests(GARDEN_MANIFEST))

        // The person resumes it: the whole narration arrives for the same generation.
        runBlocking { third.retry("garden-1") }
        val ready = third.await("garden-1") { it.narration?.isReady == true && !it.isActive }
        assertNull(ready.narrationProblem)
        assertFalse(ready.narrationPending)
        assertArrayEquals(ReadAlongFixtures.narration, third.narrationFor(ready)!!.tracks.single().readBytes())
    }

    @Test
    fun `an expired sign-in before the manifest resumes when the same account signs in again`() {
        val first = manager()
        val release = readyBookAskingForNarration(first, garden(), GARDEN_MANIFEST)
        // The connection expires: its token stops working and the account's services close as signed out.
        accepted -= ACCOUNT_A_TOKEN
        runBlocking { first.close(signedOut = true) }
        release.countDown()

        val expired = manager(token = ACCOUNT_A_TOKEN)
        assertStoppedBeforeManifest(expired, "garden-1", DownloadProblem.SIGN_IN)
        runBlocking { expired.close(signedOut = true) }

        // The same account signs in again with a new token: its stopped request carries on.
        accepted += ACCOUNT_A_RENEWED
        val renewed = manager(token = ACCOUNT_A_RENEWED)
        runBlocking { renewed.resumeAfterSignIn() }
        val ready = renewed.await("garden-1") { it.narration?.isReady == true && !it.isActive }
        assertNotNull(renewed.narrationFor(ready))
        val after = requests.filter { it.target.startsWith(GARDEN_MANIFEST) }.last()
        assertEquals("Bearer $ACCOUNT_A_RENEWED", after.headers["Authorization"])
    }

    @Test
    fun `a host stopping before the manifest leaves the request queued for the next host`() {
        val first = manager()
        val release = readyBookAskingForNarration(first, garden(), GARDEN_MANIFEST)
        runBlocking { first.pause() }
        release.countDown()
        runBlocking { first.close() }

        val next = manager()
        val queued = next.record("garden-1")!!
        assertTrue(queued.isReady && queued.isActive && queued.narrationRequested)
        assertNull(queued.narrationProblem)
        runBlocking { next.resumeQueued() }
        assertNotNull(next.narrationFor(next.await("garden-1") { it.narration?.isReady == true && !it.isActive }))
    }

    @Test
    fun `a server or connection failure before the manifest is retried like any transient download`() {
        routes[GARDEN_MANIFEST] = { MockResponse.Builder().code(503).build() }
        val first = manager()
        runBlocking { first.enqueue(garden(), narration = true) }
        first.await("garden-1") { it.narrationProblem != null }
        assertStoppedBeforeManifest(first, "garden-1", DownloadProblem.SERVER)
        assertTrue(first.hasTransientFailures)
        runBlocking { first.close() }

        // The connection drops mid-answer on the foreground retry: still the same request, now offline.
        routes[GARDEN_MANIFEST] = {
            MockResponse.Builder().code(200).addHeader("Content-Type", "application/json")
                .body(Buffer().writeUtf8(ReadAlongFixtures.overlayManifest().take(40)))
                .setHeader("Content-Length", 4_000)
                .onResponseEnd(SocketEffect.ShutdownConnection)
                .build()
        }
        val second = manager()
        runBlocking { second.retryInterrupted() }
        second.await("garden-1") { it.narrationProblem == DownloadProblem.OFFLINE }
        assertStoppedBeforeManifest(second, "garden-1", DownloadProblem.OFFLINE)
        runBlocking { second.close() }

        // A running host resumes transient failures by itself.
        routes[GARDEN_MANIFEST] = { json(ReadAlongFixtures.overlayManifest()) }
        val host = manager()
        runBlocking { host.resumeTransient() }
        assertNotNull(host.narrationFor(host.await("garden-1") { it.narration?.isReady == true && !it.isActive }))
    }

    @Test
    fun `an update stopped before its manifest keeps the earlier generation in use, never the new one`() {
        val first = manager()
        runBlocking { first.enqueue(garden(), narration = true) }
        first.await("garden-1") { it.narration?.isReady == true && !it.isActive }
        val earlier = narrationFiles("account-a", "garden-1")

        gardenGeneration = "5".repeat(64)
        val (started, release) = hold(GARDEN_MANIFEST) { json(ReadAlongFixtures.overlayManifest(generation = gardenGeneration)) }
        runBlocking { first.enqueue(garden(), narration = true) }
        assertTrue(started.await(10, TimeUnit.SECONDS))
        accepted -= ACCOUNT_A_TOKEN
        runBlocking { first.close(signedOut = true) }
        release.countDown()

        val expired = manager()
        assertStoppedBeforeManifest(expired, "garden-1", DownloadProblem.SIGN_IN)
        // The complete earlier generation still plays offline; nothing claims the new one.
        assertEquals(ReadAlongFixtures.GENERATION, expired.narrationFor(expired.record("garden-1")!!)!!.generation)
        assertEquals(earlier, narrationFiles("account-a", "garden-1"))
        runBlocking { expired.close(signedOut = true) }

        accepted += ACCOUNT_A_RENEWED
        val renewed = manager(token = ACCOUNT_A_RENEWED)
        runBlocking { renewed.resumeAfterSignIn() }
        val updated = renewed.await("garden-1") { it.narration?.generation == gardenGeneration && it.narration?.isReady == true && !it.isActive }
        assertEquals(gardenGeneration, renewed.narrationFor(updated)!!.generation)
        // The earlier generation's files go only after the new one is recorded whole.
        runBlocking { withTimeout(5_000) { while (narrationFiles("account-a", "garden-1").any { it in earlier }) delay(20) } }
    }

    @Test
    fun `removing narration after an early stop leaves nothing any recovery path can resurrect`() {
        val first = manager()
        val release = readyBookAskingForNarration(first, garden(), GARDEN_MANIFEST)
        accepted -= ACCOUNT_A_TOKEN
        runBlocking { first.close(signedOut = true) }
        release.countDown()
        accepted += ACCOUNT_A_TOKEN

        val second = manager()
        assertStoppedBeforeManifest(second, "garden-1", DownloadProblem.SIGN_IN)
        runBlocking { second.removeNarration("garden-1") }
        val removed = second.record("garden-1")!!
        assertTrue(removed.isReady)
        assertFalse(removed.withNarration || removed.narrationPending)
        assertNull(removed.narrationProblem)
        runBlocking { second.close(signedOut = true) }

        val asked = manifestRequests(GARDEN_MANIFEST)
        val third = manager()
        runBlocking {
            third.resumeAfterSignIn()
            third.interruptInherited()
            third.retryInterrupted()
            third.resumeTransient()
            third.resumeQueued()
            delay(300)
        }
        assertEquals("a removed request came back", asked, manifestRequests(GARDEN_MANIFEST))
        val record = third.record("garden-1")!!
        assertTrue(record.isReady && !record.isActive && !record.withNarration)
        assertNotNull(third.fileFor(record, ReadAlongFixtures.EPUB_ID))
    }

    @Test
    fun `cancelling or removing the book cancels its narration request for good`() {
        // Cancelled while the book itself was still downloading, with narration asked for.
        val (bookStarted, bookRelease) = hold("/files/epub-garden") { bytes(gardenEpub, "\"g\"") }
        val downloads = manager()
        runBlocking { downloads.enqueue(garden(), narration = true) }
        assertTrue(bookStarted.await(10, TimeUnit.SECONDS))
        runBlocking { downloads.cancel("garden-1") }
        bookRelease.countDown()
        assertEquals(DownloadState.CANCELLED, downloads.record("garden-1")!!.state)

        // "Download again" fetches the book only: the cancelled narration choice went with it.
        runBlocking { downloads.enqueue(garden()) }
        val again = downloads.await("garden-1") { it.isReady && !it.isActive }
        runBlocking { delay(300) }
        assertFalse(again.withNarration || again.narrationPending)
        assertEquals(0, manifestRequests(GARDEN_MANIFEST))

        // A book removed while its request is stopped is gone for every recovery path.
        val release = readyBookAskingForNarration(downloads, lighthouse(), LIGHTHOUSE_MANIFEST)
        runBlocking { downloads.close() }
        release.countDown()
        val restarted = manager()
        runBlocking { restarted.interruptInherited() }
        assertStoppedBeforeManifest(restarted, "lighthouse-1", DownloadProblem.INTERRUPTED)
        runBlocking { restarted.remove("lighthouse-1") }
        runBlocking { restarted.close() }
        val asked = manifestRequests(LIGHTHOUSE_MANIFEST)
        val last = manager()
        runBlocking {
            last.resumeAfterSignIn()
            last.retryInterrupted()
            last.resumeTransient()
            last.resumeQueued()
            delay(300)
        }
        assertNull(last.record("lighthouse-1"))
        assertFalse(File(root("account-a"), folderOf("lighthouse-1")).exists())
        assertEquals(asked, manifestRequests(LIGHTHOUSE_MANIFEST))
    }

    @Test
    fun `another account never resumes, sees or borrows this account's stopped request`() {
        val first = manager()
        val release = readyBookAskingForNarration(first, garden(), GARDEN_MANIFEST)
        accepted -= ACCOUNT_A_TOKEN
        runBlocking { first.close(signedOut = true) }
        release.countDown()
        val before = File(root("account-a"), folderOf("garden-1")).listFiles().orEmpty().associate { it.name to it.readBytes().contentHashCode() }

        // Someone else signs in on this device: their downloads are their own.
        accepted += ACCOUNT_B_TOKEN
        val other = manager(account = "account-b", token = ACCOUNT_B_TOKEN)
        runBlocking {
            other.resumeAfterSignIn()
            other.retryInterrupted()
            other.resumeQueued()
            delay(300)
        }
        assertNull(other.record("garden-1"))
        assertTrue(other.records.value.isEmpty())
        assertTrue(requests.none { it.headers["Authorization"] == "Bearer $ACCOUNT_B_TOKEN" })
        runBlocking { other.close() }
        assertEquals(before, File(root("account-a"), folderOf("garden-1")).listFiles().orEmpty().associate { it.name to it.readBytes().contentHashCode() })

        // Account A comes back: its request resumes with its own credential only.
        accepted += ACCOUNT_A_RENEWED
        val renewed = manager(token = ACCOUNT_A_RENEWED)
        assertStoppedBeforeManifest(renewed, "garden-1", DownloadProblem.SIGN_IN)
        runBlocking { renewed.resumeAfterSignIn() }
        renewed.await("garden-1") { it.narration?.isReady == true && !it.isActive }
        assertTrue(requests.filter { it.target.startsWith(GARDEN_MANIFEST) }.all { it.headers["Authorization"] != "Bearer $ACCOUNT_B_TOKEN" })
    }

    @Test
    fun `a separately downloaded audiobook is untouched by the narration request's stops and recovery`() {
        val downloads = manager()
        runBlocking { downloads.enqueue(audiobook()) }
        val audio = downloads.await("lighthouse-audio-1") { it.isReady && !it.isActive }
        val audioFiles = downloads.filesFor(audio)!!.mapValues { (_, file) -> file.readBytes().contentHashCode() to file.lastModified() }

        val release = readyBookAskingForNarration(downloads, lighthouse(), LIGHTHOUSE_MANIFEST)
        accepted -= ACCOUNT_A_TOKEN
        runBlocking { downloads.close(signedOut = true) }
        release.countDown()
        accepted += ACCOUNT_A_RENEWED
        val renewed = manager(token = ACCOUNT_A_RENEWED)
        assertStoppedBeforeManifest(renewed, "lighthouse-1", DownloadProblem.SIGN_IN)
        runBlocking { renewed.resumeAfterSignIn() }
        val ready = renewed.await("lighthouse-1") { it.narration?.isReady == true && !it.isActive }
        assertNotNull(renewed.narrationFor(ready))

        // The audiobook's own download: same record state, same files, untouched.
        val after = renewed.record("lighthouse-audio-1")!!
        assertTrue(after.isReady && !after.isActive)
        assertEquals(audio.files, after.files)
        assertEquals(audioFiles, renewed.filesFor(after)!!.mapValues { (_, file) -> file.readBytes().contentHashCode() to file.lastModified() })
    }

    @Test
    fun `disconnecting is a purge, not an expiry - nothing of the removed account comes back`() {
        val first = manager()
        val release = readyBookAskingForNarration(first, garden(), GARDEN_MANIFEST)
        // An explicit disconnect closes the account's services (not as signed out) and deletes its files.
        runBlocking { first.close() }
        release.countDown()
        assertTrue(File(folder.root, "accounts/account-a").deleteRecursively())

        val asked = manifestRequests(GARDEN_MANIFEST)
        val later = manager()
        runBlocking {
            later.interruptInherited()
            later.resumeAfterSignIn()
            later.retryInterrupted()
            later.resumeQueued()
            delay(300)
        }
        assertTrue(later.records.value.isEmpty())
        assertEquals(asked, manifestRequests(GARDEN_MANIFEST))
    }

    private companion object {
        const val GARDEN_MANIFEST = "/api/consumer/v1/library/garden-1/assets/epub-garden/read_along"
        const val LIGHTHOUSE_MANIFEST = "/api/consumer/v1/library/lighthouse-1/assets/epub-lighthouse/read_along"
        const val ACCOUNT_A_TOKEN = "account-a-token"
        const val ACCOUNT_A_RENEWED = "account-a-renewed"
        const val ACCOUNT_B_TOKEN = "account-b-token"
    }
}
