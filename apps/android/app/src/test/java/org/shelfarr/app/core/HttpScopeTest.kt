package org.shelfarr.app.core

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HttpScopeTest {
    private val home = MockWebServer()
    private val elsewhere = MockWebServer()
    private lateinit var server: ServerAddress
    private val rejected = mutableListOf<Credential>()

    @Before
    fun setUp() {
        home.start()
        elsewhere.start()
        val parsed = ServerAddress.parse(home.url("/shelfarr").toString(), allowLocalHttp = true)
        server = (parsed as ServerAddress.ParseResult.Valid).address
    }

    @After
    fun tearDown() {
        home.close()
        elsewhere.close()
    }

    private fun client() = buildHttpClient({ Credential(server, "secret-token") }) { rejected += it }

    private fun get(url: okhttp3.HttpUrl) = client().newCall(Request.Builder().url(url).build()).execute()

    @Test
    fun `attaches the bearer token inside the server scope`() {
        home.enqueue(MockResponse.Builder().code(200).build())
        get(server.api("me")).close()
        assertEquals("Bearer secret-token", home.takeRequest().headers["Authorization"])
    }

    @Test
    fun `never sends the token outside the subpath or to another origin`() {
        home.enqueue(MockResponse.Builder().code(200).build())
        elsewhere.enqueue(MockResponse.Builder().code(200).build())
        get(home.url("/other")).close()
        get(elsewhere.url("/cover.jpg")).close()
        assertNull(home.takeRequest().headers["Authorization"])
        assertNull(elsewhere.takeRequest().headers["Authorization"])
    }

    @Test
    fun `follows a redirect that stays in scope, with credentials`() {
        home.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/shelfarr/moved").build())
        home.enqueue(MockResponse.Builder().code(200).body("ok").build())
        get(server.api("me")).use { assertEquals("ok", it.body.string()) }
        home.takeRequest()
        val followed = home.takeRequest()
        assertEquals("Bearer secret-token", followed.headers["Authorization"])
        assertTrue(followed.target.endsWith("/shelfarr/moved"))
    }

    @Test
    fun `refuses a redirect to another origin and sends it nothing`() {
        home.enqueue(MockResponse.Builder().code(302).addHeader("Location", elsewhere.url("/steal").toString()).build())
        assertThrows(BlockedRedirectIOException::class.java) { get(server.api("me")) }
        assertEquals(0, elsewhere.requestCount)
    }

    @Test
    fun `refuses a redirect that leaves the subpath on the same origin`() {
        home.enqueue(MockResponse.Builder().code(302).addHeader("Location", "/not-shelfarr/me").build())
        assertThrows(BlockedRedirectIOException::class.java) { get(server.api("me")) }
        assertEquals(1, home.requestCount)
    }

    @Test
    fun `a stale external cover redirect is not followed either`() {
        elsewhere.enqueue(MockResponse.Builder().code(302).addHeader("Location", server.api("me").toString()).build())
        assertThrows(BlockedRedirectIOException::class.java) { get(elsewhere.url("/cover.jpg")) }
        assertEquals(0, home.requestCount)
    }

    @Test
    fun `reports a rejected token once for an in-scope 401`() {
        home.enqueue(MockResponse.Builder().code(401).build())
        get(server.api("me")).close()
        assertEquals(1, rejected.size)
    }

    @Test
    fun `an external 401 says nothing about the token`() {
        elsewhere.enqueue(MockResponse.Builder().code(401).build())
        get(elsewhere.url("/cover.jpg")).close()
        assertTrue(rejected.isEmpty())
    }

    @Test
    fun `the api surfaces a blocked redirect as a typed error`() = runTest {
        home.enqueue(MockResponse.Builder().code(301).addHeader("Location", elsewhere.url("/").toString()).build())
        val error = runCatching { ConsumerApi(client()).me(server) }.exceptionOrNull()
        assertTrue(error is ApiException.RedirectBlocked)
    }
}
