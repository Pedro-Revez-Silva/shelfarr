package org.shelfarr.app.transfer

import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Credential
import org.shelfarr.app.core.DownloadManager
import org.shelfarr.app.core.DownloadProblem
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.buildHttpClient

/** The host side: it follows the signed-in account and decides when the OS should try again. */
class TransferDriverTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private val scopes = mutableListOf<CoroutineScope>()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()
    private val body = ByteArray(6_000) { (it % 199).toByte() }
    private val failuresLeft = AtomicInteger(0)
    @Volatile private var throttle = false

    private val audiobook = Publication(
        id = "audio",
        title = "Audio",
        bookType = BookType.AUDIOBOOK,
        assets = listOf(Asset("t1", "1.mp3", "audio/mpeg", "mp3", body.size.toLong(), "/files/t1", 1)),
    )

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                if (failuresLeft.getAndDecrement() > 0) return MockResponse.Builder().code(503).build()
                return MockResponse.Builder().code(200).addHeader("ETag", "\"t1\"").body(Buffer().write(body)).apply {
                    if (throttle) throttleBody(1_000, 200, TimeUnit.MILLISECONDS)
                }.build()
            }
        }
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        web.close()
    }

    private class Account(override val accountKey: String, override val downloads: DownloadManager) : TransferAccount

    private fun account(key: String, token: String): Account {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scopes += it }
        return Account(
            key,
            DownloadManager(
                root = File(folder.root, "$key/downloads"),
                client = buildHttpClient({ Credential(server, token) }),
                server = server,
                fetchPublication = { id -> if (id == audiobook.id) audiobook else throw ApiException.NotFound() },
                scope = scope,
            ),
        )
    }

    private class Budget(var left: Int) : RetryBudget {
        var resets = 0
        override fun consume(): Boolean = left-- > 0
        override fun reset() {
            resets++
        }
    }

    @Test
    fun `drives the queue to completion and reports progress`() = runBlocking {
        throttle = true
        val one = account("one", "token-one")
        val accounts = MutableStateFlow<TransferAccount?>(one)
        one.downloads.start()
        one.downloads.enqueue(audiobook)
        val published = mutableListOf<Collection<DownloadRecord>>()
        var finished: List<DownloadRecord> = emptyList()
        val budget = Budget(3)
        val again = withTimeout(15_000) {
            TransferDriver(accounts, budget, publishEveryMs = 10).drive(
                publish = { _, records -> published += records },
                finished = { _, done, _ -> finished = done },
            )
        }
        assertFalse(again)
        assertTrue(one.downloads.ready("audio") != null)
        assertTrue(published.isNotEmpty())
        assertEquals(listOf("audio"), finished.map { it.publicationId })
        assertEquals(1, budget.resets)
    }

    @Test
    fun `signing out mid-transfer ends the host without touching the stopped downloads`() = runBlocking {
        throttle = true
        val one = account("one", "token-one")
        one.downloads.start()
        one.downloads.enqueue(audiobook)
        val accounts = MutableStateFlow<TransferAccount?>(one)
        val drive = async { TransferDriver(accounts, Budget(3), publishEveryMs = 10).drive(publish = { _, _ -> }) }
        withTimeout(15_000) { one.downloads.records.first { it["audio"]?.state == DownloadState.DOWNLOADING } }
        accounts.value = null
        one.downloads.close(signedOut = true)
        assertFalse(withTimeout(15_000) { drive.await() })
        assertEquals(DownloadProblem.SIGN_IN, one.downloads.record("audio")!!.problem)
    }

    @Test
    fun `with nobody signed in it stops at once`() = runBlocking {
        assertFalse(TransferDriver(MutableStateFlow(null), Budget(3)).drive(publish = { _, _ -> }))
    }

    @Test
    fun `asks the OS to retry transient failures until the budget runs out`() = runBlocking {
        val one = account("one", "token-one")
        one.downloads.start()
        failuresLeft.set(Int.MAX_VALUE)
        one.downloads.enqueue(audiobook)
        withTimeout(15_000) { one.downloads.records.first { it["audio"]?.problem == DownloadProblem.SERVER } }
        val accounts = MutableStateFlow<TransferAccount?>(one)
        val budget = Budget(1)
        assertTrue(TransferDriver(accounts, budget).drive(publish = { _, _ -> }))
        assertFalse("The budget is spent; the person retries from here", TransferDriver(accounts, budget).drive(publish = { _, _ -> }))
        assertEquals(DownloadProblem.SERVER, one.downloads.record("audio")!!.problem)
    }

    @Test
    fun `follows an account switch and never sends the old token afterwards`() = runBlocking {
        throttle = true
        val one = account("one", "token-one")
        val two = account("two", "token-two")
        one.downloads.start()
        two.downloads.start()
        one.downloads.enqueue(audiobook)
        val accounts = MutableStateFlow<TransferAccount?>(one)
        val drive = async { TransferDriver(accounts, Budget(0), publishEveryMs = 10).drive(publish = { _, _ -> }) }
        withTimeout(15_000) { one.downloads.records.first { it["audio"]?.state == DownloadState.DOWNLOADING } }
        // "Downloading" is recorded before the request leaves; wait until the first account's request arrived.
        withTimeout(15_000) {
            while (requests.none { it.target.startsWith("/files/") && it.headers["Authorization"] == "Bearer token-one" }) kotlinx.coroutines.delay(20)
        }

        requests.clear()
        two.downloads.enqueue(audiobook)
        accounts.value = two
        one.downloads.close(signedOut = true)
        assertFalse(withTimeout(20_000) { drive.await() })

        assertTrue(two.downloads.ready("audio") != null)
        assertEquals(DownloadProblem.SIGN_IN, one.downloads.record("audio")!!.problem)
        val tokens = requests.filter { it.target.startsWith("/files/") }.map { it.headers["Authorization"] }.toSet()
        assertEquals(setOf("Bearer token-two"), tokens)
    }
}
