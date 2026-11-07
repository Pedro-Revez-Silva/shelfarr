package org.shelfarr.app.core

import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
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
import okhttp3.OkHttpClient
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Real HTTP and real files: managed downloads must never call a partial copy ready. */
class DownloadManagerTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private val scopes = mutableListOf<CoroutineScope>()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()

    private val epubBytes = "PK" + "epub-body-".repeat(400)
    private val track1 = ByteArray(9_000) { (it % 251).toByte() }
    private val track2 = ByteArray(7_000) { (it % 241).toByte() }

    /** What the fixture server answers for each path. Tests swap entries to change behaviour. */
    private val routes = HashMap<String, (RecordedRequest) -> MockResponse>()

    private val book = Publication(
        id = "book",
        title = "Downloaded book",
        bookType = BookType.EBOOK,
        assets = listOf(Asset("epub-1", "b.epub", "application/epub+zip", "epub", epubBytes.length.toLong(), "/files/epub-1")),
    )
    private val audiobook = Publication(
        id = "audio",
        title = "Downloaded audiobook",
        bookType = BookType.AUDIOBOOK,
        assets = listOf(
            // Deliberately out of order: position decides, not list order.
            Asset("t2", "2.mp3", "audio/mpeg", "mp3", track2.size.toLong(), "/files/t2", position = 2),
            Asset("t1", "1.mp3", "audio/mpeg", "mp3", track1.size.toLong(), "/files/t1", position = 1),
            Asset("cover", "cover.jpg", "image/jpeg", "jpg", 10, "/files/cover", position = 0),
        ),
    )
    private var publications = mapOf(book.id to book, audiobook.id to audiobook)

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val route = routes[request.target.substringBefore('?')] ?: return MockResponse.Builder().code(404).build()
                return route(request)
            }
        }
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        routes["/files/epub-1"] = { ranged(it, epubBytes.toByteArray(), "\"e1\"") }
        routes["/files/t1"] = { ranged(it, track1, "\"t1\"") }
        routes["/files/t2"] = { ranged(it, track2, "\"t2\"") }
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        web.close()
    }

    private fun ranged(request: RecordedRequest, bytes: ByteArray, etag: String): MockResponse {
        val range = request.headers["Range"]?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull()
        val ifRange = request.headers["If-Range"]
        if (range != null && ifRange == etag) {
            return MockResponse.Builder().code(206)
                .addHeader("ETag", etag)
                .addHeader("Content-Range", "bytes $range-${bytes.size - 1}/${bytes.size}")
                .body(Buffer().write(bytes, range, bytes.size - range))
                .build()
        }
        return MockResponse.Builder().code(200).addHeader("ETag", etag).body(Buffer().write(bytes)).build()
    }

    /** Sends only the first [cut] bytes, then drops the connection mid-body. */
    private fun truncated(bytes: ByteArray, etag: String, cut: Int): MockResponse =
        MockResponse.Builder().code(200)
            .addHeader("ETag", etag)
            .body(Buffer().write(bytes, 0, cut))
            .setHeader("Content-Length", bytes.size)
            .onResponseEnd(SocketEffect.ShutdownConnection)
            .build()

    private fun manager(
        root: File = File(folder.root, "acct/downloads"),
        token: String = "secret",
        client: OkHttpClient = buildHttpClient({ Credential(server, token) }),
        maxConcurrent: Int = 2,
        space: Long = Long.MAX_VALUE,
        onQueued: suspend () -> Unit = {},
    ): DownloadManager {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scopes += it }
        return DownloadManager(
            root = root,
            client = client,
            server = server,
            fetchPublication = { id -> publications[id] ?: throw ApiException.NotFound() },
            scope = scope,
            maxConcurrent = maxConcurrent,
            usableSpace = { space },
            onQueued = onQueued,
        )
    }

    private fun slow(bytes: ByteArray, etag: String, started: CountDownLatch? = null, headersDelayMillis: Long = 0): (RecordedRequest) -> MockResponse = { request ->
        started?.countDown()
        val range = request.headers["Range"]?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull()
        if (range != null && request.headers["If-Range"] == etag) {
            ranged(request, bytes, etag)
        } else {
            MockResponse.Builder().code(200).addHeader("ETag", etag).body(Buffer().write(bytes))
                .headersDelay(headersDelayMillis, TimeUnit.MILLISECONDS)
                .throttleBody(500, 300, TimeUnit.MILLISECONDS).build()
        }
    }

    /** Waits for actual partial bytes, even when a busy runner delays the HTTP response. */
    private suspend fun DownloadManager.awaitSomeBytes(id: String) {
        withTimeout(15_000) {
            records.first { it[id]?.state == DownloadState.DOWNLOADING }
            // The fixtures are smaller than a progress checkpoint, so inspect the
            // partial file instead of the record's bytesDone or an elapsed delay.
            val names = record(id)!!.files.filterNot { it.complete }.map { it.name + ".part" }.toSet()
            while (folder.root.walkTopDown().none { it.name in names && it.length() > 0 }) {
                delay(10)
            }
            assertEquals(DownloadState.DOWNLOADING, record(id)!!.state)
        }
    }

    private fun DownloadManager.awaitState(id: String, vararg states: DownloadState): DownloadRecord = runBlocking {
        withTimeout(15_000) { records.first { it[id]?.state in states } }[id]!!
    }

    @Test
    fun `manifest write failure is visible and retryable without crashing or transferring`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        val blocked = File(root, "manifest.json.tmp").apply { mkdirs() }
        val downloads = manager(root)
        downloads.start()
        downloads.enqueue(book)
        assertEquals(DownloadProblem.STORAGE, downloads.awaitState("book", DownloadState.FAILED).problem)
        assertTrue(requests.isEmpty())
        blocked.delete()
        downloads.retry("book")
        downloads.awaitState("book", DownloadState.READY)
        downloads.close()
    }

    @Test
    fun `manifest failure while persisting a validator is reported without crashing the worker`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        val blocked = File(root, "manifest.json.tmp")
        routes["/files/epub-1"] = {
            blocked.mkdirs()
            ranged(it, epubBytes.toByteArray(), "\"e1\"")
        }
        val downloads = manager(root)
        downloads.start()
        downloads.enqueue(book)
        val failed = downloads.awaitState("book", DownloadState.FAILED)
        assertEquals(DownloadProblem.STORAGE, failed.problem)
        assertNull(downloads.ready("book"))
        downloads.cancel("book")
        assertEquals(DownloadProblem.STORAGE, downloads.record("book")?.problem)
        downloads.remove("book")
        assertEquals(DownloadProblem.STORAGE, downloads.record("book")?.problem)
        downloads.close()
    }

    @Test
    fun `an EPUB downloads with the account header and survives a restart`() = runBlocking {
        val downloads = manager()
        downloads.start()
        downloads.enqueue(book)
        val ready = downloads.awaitState("book", DownloadState.READY)

        assertEquals(epubBytes.length.toLong(), ready.bytesDone)
        assertEquals(epubBytes.length.toLong(), ready.bytesTotal)
        val file = requireNotNull(downloads.fileFor(ready, "epub-1"))
        assertEquals(epubBytes, file.readText())
        assertFalse("Managed files never live in the cache", file.path.contains("/cache/"))
        val content = requests.first { it.target.startsWith("/files/") }
        assertEquals("Bearer secret", content.headers["Authorization"])
        assertFalse(content.target.contains("secret"))
        downloads.close()

        // A new process: the catalog and its files are still there, with no network needed.
        web.close()
        val reopened = manager()
        reopened.start()
        val restored = requireNotNull(reopened.ready("book"))
        assertEquals("Downloaded book", restored.publication.title)
        assertEquals(epubBytes, reopened.fileFor(restored, "epub-1")!!.readText())
    }

    @Test
    fun `an audiobook downloads every audio file in order and only then is ready`() = runBlocking {
        val downloads = manager()
        downloads.start()
        downloads.enqueue(audiobook)
        val ready = downloads.awaitState("audio", DownloadState.READY)

        assertEquals(listOf("t1", "t2"), ready.pinnedAssetIds)
        val contentOrder = requests.map { it.target }.filter { it.startsWith("/files/") }
        assertEquals(listOf("/files/t1", "/files/t2"), contentOrder)
        val files = requireNotNull(downloads.filesFor(ready))
        assertTrue(files.getValue("t1").readBytes().contentEquals(track1))
        assertTrue(files.getValue("t2").readBytes().contentEquals(track2))
        assertTrue(files.getValue("t1").name.endsWith(".mp3"))
        assertEquals((track1.size + track2.size).toLong(), ready.bytesTotal)
    }

    @Test
    fun `an interrupted transfer stays partial, then resumes with Range and If-Range`() = runBlocking {
        val first = AtomicInteger()
        routes["/files/t2"] = { request ->
            if (first.getAndIncrement() == 0) truncated(track2, "\"t2\"", 3_000) else ranged(request, track2, "\"t2\"")
        }
        val downloads = manager()
        downloads.start()
        downloads.enqueue(audiobook)
        val failed = downloads.awaitState("audio", DownloadState.FAILED)

        assertEquals(DownloadProblem.OFFLINE, failed.problem)
        assertNull("A partial download is never offered", downloads.ready("audio"))
        assertNull(downloads.filesFor(failed))
        assertTrue(failed.files.first { it.assetId == "t1" }.complete)
        assertFalse(failed.files.first { it.assetId == "t2" }.complete)

        downloads.retryInterrupted()
        val ready = downloads.awaitState("audio", DownloadState.READY)
        val resumed = requests.last { it.target == "/files/t2" }
        assertEquals("bytes=3000-", resumed.headers["Range"])
        assertEquals("\"t2\"", resumed.headers["If-Range"])
        assertEquals(1, requests.count { it.target == "/files/t1" })
        assertTrue(downloads.filesFor(ready)!!.getValue("t2").readBytes().contentEquals(track2))
    }

    @Test
    fun `a partial transfer resumes after the app restarts`() = runBlocking {
        routes["/files/epub-1"] = { truncated(epubBytes.toByteArray(), "\"e1\"", 1_000) }
        val downloads = manager()
        downloads.start()
        downloads.enqueue(book)
        downloads.awaitState("book", DownloadState.FAILED)
        downloads.close()

        routes["/files/epub-1"] = { ranged(it, epubBytes.toByteArray(), "\"e1\"") }
        val reopened = manager()
        reopened.start()
        assertEquals(1_000L, reopened.record("book")!!.bytesDone)
        reopened.retryInterrupted()
        val ready = reopened.awaitState("book", DownloadState.READY)
        assertEquals("bytes=1000-", requests.last().headers["Range"])
        assertEquals(epubBytes, reopened.fileFor(ready, "epub-1")!!.readText())
    }

    @Test
    fun `a file that changed under the pinned edition fails instead of being stitched together`() = runBlocking {
        routes["/files/epub-1"] = { truncated(epubBytes.toByteArray(), "\"e1\"", 1_000) }
        val downloads = manager()
        downloads.start()
        downloads.enqueue(book)
        downloads.awaitState("book", DownloadState.FAILED)

        // The server ignores If-Range because the file was replaced: a full 200 with a new tag.
        val replaced = "PK" + "a-different-file".repeat(200)
        routes["/files/epub-1"] = { MockResponse.Builder().code(200).addHeader("ETag", "\"e2\"").body(replaced).build() }
        downloads.retry("book")
        val failed = downloads.awaitState("book", DownloadState.FAILED)
        assertEquals(DownloadProblem.CHANGED, failed.problem)
        assertEquals(0L, failed.bytesDone)
        assertNull(downloads.ready("book"))
    }

    @Test
    fun `a replaced edition is re-pinned to the server's current asset ids`() = runBlocking {
        val downloads = manager()
        downloads.start()
        downloads.enqueue(book)
        val first = downloads.awaitState("book", DownloadState.READY)

        val newEdition = book.copy(assets = listOf(Asset("epub-2", "b2.epub", "application/epub+zip", "epub", 6, "/files/epub-2")))
        assertFalse("The old download is not the current edition", first.matches(newEdition))
        publications = publications + (book.id to newEdition)
        routes["/files/epub-2"] = { ranged(it, "PK-new".toByteArray(), "\"n\"") }
        downloads.enqueue(newEdition)
        val updated = downloads.awaitState("book", DownloadState.READY)
        assertEquals(listOf("epub-2"), updated.pinnedAssetIds)
        assertNull(downloads.fileFor(updated, "epub-1"))
        assertEquals("PK-new", downloads.fileFor(updated, "epub-2")!!.readText())
    }

    @Test
    fun `sign-in, certificate, offline and missing files stay distinct`() = runBlocking {
        routes["/files/epub-1"] = { MockResponse.Builder().code(401).build() }
        val signedOut = manager(root = File(folder.root, "a/downloads"))
        signedOut.start()
        signedOut.enqueue(book)
        assertEquals(DownloadProblem.SIGN_IN, signedOut.awaitState("book", DownloadState.FAILED).problem)

        val untrusted = manager(
            root = File(folder.root, "b/downloads"),
            client = OkHttpClient.Builder().addInterceptor { throw javax.net.ssl.SSLHandshakeException("untrusted") }.build(),
        )
        untrusted.start()
        untrusted.enqueue(book)
        assertEquals(DownloadProblem.CERTIFICATE, untrusted.awaitState("book", DownloadState.FAILED).problem)

        val offline = manager(
            root = File(folder.root, "c/downloads"),
            client = OkHttpClient.Builder().addInterceptor { throw java.net.ConnectException("refused") }.build(),
        )
        offline.start()
        offline.enqueue(book)
        assertEquals(DownloadProblem.OFFLINE, offline.awaitState("book", DownloadState.FAILED).problem)

        routes["/files/epub-1"] = { ranged(it, epubBytes.toByteArray(), "\"e1\"") }
        val root = File(folder.root, "d/downloads")
        val complete = manager(root = root)
        complete.start()
        complete.enqueue(book)
        complete.fileFor(complete.awaitState("book", DownloadState.READY), "epub-1")!!.delete()
        complete.close()
        val reopened = manager(root = root)
        reopened.start()
        assertEquals(DownloadProblem.MISSING, reopened.record("book")!!.problem)
        assertNull(reopened.ready("book"))
    }

    @Test
    fun `not enough space fails before transferring`() = runBlocking {
        val downloads = manager(space = 1_000)
        downloads.start()
        downloads.enqueue(audiobook)
        assertEquals(DownloadProblem.STORAGE, downloads.awaitState("audio", DownloadState.FAILED).problem)
        assertTrue(requests.none { it.target.startsWith("/files/") })
    }

    @Test
    fun `cancel stops the transfer and deletes its bytes, remove forgets the entry`() = runBlocking {
        val started = CountDownLatch(1)
        routes["/files/t1"] = {
            started.countDown()
            MockResponse.Builder().code(200).addHeader("ETag", "\"t1\"").body(Buffer().write(track1))
                .throttleBody(500, 1, TimeUnit.SECONDS).build()
        }
        val root = File(folder.root, "acct/downloads")
        val downloads = manager(root = root)
        downloads.start()
        downloads.enqueue(audiobook)
        assertTrue(started.await(10, TimeUnit.SECONDS))
        downloads.awaitState("audio", DownloadState.DOWNLOADING)
        downloads.cancel("audio")

        val cancelled = downloads.record("audio")!!
        assertEquals(DownloadState.CANCELLED, cancelled.state)
        assertEquals(0L, cancelled.bytesDone)
        assertTrue(root.listFiles().orEmpty().none { it.isDirectory })

        routes["/files/t1"] = { ranged(it, track1, "\"t1\"") }
        downloads.enqueue(audiobook)
        downloads.awaitState("audio", DownloadState.READY)
        downloads.remove("audio")
        assertNull(downloads.record("audio"))
        assertTrue(root.listFiles().orEmpty().none { it.isDirectory })
        downloads.close()
        assertTrue(manager(root = root).also { it.start() }.records.value.isEmpty())
    }

    @Test
    fun `closing for sign-out stops transfers so nothing is written after the wipe`() = runBlocking {
        routes["/files/t1"] = {
            MockResponse.Builder().code(200).addHeader("ETag", "\"t1\"").body(Buffer().write(track1))
                .throttleBody(1_000, 1, TimeUnit.SECONDS).build()
        }
        val account = File(folder.root, "acct")
        val downloads = manager(root = File(account, "downloads"))
        downloads.start()
        downloads.enqueue(audiobook)
        downloads.awaitState("audio", DownloadState.DOWNLOADING)

        downloads.close()
        account.deleteRecursively()
        delay(1_500)
        assertFalse("A stopped account must not recreate its files", account.exists())
        downloads.enqueue(book)
        delay(300)
        assertFalse(account.exists())
    }

    @Test
    fun `each account downloads only with its own token and into its own folder`() = runBlocking {
        val first = manager(root = File(folder.root, "one/downloads"), token = "token-one")
        val second = manager(root = File(folder.root, "two/downloads"), token = "token-two")
        first.start()
        second.start()
        first.enqueue(book)
        first.awaitState("book", DownloadState.READY)
        val firstTokens = requests.filter { it.target.startsWith("/files/") }.map { it.headers["Authorization"] }.toSet()
        requests.clear()
        second.enqueue(book)
        second.awaitState("book", DownloadState.READY)
        val secondTokens = requests.filter { it.target.startsWith("/files/") }.map { it.headers["Authorization"] }.toSet()

        assertEquals(setOf("Bearer token-one"), firstTokens)
        assertEquals(setOf("Bearer token-two"), secondTokens)
        assertTrue(File(folder.root, "one/downloads/manifest.json").isFile)
        assertTrue(File(folder.root, "two/downloads/manifest.json").isFile)
        second.remove("book")
        assertNotNull("Removing in one account leaves the other alone", first.ready("book"))
    }

    @Test
    fun `transfers are bounded`() = runBlocking {
        val inFlight = AtomicInteger()
        val peak = AtomicInteger()
        val slow: (RecordedRequest, ByteArray, String) -> MockResponse = { request, bytes, tag ->
            val now = inFlight.incrementAndGet()
            peak.accumulateAndGet(now) { a, b -> maxOf(a, b) }
            Thread.sleep(150)
            inFlight.decrementAndGet()
            ranged(request, bytes, tag)
        }
        routes["/files/epub-1"] = { slow(it, epubBytes.toByteArray(), "\"e1\"") }
        routes["/files/t1"] = { slow(it, track1, "\"t1\"") }
        routes["/files/t2"] = { slow(it, track2, "\"t2\"") }
        val downloads = manager(maxConcurrent = 1)
        downloads.start()
        downloads.enqueue(book)
        downloads.enqueue(audiobook)
        downloads.awaitState("book", DownloadState.READY)
        downloads.awaitState("audio", DownloadState.READY)
        assertEquals(1, peak.get())
    }

    @Test
    fun `the queue is on disk before a host is asked to run it`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        val seenOnDisk = mutableListOf<String>()
        val downloads = manager(root, onQueued = { seenOnDisk += File(root, "manifest.json").readText() })
        downloads.start()
        downloads.enqueue(book)
        downloads.awaitState("book", DownloadState.READY)
        assertEquals(1, seenOnDisk.size)
        val stored = ApiJson.decodeFromString<Map<String, DownloadRecord>>(seenOnDisk.single())
        assertEquals(DownloadState.QUEUED, stored.getValue("book").state)
        // Asking again for an active download asks for a host again, without a second record.
        downloads.close()
    }

    @Test
    fun `pausing for the OS keeps partial bytes and the next host resumes with a range`() = runBlocking {
        routes["/files/t1"] = slow(track1, "\"t1\"")
        val downloads = manager()
        downloads.start()
        downloads.enqueue(audiobook)
        downloads.awaitSomeBytes("audio")
        downloads.pause()

        val paused = downloads.record("audio")!!
        assertEquals(DownloadState.QUEUED, paused.state)
        assertTrue("Kept bytes survive a pause", paused.bytesDone > 0)
        assertNull(downloads.ready("audio"))
        val before = requests.count { it.target == "/files/t1" }

        routes["/files/t1"] = { ranged(it, track1, "\"t1\"") }
        downloads.resumeQueued()
        val ready = downloads.awaitState("audio", DownloadState.READY)
        val resumed = requests.filter { it.target == "/files/t1" }.drop(before).first()
        assertTrue(resumed.headers["Range"]!!.startsWith("bytes="))
        assertEquals("\"t1\"", resumed.headers["If-Range"])
        assertTrue(downloads.filesFor(ready)!!.getValue("t1").readBytes().contentEquals(track1))
        downloads.close()
    }

    @Test
    fun `an earlier process's downloads are interrupted when nothing will continue them`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        routes["/files/epub-1"] = slow(epubBytes.toByteArray(), "\"e1\"", headersDelayMillis = 1_500)
        val first = manager(root)
        first.start()
        first.enqueue(book)
        first.awaitSomeBytes("book")
        // The process dies mid-transfer: the manifest still says downloading.
        first.close()

        requests.clear()
        val reopened = manager(root)
        reopened.start()
        assertEquals(DownloadState.QUEUED, reopened.record("book")!!.state)
        reopened.interruptInherited()
        val interrupted = reopened.record("book")!!
        assertEquals(DownloadState.FAILED, interrupted.state)
        assertEquals(DownloadProblem.INTERRUPTED, interrupted.problem)
        assertTrue("Nothing restarts on its own", requests.none { it.target.startsWith("/files/") })
        assertTrue(interrupted.bytesDone > 0)

        // The person resumes it: the kept bytes are used.
        routes["/files/epub-1"] = { ranged(it, epubBytes.toByteArray(), "\"e1\"") }
        reopened.retry("book")
        val ready = reopened.awaitState("book", DownloadState.READY)
        assertTrue(requests.first { it.target == "/files/epub-1" }.headers["Range"]!!.startsWith("bytes="))
        assertEquals(epubBytes, reopened.fileFor(ready, "epub-1")!!.readText())
        // Persisted, so a third process agrees.
        reopened.close()
        assertNotNull(manager(root).also { it.start() }.ready("book"))
    }

    @Test
    fun `with a host scheduled, an earlier process's downloads stay queued for it`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        routes["/files/epub-1"] = slow(epubBytes.toByteArray(), "\"e1\"")
        val first = manager(root)
        first.start()
        first.enqueue(book)
        first.awaitSomeBytes("book")
        first.close()

        routes["/files/epub-1"] = { ranged(it, epubBytes.toByteArray(), "\"e1\"") }
        val reopened = manager(root)
        reopened.start()
        assertTrue(reopened.hasActiveWork)
        assertTrue(reopened.remainingBytes in 1 until epubBytes.length.toLong())
        reopened.resumeQueued()
        reopened.awaitState("book", DownloadState.READY)
        assertFalse(reopened.hasActiveWork)
        assertEquals(0L, reopened.remainingBytes)
    }

    @Test
    fun `a user stop marks downloads interrupted instead of queued`() = runBlocking {
        routes["/files/t1"] = slow(track1, "\"t1\"")
        val downloads = manager()
        downloads.start()
        downloads.enqueue(audiobook)
        downloads.awaitSomeBytes("audio")
        downloads.pause(interrupted = true)
        assertEquals(DownloadProblem.INTERRUPTED, downloads.record("audio")!!.problem)
        assertFalse(downloads.hasActiveWork)
        assertFalse("Interrupted needs the person, not a retry loop", downloads.hasTransientFailures)
    }

    @Test
    fun `an expired sign-in records stopped downloads, which resume with the new token only`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        routes["/files/t1"] = slow(track1, "\"t1\"")
        val expired = manager(root, token = "old-token")
        expired.start()
        expired.enqueue(audiobook)
        expired.awaitSomeBytes("audio")
        expired.close(signedOut = true)
        assertEquals(DownloadProblem.SIGN_IN, expired.record("audio")!!.problem)

        requests.clear()
        routes["/files/t1"] = { ranged(it, track1, "\"t1\"") }
        val signedIn = manager(root, token = "new-token")
        signedIn.start()
        assertEquals(DownloadProblem.SIGN_IN, signedIn.record("audio")!!.problem)
        signedIn.resumeAfterSignIn()
        signedIn.awaitState("audio", DownloadState.READY)
        val tokens = requests.filter { it.target.startsWith("/files/") }.map { it.headers["Authorization"] }.toSet()
        assertEquals(setOf("Bearer new-token"), tokens)
    }

    @Test
    fun `a host retries connection failures itself`() = runBlocking {
        val offline = AtomicInteger(1)
        routes["/files/epub-1"] = { request ->
            if (offline.getAndDecrement() > 0) truncated(epubBytes.toByteArray(), "\"e1\"", 500) else ranged(request, epubBytes.toByteArray(), "\"e1\"")
        }
        val downloads = manager()
        downloads.start()
        downloads.enqueue(book)
        downloads.awaitState("book", DownloadState.FAILED)
        assertTrue(downloads.hasTransientFailures)
        downloads.resumeTransient()
        downloads.awaitState("book", DownloadState.READY)
        assertFalse(downloads.hasTransientFailures)
    }

    @Test
    fun `an unreadable manifest is kept aside and the files are left alone`() = runBlocking {
        val root = File(folder.root, "acct/downloads")
        val downloads = manager(root)
        downloads.start()
        downloads.enqueue(book)
        downloads.awaitState("book", DownloadState.READY)
        downloads.close()
        val folders = root.listFiles().orEmpty().filter { it.isDirectory }.map { it.name }
        File(root, "manifest.json").writeText("{ not json")

        val reopened = manager(root)
        reopened.start()
        assertTrue(reopened.records.value.isEmpty())
        assertEquals(1, root.listFiles().orEmpty().count { it.name.startsWith("manifest.unreadable-") })
        assertEquals("Downloaded files aren't deleted", folders, root.listFiles().orEmpty().filter { it.isDirectory }.map { it.name })
    }

    @Test
    fun `a manifest written by the previous version still loads`() = runBlocking {
        val root = File(folder.root, "acct/downloads").apply { mkdirs() }
        val folderName = java.security.MessageDigest.getInstance("SHA-256").digest("book".toByteArray()).take(16).joinToString("") { "%02x".format(it) }
        val fileName = "000-" + java.security.MessageDigest.getInstance("SHA-256").digest("epub-1".toByteArray()).take(16).joinToString("") { "%02x".format(it) } + ".epub"
        File(root, folderName).mkdirs()
        File(File(root, folderName), fileName).writeText(epubBytes)
        File(root, "manifest.json").writeText(
            """{"book":{"publicationId":"book","publication":{"id":"book","title":"Downloaded book","book_type":"ebook",""" +
                """"assets":[{"id":"epub-1","filename":"b.epub","media_type":"application/epub+zip","format":"epub","size_bytes":${epubBytes.length},"content_url":"/files/epub-1","position":0}]},""" +
                """"files":[{"assetId":"epub-1","name":"$fileName","sizeBytes":${epubBytes.length},"etag":"\"e1\"","complete":true,"bytesDone":${epubBytes.length}}],""" +
                """"state":"READY","updatedAtEpochMs":1}}""",
        )
        val downloads = manager(root)
        downloads.start()
        val ready = requireNotNull(downloads.ready("book"))
        assertEquals(epubBytes, downloads.fileFor(ready, "epub-1")!!.readText())
    }
}
