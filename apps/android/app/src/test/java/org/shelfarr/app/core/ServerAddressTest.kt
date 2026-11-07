package org.shelfarr.app.core

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerAddressTest {
    private fun valid(input: String, http: Boolean = false): ServerAddress =
        (ServerAddress.parse(input, http) as ServerAddress.ParseResult.Valid).address

    @Test
    fun `assumes https and normalises trailing slashes`() {
        assertEquals("https://books.example.org", valid("books.example.org/").display)
        assertEquals("https://example.org/shelfarr", valid(" https://example.org/shelfarr/ ").display)
    }

    @Test
    fun `rejects empty, credentialed and query addresses`() {
        assertEquals(ServerAddress.ParseResult.Empty, ServerAddress.parse("  "))
        assertEquals(ServerAddress.ParseResult.Malformed, ServerAddress.parse("https://user:pw@example.org"))
        assertEquals(ServerAddress.ParseResult.Malformed, ServerAddress.parse("https://example.org?x=1"))
        assertEquals(ServerAddress.ParseResult.Malformed, ServerAddress.parse("https://example.org/#a"))
        assertEquals(ServerAddress.ParseResult.Malformed, ServerAddress.parse("ftp://example.org"))
    }

    @Test
    fun `plain http needs the opt-in and a local host`() {
        assertEquals(ServerAddress.ParseResult.CleartextNotAllowed, ServerAddress.parse("http://192.168.1.10"))
        assertEquals(ServerAddress.ParseResult.CleartextNotAllowed, ServerAddress.parse("http://example.org", allowLocalHttp = true))
        assertEquals(ServerAddress.ParseResult.CleartextNotAllowed, ServerAddress.parse("http://8.8.8.8", allowLocalHttp = true))
        assertTrue(valid("http://192.168.1.10:3000", http = true).isCleartext)
        assertTrue(valid("http://10.0.2.2:3000", http = true).isCleartext)
        assertTrue(valid("http://nas.local", http = true).isCleartext)
        assertTrue(valid("http://localhost:3000", http = true).isCleartext)
    }

    @Test
    fun `api paths sit under the subpath`() {
        assertEquals(
            "https://example.org/shelfarr/api/consumer/v1/library/a%20b",
            valid("https://example.org/shelfarr").api("library/a%20b").toString(),
        )
        assertEquals("https://example.org/api/consumer/v1/me", valid("example.org").api("me").toString())
    }

    @Test
    fun `scope is exact on scheme, host, port and subpath`() {
        val server = valid("https://example.org/shelfarr")
        assertTrue(server.contains("https://example.org/shelfarr/api/x".toHttpUrl()))
        assertTrue(server.contains("https://example.org/shelfarr".toHttpUrl()))
        assertFalse(server.contains("https://example.org/shelfarr-evil/api".toHttpUrl()))
        assertFalse(server.contains("https://example.org/other".toHttpUrl()))
        assertFalse(server.contains("https://example.org/shelfarr/../other".toHttpUrl()))
        assertFalse(server.contains("http://example.org/shelfarr/api".toHttpUrl()))
        assertFalse(server.contains("https://example.org:8443/shelfarr/api".toHttpUrl()))
        assertFalse(server.contains("https://evil.example.org/shelfarr/api".toHttpUrl()))
        assertFalse(server.contains("https://example.org.evil.com/shelfarr/api".toHttpUrl()))
    }

    @Test
    fun `resolves server-relative references against the subpath`() {
        val server = valid("https://example.org/shelfarr")
        assertEquals(
            "https://example.org/shelfarr/api/consumer/v1/assets/1/content",
            server.resolve("/api/consumer/v1/assets/1/content").toString(),
        )
        assertEquals(
            "https://example.org/shelfarr/api/consumer/v1/assets/1/content",
            server.resolve("/shelfarr/api/consumer/v1/assets/1/content").toString(),
        )
        assertEquals("https://example.org/shelfarr/covers/1.jpg", server.resolve("covers/1.jpg").toString())
        assertEquals("https://cdn.example.com/1.jpg", server.resolve("https://cdn.example.com/1.jpg").toString())
    }

    @Test
    fun `a path that merely starts like the subpath is still prefixed`() {
        val server = valid("https://example.org/shelfarr")
        assertEquals("https://example.org/shelfarr/shelfarr-x/1", server.resolve("/shelfarr-x/1").toString())
    }

    @Test
    fun `protocol-relative and non-web references never resolve into a request`() {
        val server = valid("https://example.org")
        assertNull(server.resolve("//evil.example.com/x"))
        assertNull(server.resolve("javascript:alert(1)"))
        assertNull(server.resolve(""))
    }

    @Test
    fun `restoring keeps the same identity`() {
        val server = valid("https://Example.org/Shelfarr/")
        assertEquals(server, ServerAddress.restore(server.display))
    }
}
