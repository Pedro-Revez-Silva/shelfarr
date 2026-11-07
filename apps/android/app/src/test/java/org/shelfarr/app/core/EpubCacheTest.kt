package org.shelfarr.app.core

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class EpubCacheTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private lateinit var cache: EpubCache
    private val bytes = "PK-a-real-epub-would-go-here"

    private fun asset(id: String = "a1", size: Long = bytes.length.toLong(), url: String = "/content/a1") =
        Asset(id = id, format = "epub", sizeBytes = size, contentUrl = url)

    @Before
    fun setUp() {
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        cache = EpubCache(folder.root, buildHttpClient({ Credential(server, "secret") }))
    }

    @After
    fun tearDown() = web.close()

    private fun ok(body: String = bytes, etag: String = "\"v1\"") =
        web.enqueue(MockResponse.Builder().code(200).addHeader("ETag", etag).body(body).build())

    @Test
    fun `downloads with the header, never the URL, carrying the token`() = runTest {
        ok()
        val result = cache.obtain("acct", server, asset())
        assertEquals(bytes, result.file.readText())
        val request = web.takeRequest()
        assertEquals("Bearer secret", request.headers["Authorization"])
        assertFalse(request.target.contains("secret"))
    }

    @Test
    fun `an unchanged ETag reuses the copy`() = runTest {
        ok()
        cache.obtain("acct", server, asset())
        web.enqueue(MockResponse.Builder().code(304).build())
        val again = cache.obtain("acct", server, asset())

        web.takeRequest()
        assertEquals("\"v1\"", web.takeRequest().headers["If-None-Match"])
        assertFalse(again.unverified)
    }

    @Test
    fun `a changed ETag replaces the copy`() = runTest {
        ok()
        cache.obtain("acct", server, asset())
        val replacement = "PK-the-new-edition-file-bytes"
        ok(replacement, "\"v2\"")
        val again = cache.obtain("acct", server, asset(size = replacement.length.toLong()))
        assertEquals(replacement, again.file.readText())
    }

    @Test
    fun `offline reuses the copy and says it could not check`() = runTest {
        ok()
        cache.obtain("acct", server, asset())
        web.close()
        val again = cache.obtain("acct", server, asset())
        assertTrue(again.unverified)
        assertEquals(bytes, again.file.readText())
    }

    @Test
    fun `offline with no copy fails honestly`() = runTest {
        web.close()
        val error = runCatching { cache.obtain("acct", server, asset()) }.exceptionOrNull()
        assertTrue(error is ApiException.Offline)
    }

    @Test
    fun `an interrupted download resumes with a range tied to the ETag`() = runTest {
        // First attempt: the server drops the connection after half the body.
        val half = bytes.length / 2
        web.enqueue(
            MockResponse.Builder()
                .code(200)
                .addHeader("ETag", "\"v1\"")
                .addHeader("Content-Length", bytes.length.toString())
                .body(bytes.substring(0, half))
                .onResponseBody(mockwebserver3.SocketEffect.ShutdownConnection)
                .build(),
        )
        runCatching { cache.obtain("acct", server, asset()) }
        web.takeRequest()

        val partial = folder.root.walkTopDown().first { it.name == "book.part" }
        val offset = partial.length()
        assertTrue(offset in 1 until bytes.length)
        web.enqueue(
            MockResponse.Builder()
                .code(206)
                .addHeader("Content-Range", "bytes $offset-${bytes.length - 1}/${bytes.length}")
                .body(bytes.substring(offset.toInt()))
                .build(),
        )
        val result = cache.obtain("acct", server, asset())

        val resume = web.takeRequest()
        assertEquals("bytes=$offset-", resume.headers["Range"])
        assertEquals("\"v1\"", resume.headers["If-Range"])
        assertEquals(bytes, result.file.readText())
    }

    @Test
    fun `a wrong size is thrown away, not opened`() = runTest {
        ok()
        val error = runCatching { cache.obtain("acct", server, asset(size = 999)) }.exceptionOrNull()
        assertTrue(error is ApiException.Protocol)
        assertNull(folder.root.walkTopDown().firstOrNull { it.name == "book.epub" })
    }

    @Test
    fun `an HTML sign-in page is not mistaken for a book`() = runTest {
        val html = "<html>please sign in</html>"
        ok(html)
        val error = runCatching { cache.obtain("acct", server, asset(size = html.length.toLong())) }.exceptionOrNull()
        assertTrue(error is ApiException.Protocol)
    }

    @Test
    fun `refuses a content URL outside the server`() = runTest {
        val error = runCatching { cache.obtain("acct", server, asset(url = "https://evil.example.com/a.epub")) }.exceptionOrNull()
        assertTrue(error is ApiException.Protocol)
        assertEquals(0, web.requestCount)
    }

    @Test
    fun `accounts never share a copy and can be cleared alone`() = runTest {
        ok()
        val first = cache.obtain("one", server, asset())
        ok()
        val second = cache.obtain("two", server, asset())
        assertFalse(first.file == second.file)

        cache.clear("one")
        assertFalse(first.file.exists())
        assertTrue(second.file.exists())
    }

    @Test
    fun `old copies are trimmed once over budget`() = runTest {
        val small = EpubCache(folder.root, buildHttpClient({ Credential(server, "secret") }), maxBytes = 80)
        ok()
        val oldest = small.obtain("acct", server, asset("a1"))
        oldest.file.setLastModified(1_000)
        ok()
        small.obtain("acct", server, asset("a2"))
        ok()
        small.obtain("acct", server, asset("a3"))
        assertFalse(oldest.file.exists())
    }
}
