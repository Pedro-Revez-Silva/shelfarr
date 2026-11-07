package org.shelfarr.app.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DeviceAuthorizerTest {
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private lateinit var api: ConsumerApi
    private val responses = ArrayDeque<MockResponse>()

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                synchronized(responses) { responses.removeFirstOrNull() } ?: pending()
        }
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        api = ConsumerApi(buildHttpClient({ null }))
    }

    @After
    fun tearDown() = web.close()

    private fun error(code: String) = MockResponse.Builder().code(400).body("""{"error":"$code"}""").build()
    private fun pending() = error("authorization_pending")
    private fun token() = MockResponse.Builder().code(200).body("""{"access_token":"t","token_type":"Bearer"}""").build()

    private fun pendingAuthorization(expiresAt: Long = Long.MAX_VALUE, interval: Long = 5) =
        PendingAuthorization(server, DeviceGrant("dev", "CODE", "/v", "/v?c", 600, interval), expiresAt)

    private fun queue(vararg items: MockResponse) = synchronized(responses) { responses.addAll(items) }

    @Test
    fun `polls until approved`() = runTest {
        queue(pending(), pending(), token())
        val outcome = DeviceAuthorizer(api).await(pendingAuthorization())
        assertTrue(outcome is AuthorizationOutcome.Approved)
        assertEquals(3, web.requestCount)
        assertEquals(15_000, currentTime)
    }

    @Test
    fun `slow_down lengthens the interval and it stays longer`() = runTest {
        queue(error("slow_down"), pending(), token())
        DeviceAuthorizer(api).await(pendingAuthorization())
        assertEquals(5_000L + 10_000 + 10_000, currentTime)
    }

    @Test
    fun `denial and expiry stop polling`() = runTest {
        queue(error("access_denied"))
        assertEquals(AuthorizationOutcome.Denied, DeviceAuthorizer(api).await(pendingAuthorization()))
        queue(error("expired_token"))
        assertEquals(AuthorizationOutcome.Expired, DeviceAuthorizer(api).await(pendingAuthorization()))
        assertEquals(2, web.requestCount)
    }

    @Test
    fun `stops by itself at the local expiry without another request`() = runTest {
        val outcome = DeviceAuthorizer(api, now = { currentTime }).await(pendingAuthorization(expiresAt = 3_000))
        assertEquals(AuthorizationOutcome.Expired, outcome)
        assertEquals(0, web.requestCount)
    }

    @Test
    fun `a server hiccup does not lose the attempt`() = runTest {
        queue(MockResponse.Builder().code(503).build(), token())
        assertTrue(DeviceAuthorizer(api).await(pendingAuthorization()) is AuthorizationOutcome.Approved)
    }

    @Test
    fun `cancelling stops the loop`() = runTest {
        val job = launch { DeviceAuthorizer(api).await(pendingAuthorization()) }
        advanceTimeBy(1_000)
        runCurrent()
        job.cancel()
        job.join()
        assertEquals(0, web.requestCount)
    }
}
