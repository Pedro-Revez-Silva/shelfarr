package org.shelfarr.app.core

import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ConsumerApiTest {
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private lateinit var api: ConsumerApi

    @Before
    fun setUp() {
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        api = ConsumerApi(buildHttpClient({ Credential(server, "token") }))
    }

    @After
    fun tearDown() = web.close()

    private fun respond(code: Int, body: String = "") =
        web.enqueue(MockResponse.Builder().code(code).addHeader("Content-Type", "application/json").body(body).build())

    private suspend fun failure(block: suspend () -> Any?): Throwable? = runCatching { block() }.exceptionOrNull()

    @Test
    fun `decodes the publication contract and ignores unknown fields`() = runTest {
        respond(
            200,
            """
            {"items":[{"id":"p1","title":"T","author":"A","description":null,"book_type":"audiobook","cover_url":null,
              "future_field":{"a":1},
              "assets":[
                {"id":"a2","filename":"2.mp3","media_type":"audio/mpeg","format":"mp3","size_bytes":10,"content_url":"/c/2","position":2},
                {"id":"a1","filename":"1.mp3","media_type":"audio/mpeg","format":"mp3","size_bytes":10,"content_url":"/c/1","position":1}],
              "progress":{"asset_id":"a1","locator":null,"position_seconds":12.5,"version":3,"updated_at":"2026-11-07T10:00:00Z","client_mutation_id":"m"}}],
             "next_cursor":"opaque"}
            """,
        )
        val page = api.library(server, LibraryFilter.AUDIOBOOK, "dune", "c1")
        val publication = page.items.single()
        assertEquals("opaque", page.nextCursor)
        assertEquals(BookType.AUDIOBOOK, publication.bookType)
        assertEquals(listOf("a1", "a2"), publication.audioAssets.map { it.id })
        assertEquals(12.5, publication.progress?.positionSeconds)

        val request = web.takeRequest()
        assertTrue(request.target, request.target.startsWith("/api/consumer/v1/library?"))
        assertTrue(request.target.contains("type=audiobook"))
        assertTrue(request.target.contains("q=dune"))
        assertTrue(request.target.contains("cursor=c1"))
        assertTrue(request.target.contains("limit=30"))
    }

    @Test
    fun `opaque ids are path-encoded`() = runTest {
        respond(200, """{"id":"a/b c","title":"T","book_type":"ebook"}""")
        api.publication(server, "a/b c")
        assertEquals("/api/consumer/v1/library/a%2Fb%20c", web.takeRequest().target)
    }

    @Test
    fun `progress updates are snake_case and omit the unused position kind`() = runTest {
        respond(200, """{"progress":{"asset_id":"a","position_seconds":5.0,"version":1,"client_mutation_id":"m"}}""")
        api.saveProgress(server, "p", ProgressUpdate("a", null, 5.0, 0, "m"))
        val request = web.takeRequest()
        assertEquals("PUT", request.method)
        val json = Json.parseToJsonElement(request.body!!.utf8()).jsonObject
        assertEquals("a", json["asset_id"]!!.jsonPrimitive.content)
        assertEquals("0", json["expected_version"]!!.jsonPrimitive.content)
        assertEquals("m", json["client_mutation_id"]!!.jsonPrimitive.content)
        assertFalse(json.containsKey("locator"))
    }

    @Test
    fun `an absent progress decodes to null`() = runTest {
        respond(200, """{"progress":null}""")
        assertNull(api.progress(server, "p"))
    }

    @Test
    fun `maps every error status to a typed failure`() = runTest {
        suspend fun check(code: Int, type: Class<*>) {
            respond(code, "{}")
            val error = failure { api.me(server) }
            assertTrue("$code gave $error", type.isInstance(error))
        }
        check(401, ApiException.Unauthorized::class.java)
        check(403, ApiException.Forbidden::class.java)
        check(404, ApiException.NotFound::class.java)
        check(422, ApiException.Rejected::class.java)
        check(500, ApiException.Server::class.java)
        check(503, ApiException.Server::class.java)
    }

    @Test
    fun `conflict carries the current server progress`() = runTest {
        respond(409, """{"error":"progress_conflict","progress":{"asset_id":"a","position_seconds":9.0,"version":7,"client_mutation_id":"x"}}""")
        val error = failure { api.saveProgress(server, "p", ProgressUpdate("a", null, 1.0, 1, "m")) }
        assertEquals(7, (error as ApiException.ProgressConflict).current?.version)
    }

    @Test
    fun `html from a proxy is a protocol error, not a crash`() = runTest {
        respond(200, "<html>sign in</html>")
        assertTrue(failure { api.me(server) } is ApiException.Protocol)
    }

    @Test
    fun `a dropped connection is reported as offline`() = runTest {
        web.close()
        assertTrue(failure { api.me(server) } is ApiException.Offline)
    }

    @Test
    fun `response bodies are read on the io dispatcher, never the caller's thread`() = runTest {
        // Android's StrictMode kills the app if a body is read on the main thread.
        val readers = java.util.Collections.synchronizedList(mutableListOf<String>())
        val listening = buildHttpClient({ null }).newBuilder()
            .eventListener(object : okhttp3.EventListener() {
                override fun responseBodyEnd(call: okhttp3.Call, byteCount: Long) {
                    readers += Thread.currentThread().name
                }
            })
            .build()
        val pool = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "api-io") }
        val client = ConsumerApi(listening, pool.asCoroutineDispatcher())
        respond(200, """{"id":"u"}""")

        client.me(server)

        pool.shutdown()
        assertEquals(listOf("api-io"), readers)
    }

    @Test
    fun `device codes never appear in toString`() {
        val grant = DeviceGrant("secret-device", "ABCD", "u", "c", 600, 5)
        assertFalse(grant.toString().contains("secret-device"))
        val token = TokenResponse("secret-token")
        assertFalse(token.toString().contains("secret-token"))
    }

    @Test
    fun `reading status is read when present and derived when absent or unknown`() = runTest {
        respond(
            200,
            """
            {"items":[
              {"id":"a","title":"A","book_type":"ebook","reading_status":"finished","progress":{"asset_id":"x","position_seconds":1,"version":1}},
              {"id":"b","title":"B","book_type":"ebook","progress":{"asset_id":"x","position_seconds":1,"version":1}},
              {"id":"c","title":"C","book_type":"ebook"},
              {"id":"d","title":"D","book_type":"ebook","reading_status":"abandoned"},
              {"id":"e","title":"E","book_type":"ebook","reading_status":"unread","progress":{"asset_id":"x","position_seconds":1,"version":1}}
            ]}
            """,
        )
        val items = api.library(server).items.associateBy { it.id }
        assertEquals(ReadingStatus.FINISHED, items.getValue("a").status)
        assertEquals(ReadingStatus.IN_PROGRESS, items.getValue("b").status)
        assertEquals(ReadingStatus.UNREAD, items.getValue("c").status)
        assertEquals(ReadingStatus.UNREAD, items.getValue("d").status)
        // An explicit status wins over a saved place, which is kept.
        assertEquals(ReadingStatus.UNREAD, items.getValue("e").status)
        assertEquals(1.0, items.getValue("e").progress?.positionSeconds)
    }

    @Test
    fun `library sends status and sort, and continue asks for recent activity`() = runTest {
        respond(200, """{"items":[],"next_cursor":null}""")
        api.library(server, LibraryQuery(LibraryFilter.EBOOK, "dune", ReadingStatus.IN_PROGRESS, LibrarySort.TITLE), cursor = "c2")
        val url = web.takeRequest().url
        assertEquals("ebook", url.queryParameter("type"))
        assertEquals("dune", url.queryParameter("q"))
        assertEquals("in_progress", url.queryParameter("status"))
        assertEquals("title", url.queryParameter("sort"))
        assertEquals("c2", url.queryParameter("cursor"))

        respond(200, """{"items":[],"next_cursor":null}""")
        api.library(server, LibraryQuery())
        val defaults = web.takeRequest().url
        assertNull("All statuses omit the parameter", defaults.queryParameter("status"))
        assertNull("Recent is the server default", defaults.queryParameter("sort"))

        respond(200, """{"items":[{"id":"deep","title":"Page nine","book_type":"audiobook","reading_status":"in_progress"}]}""")
        val recent = api.continueReading(server, limit = 10)
        assertEquals(listOf("deep"), recent.map { it.id })
        val request = web.takeRequest()
        assertEquals("/api/consumer/v1/continue", request.url.encodedPath)
        assertEquals("10", request.url.queryParameter("limit"))
        assertNull(request.url.queryParameter("cursor"))
    }

    @Test
    fun `setting a status puts it and returns the updated publication`() = runTest {
        respond(200, """{"id":"p/1","title":"T","book_type":"ebook","reading_status":"finished"}""")
        val updated = api.setReadingStatus(server, "p/1", ReadingStatus.FINISHED)
        assertEquals(ReadingStatus.FINISHED, updated.status)
        val request = web.takeRequest()
        assertEquals("PUT", request.method)
        assertEquals("/api/consumer/v1/library/p%2F1/reading_status", request.url.encodedPath)
        assertEquals("""{"status":"finished"}""", request.body!!.utf8())
        assertEquals("Bearer token", request.headers["Authorization"])

        respond(403, """{"error":"insufficient_scope"}""")
        assertTrue(failure { api.setReadingStatus(server, "p", ReadingStatus.UNREAD) } is ApiException.Forbidden)
    }
}
