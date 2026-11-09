package org.shelfarr.app.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The reading order obeys the same origin, subpath, redirect and size rules as every other call. */
class ReadingOrderClientTest {
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private lateinit var client: ReadingOrderClient
    private val built = ComicFixtures.zip(listOf(ComicFixtures.Entry("1.png", ComicFixtures.page("1"))))

    @Before
    fun setUp() {
        web.start()
        server = (ServerAddress.parse(web.url("/shelf").toString(), true) as ServerAddress.ParseResult.Valid).address
        client = ReadingOrderClient(buildHttpClient({ Credential(server, "secret") }))
    }

    @After
    fun tearDown() = web.close()

    private fun asset(url: String?) = ComicFixtures.asset("z", built).copy(readingOrderUrl = url)

    private suspend fun failure(block: suspend () -> Any?): Throwable? = runCatching { block() }.exceptionOrNull()

    @Test
    fun `a server-relative URL gains the subpath and carries only the header credential`() = runTest {
        val order = ComicFixtures.order("z", built.items)
        web.enqueue(MockResponse.Builder().code(200).body(ApiJson.encodeToString(order)).build())
        assertEquals(order, client.fetch(server, asset("/api/consumer/v1/library/b/assets/z/reading_order")))
        val request = web.takeRequest()
        assertEquals("/shelf/api/consumer/v1/library/b/assets/z/reading_order", request.target)
        assertEquals("Bearer secret", request.headers["Authorization"])
    }

    @Test
    fun `URLs outside the server, redirects away and oversized or malformed bodies are refused`() = runTest {
        assertTrue(failure { client.fetch(server, asset("https://elsewhere.example/ro")) } is ApiException.Protocol)
        assertTrue(failure { client.fetch(server, asset("//elsewhere.example/ro")) } is ApiException.Protocol)
        val outside = web.url("/other/ro").toString()
        assertTrue("same origin, other subpath", failure { client.fetch(server, asset(outside)) } is ApiException.Protocol)
        assertEquals("Nothing was requested", 0, web.requestCount)

        web.enqueue(MockResponse.Builder().code(302).addHeader("Location", "https://elsewhere.example/ro").build())
        assertTrue(failure { client.fetch(server, asset("/ro")) } is ApiException.RedirectBlocked)

        web.enqueue(MockResponse.Builder().code(200).body("{\"asset_id\":\"z\",\"format\":\"cbz\",\"items\":[" + " ".repeat(9 shl 20) + "]}").build())
        assertTrue(failure { client.fetch(server, asset("/ro")) } is ApiException.Protocol)

        web.enqueue(MockResponse.Builder().code(200).body("{\"asset_id\":\"z\"}").build())
        assertTrue(failure { client.fetch(server, asset("/ro")) } is ApiException.Protocol)

        web.enqueue(MockResponse.Builder().code(410).build())
        assertTrue(failure { client.fetch(server, asset("/ro")) } is GenerationGone)
        web.enqueue(MockResponse.Builder().code(404).build())
        assertTrue(failure { client.fetch(server, asset("/ro")) } is ApiException.NotFound)
        assertTrue(failure { client.fetch(server, asset(null)) } is UnreadableFile)
    }
}
