package org.shelfarr.app.update

import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.shelfarr.app.core.ServerAddress

/** Asks a real HTTPS server for its description, with a subpath, and checks every boundary. */
class ServerDiscoveryTest {
    private val origin = TestTls.httpsServer()
    private val server = address(origin.url("/shelfarr").toString())
    private val discovery = ServerDiscovery(TestTls.trustingClient())

    @After
    fun tearDown() = origin.close()

    private fun address(value: String): ServerAddress = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address

    private fun description(android: String = DEFAULT_ANDROID, versions: String = "[1]") =
        """{"schema_version":1,"server_version":"2026.11.1","consumer_api_versions":$versions,"android":$android}"""

    private fun discover(channel: String = "development"): ServerUpdates = runBlocking { discovery.discover(server, channel) }

    private fun failure(channel: String = "development"): UpdateException = try {
        discover(channel)
        fail("Expected discovery to fail")
        error("unreachable")
    } catch (error: UpdateException) {
        error
    }

    @Test
    fun `reads the channel's feed inside the server's subpath, without any credential`() {
        origin.enqueue(ok(description()))
        val described = discover() as ServerUpdates.Described
        assertEquals(setOf(1), described.apiVersions)
        val source = requireNotNull(described.source)
        assertEquals(UpdateSource.Kind.SERVER, source.kind)
        assertEquals(server.identity, source.server)
        assertEquals("/shelfarr/apps/android/development.json", source.feed.encodedPath)
        assertEquals("/shelfarr/apps/android/", source.directory)

        val request = origin.takeRequest()
        assertEquals("/shelfarr/api/consumer/v1/server.json", request.target)
        assertNull("No credential reaches discovery", request.headers["Authorization"])
        assertNull(request.headers["Cookie"])
    }

    @Test
    fun `the release channel is read separately`() {
        origin.enqueue(ok(description()))
        val source = requireNotNull((discover("release") as ServerUpdates.Described).source)
        assertEquals("/shelfarr/apps/android/release.json", source.feed.encodedPath)
    }

    @Test
    fun `relative and in-boundary absolute feeds are both accepted`() {
        listOf(
            "apps/android/development.json",
            "/apps/android/development.json",
            origin.url("/shelfarr/apps/android/development.json").toString(),
        ).forEach { feed ->
            origin.enqueue(ok(description("""{"development":{"feed_url":"$feed"}}""")))
            val source = requireNotNull((discover() as ServerUpdates.Described).source)
            assertEquals(feed, "/shelfarr/apps/android/development.json", source.feed.encodedPath)
        }
    }

    @Test
    fun `a channel the server doesn't offer means no feed, not an error`() {
        origin.enqueue(ok(description("""{"release":{"feed_url":"/shelfarr/apps/android/release.json"}}""")))
        assertNull((discover() as ServerUpdates.Described).source)
        origin.enqueue(ok("""{"schema_version":1,"consumer_api_versions":[1]}"""))
        assertNull((discover() as ServerUpdates.Described).source)
    }

    @Test
    fun `a server from before discovery says so with 404 or 410`() {
        origin.enqueue(MockResponse.Builder().code(404).build())
        assertEquals(ServerUpdates.NotOffered, discover())
        origin.enqueue(MockResponse.Builder().code(410).build())
        assertEquals(ServerUpdates.NotOffered, discover())
    }

    @Test
    fun `other failures are errors, so callers keep what they had`() {
        listOf(500, 503, 401, 403).forEach { code ->
            origin.enqueue(MockResponse.Builder().code(code).build())
            val error = failure()
            assertEquals(UpdateProblem.SERVER, error.problem)
            assertEquals(code, error.status)
        }
        origin.enqueue(ok("<html>Shelfarr</html>"))
        assertEquals(UpdateProblem.BAD_FEED, failure().problem)
    }

    @Test
    fun `feeds outside the server's address are refused`() {
        listOf(
            "https://elsewhere.example.org/shelfarr/apps/android/development.json",
            origin.url("/other/apps/android/development.json").toString(),
            "//elsewhere.example.org/apps/android/development.json",
            "http://localhost:${origin.port}/shelfarr/apps/android/development.json",
            "https://localhost:1/shelfarr/apps/android/development.json",
            "/shelfarr/apps/../../admin/development.json",
            "/shelfarr/apps/%2e%2e/development.json",
            "/shelfarr/apps/android/development.json?token=1",
            "/shelfarr/apps/android/development.json#x",
            "https://user@localhost:${origin.port}/shelfarr/apps/android/development.json",
            "/shelfarr/apps/android/development.txt",
        ).forEach { feed ->
            origin.enqueue(ok(description("""{"development":{"feed_url":"$feed"}}""")))
            val error = failure()
            assertTrue(feed, error.problem == UpdateProblem.UNTRUSTED_LOCATION)
        }
    }

    @Test
    fun `malformed descriptions are refused`() {
        listOf(
            """{"schema_version":2,"consumer_api_versions":[1]}""",
            """{"schema_version":"1","consumer_api_versions":[1]}""",
            """{"schema_version":1}""",
            """{"schema_version":1,"consumer_api_versions":[]}""",
            """{"schema_version":1,"consumer_api_versions":["1"]}""",
            """{"schema_version":1,"consumer_api_versions":[1,1]}""",
            """{"schema_version":1,"consumer_api_versions":[1.5]}""",
            """{"schema_version":1,"consumer_api_versions":[1],"android":[]}""",
            """{"schema_version":1,"consumer_api_versions":[1],"android":{"development":"/x.json"}}""",
            """{"schema_version":1,"consumer_api_versions":[1],"android":{"development":{}}}""",
            """[1]""",
        ).forEach { body ->
            origin.enqueue(ok(body))
            assertEquals(body, UpdateProblem.BAD_FEED, failure().problem)
        }
    }

    @Test
    fun `redirects must stay on the server's address`() {
        origin.enqueue(redirect("/shelfarr/api/consumer/v1/server.json?again"))
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure().problem)
        origin.enqueue(redirect("https://elsewhere.example.org/server.json"))
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure().problem)
        origin.enqueue(redirect("/other/server.json"))
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, failure().problem)

        origin.enqueue(redirect("/shelfarr/api/consumer/v1/moved/server.json"))
        origin.enqueue(ok(description()))
        assertTrue(discover() is ServerUpdates.Described)
    }

    @Test
    fun `an oversized description is refused`() {
        origin.enqueue(ok(description().replace("2026.11.1", "x".repeat(40_000))))
        assertEquals(UpdateProblem.BAD_FEED, failure().problem)
    }

    @Test
    fun `a plain HTTP server is never asked`() {
        val local = (ServerAddress.parse("http://127.0.0.1:${origin.port}", allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address
        val error = try {
            runBlocking { discovery.discover(local, "development") }
            null
        } catch (error: UpdateException) {
            error
        }
        assertEquals(UpdateProblem.UNTRUSTED_LOCATION, error?.problem)
        assertEquals(0, origin.requestCount)
    }

    private companion object {
        const val DEFAULT_ANDROID = """{"release":{"feed_url":"/shelfarr/apps/android/release.json","download_page_url":"/shelfarr/apps/android"},""" +
            """"development":{"feed_url":"/shelfarr/apps/android/development.json","download_page_url":"/shelfarr/apps/android?channel=development"}}"""
    }
}
