package org.shelfarr.app.update

import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdateFetcherTest {
    private val origin: MockWebServer = TestTls.httpsServer()
    private val otherPort: MockWebServer = TestTls.httpsServer()
    private val plain: MockWebServer = MockWebServer().apply { start() }
    private val directory: File = Files.createTempDirectory("updater").toFile()
    private val source = requireNotNull(UpdateSource.parse(origin.url("/downloads/android-development.json").toString()))
    private val fetcher = UpdateFetcher(TestTls.trustingClient(), source)
    private val apk = Random(7).nextBytes(300_000)

    @After
    fun tearDown() {
        origin.close()
        otherPort.close()
        plain.close()
        directory.deleteRecursively()
    }

    private fun release(bytes: ByteArray = apk, path: String = "/downloads/shelfarr-3.apk", size: Long = bytes.size.toLong()) =
        UpdateRelease("development", PACKAGE, 3, "0.1.2-debug", origin.url(path), size, sha256Hex(bytes), null, null)

    private fun failure(block: suspend () -> Unit): UpdateException =
        assertThrows(UpdateException::class.java) { runBlocking { block() } }

    @Test
    fun `the updater client carries nothing of the account`() {
        val client = buildUpdateHttpClient()
        assertTrue(client.interceptors.isEmpty())
        assertTrue(client.networkInterceptors.isEmpty())
        assertFalse(client.followRedirects)
        assertFalse(client.followSslRedirects)
        assertNull(client.cache)
    }

    @Test
    fun `fetches the feed over https without credentials or cookies`() = runBlocking {
        origin.enqueue(ok("{\"hello\":1}"))
        assertEquals("{\"hello\":1}", fetcher.fetchFeed())
        val request = origin.takeRequest()
        assertEquals("/downloads/android-development.json", request.url.encodedPath)
        assertNull(request.headers["Authorization"])
        assertNull(request.headers["Cookie"])
    }

    @Test
    fun `refuses an oversized feed, declared or streamed`() {
        val big = "x".repeat(UpdateManifest.MAX_FEED_BYTES.toInt() + 10)
        origin.enqueue(ok(big))
        assertEquals(UpdateProblem.BAD_FEED, failure { fetcher.fetchFeed() }.problem)
        origin.enqueue(MockResponse.Builder().code(200).chunkedBody(big, 4_096).build())
        assertEquals(UpdateProblem.BAD_FEED, failure { fetcher.fetchFeed() }.problem)
    }

    @Test
    fun `reports server errors and unreachable publishers readably`() {
        origin.enqueue(MockResponse.Builder().code(404).build())
        assertEquals(UpdateProblem.SERVER, failure { fetcher.fetchFeed() }.problem)
        val gone = requireNotNull(UpdateSource.parse("https://localhost:1/downloads/feed.json"))
        val error = failure { UpdateFetcher(TestTls.trustingClient(), gone).fetchFeed() }
        assertEquals(UpdateProblem.OFFLINE, error.problem)
        assertTrue(error.isTransient)
    }

    @Test
    fun `an untrusted certificate is not mistaken for being offline`() {
        val untrusting = UpdateFetcher(buildUpdateHttpClient(), source)
        origin.enqueue(ok("{}"))
        val error = failure { untrusting.fetchFeed() }
        assertEquals("The update server's certificate couldn't be trusted", error.message)
    }

    @Test
    fun `follows a redirect that stays in the publisher directory`() = runBlocking {
        origin.enqueue(redirect("/downloads/android/current.json"))
        origin.enqueue(ok("{}"))
        assertEquals("{}", fetcher.fetchFeed())
        origin.takeRequest()
        assertEquals("/downloads/android/current.json", origin.takeRequest().url.encodedPath)
    }

    @Test
    fun `never follows a redirect off the origin, to http or out of the directory`() {
        val targets = listOf(
            otherPort.url("/downloads/android-development.json").toString(),
            plain.url("/downloads/android-development.json").toString(),
            "/api/v1/consumer/me.json",
            "../downloads/android-development.json",
            "/downloads/%2e%2e/admin.json",
            origin.url("/downloads/feed.json").newBuilder().username("u").build().toString(),
        )
        targets.forEach { location ->
            origin.enqueue(redirect(location, code = 307))
            assertEquals(location, UpdateProblem.UNTRUSTED_LOCATION, failure { fetcher.fetchFeed() }.problem)
        }
        assertEquals(0, otherPort.requestCount)
        assertEquals(0, plain.requestCount)
        assertEquals(targets.size, origin.requestCount)
    }

    @Test
    fun `stops after a few redirects`() {
        repeat(5) { origin.enqueue(redirect("/downloads/loop.json")) }
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure { fetcher.fetchFeed() }.problem)
        assertEquals(4, origin.requestCount)
    }

    @Test
    fun `downloads and verifies the exact announced bytes`() = runBlocking {
        origin.enqueue(redirect("/downloads/mirror/shelfarr-3.apk"))
        origin.enqueue(ok(apk))
        val file = File(directory, "update.part")
        val progress = mutableListOf<Long>()
        fetcher.download(release(), file) { progress += it }
        assertTrue(apk.contentEquals(file.readBytes()))
        assertEquals(apk.size.toLong(), progress.last())
        origin.takeRequest()
        val request = origin.takeRequest()
        assertEquals("identity", request.headers["Accept-Encoding"])
        assertNull(request.headers["Authorization"])
    }

    @Test
    fun `a tampered file is refused and removed`() {
        val tampered = apk.copyOf().also { it[1_000] = (it[1_000] + 1).toByte() }
        origin.enqueue(ok(tampered))
        val file = File(directory, "update.part")
        assertEquals(UpdateProblem.CHECKSUM, failure { fetcher.download(release(), file) {} }.problem)
        assertFalse(file.exists())
    }

    @Test
    fun `a truncated file is refused and removed`() {
        origin.enqueue(ok(apk.copyOf(apk.size - 1)))
        val file = File(directory, "update.part")
        assertEquals(UpdateProblem.INCOMPLETE, failure { fetcher.download(release(), file) {} }.problem)
        assertFalse(file.exists())
    }

    @Test
    fun `a dropped connection is a retryable failure`() {
        origin.enqueue(
            MockResponse.Builder().code(200).body(Buffer().write(apk))
                .onResponseBody(mockwebserver3.SocketEffect.ShutdownConnection).build(),
        )
        val file = File(directory, "update.part")
        val error = failure { fetcher.download(release(), file) {} }
        assertTrue(error.problem.toString(), error.problem == UpdateProblem.OFFLINE || error.problem == UpdateProblem.INCOMPLETE)
        assertFalse(file.exists())
    }

    @Test
    fun `stops reading once a file is larger than announced`() {
        val larger = apk + ByteArray(200_000)
        origin.enqueue(ok(larger))
        assertEquals(UpdateProblem.TOO_LARGE, failure { fetcher.download(release(), File(directory, "a.part")) {} }.problem)
        // Without a length up front, the stream is cut at the announced size.
        origin.enqueue(MockResponse.Builder().code(200).chunkedBody(Buffer().write(larger), 8_192).build())
        assertEquals(UpdateProblem.TOO_LARGE, failure { fetcher.download(release(), File(directory, "b.part")) {} }.problem)
        assertEquals(0, directory.listFiles()!!.size)
    }

    @Test
    fun `refuses a file whose encoding was changed in transit`() {
        origin.enqueue(MockResponse.Builder().code(200).addHeader("Content-Encoding", "gzip").body(Buffer().write(apk)).build())
        assertEquals(UpdateProblem.BAD_FEED, failure { fetcher.download(release(), File(directory, "a.part")) {} }.problem)
    }

    @Test
    fun `a redirect towards account media or another origin is never followed`() {
        origin.enqueue(redirect("/api/v1/consumer/publications/1/assets/2/file"))
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure { fetcher.download(release(), File(directory, "a.part")) {} }.problem)
        origin.enqueue(redirect(otherPort.url("/downloads/shelfarr-3.apk").toString()))
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure { fetcher.download(release(), File(directory, "a.part")) {} }.problem)
        origin.enqueue(redirect(plain.url("/downloads/shelfarr-3.apk").toString(), code = 301))
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure { fetcher.download(release(), File(directory, "a.part")) {} }.problem)
        assertEquals(0, otherPort.requestCount + plain.requestCount)
    }

    @Test
    fun `cancelling a slow download closes it promptly and removes the partial file`() = runBlocking {
        origin.enqueue(MockResponse.Builder().code(200).body(Buffer().write(apk)).throttleBody(1_024, 1, TimeUnit.SECONDS).build())
        val file = File(directory, "slow.part")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val job = scope.launch { fetcher.download(release(), file) {} }
        withTimeout(5_000) { while (!file.exists()) kotlinx.coroutines.delay(20) }
        withTimeout(5_000) { job.cancelAndJoin() }
        assertFalse(file.exists())
    }
}
