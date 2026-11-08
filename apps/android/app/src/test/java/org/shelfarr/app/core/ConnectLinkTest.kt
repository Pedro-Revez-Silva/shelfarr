package org.shelfarr.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectLinkTest {
    private val view = ConnectLink.ACTION_VIEW

    private fun address(value: String) = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address

    private fun parse(data: String?, action: String? = view) = ConnectLink.parse(action, data)

    @Test
    fun `reads a fully encoded https address, subpath and port included`() {
        assertEquals(address("https://books.example.org"), parse("shelfarr://connect?server=https%3A%2F%2Fbooks.example.org"))
        assertEquals(
            address("https://books.example.org/shelfarr"),
            parse("shelfarr://connect?server=https%3A%2F%2Fbooks.example.org%2Fshelfarr"),
        )
        assertEquals(
            address("https://books.example.org:8443/a/b"),
            parse("shelfarr://connect?server=https%3a%2f%2fbooks.example.org%3a8443%2fa%2fb"),
        )
        // A trailing slash names the same server.
        assertEquals(address("https://books.example.org/shelfarr"), parse("shelfarr://connect?server=https%3A%2F%2Fbooks.example.org%2Fshelfarr%2F"))
    }

    @Test
    fun `what the server page builds is what the app reads`() {
        listOf("https://books.example.org", "https://books.example.org/shelfarr", "https://a-b.example.org:8443/x_y/z~1.2", "https://[2001:db8::1]:8443/shelfarr").forEach { value ->
            val server = address(value)
            val link = ConnectLink.build(server)
            assertTrue(link, link.startsWith("shelfarr://connect?server=https%3A%2F%2F"))
            assertEquals(server, parse(link))
        }
    }

    @Test
    fun `only a VIEW intent counts`() {
        val link = "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org"
        assertNull(parse(link, action = null))
        assertNull(parse(link, action = "android.intent.action.MAIN"))
        assertNull(parse(link, action = "android.intent.action.SEND"))
        assertNull(parse(null))
    }

    @Test
    fun `the link's own shape is exact`() {
        listOf(
            "shelfarr://connect",
            "shelfarr://connect?",
            "shelfarr://connect?server=",
            "shelfarr://connect/?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://connect/x?server=https%3A%2F%2Fbooks.example.org",
            "SHELFARR://connect?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://Connect?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://other?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://user@connect?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://connect:80?server=https%3A%2F%2Fbooks.example.org",
            "https://connect?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr:connect?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org#x",
            "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org&server=https%3A%2F%2Fevil.example",
            "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org&token=abc",
            "shelfarr://connect?token=abc&server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://connect?Server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org;x=1",
            " shelfarr://connect?server=https%3A%2F%2Fbooks.example.org",
            "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org\n",
        ).forEach { link -> assertNull(link, parse(link)) }
    }

    @Test
    fun `the address must be fully encoded and decode cleanly`() {
        listOf(
            "shelfarr://connect?server=https://books.example.org",
            "shelfarr://connect?server=https%3A//books.example.org",
            "shelfarr://connect?server=https%3A%2F%2Fbooks.example.org+x",
            "shelfarr://connect?server=https%3A%2F%2Fbooks%2",
            "shelfarr://connect?server=https%3A%2F%2Fbooks%zz.org",
            "shelfarr://connect?server=https%3A%2F%2Fb%C3%28.org",
            "shelfarr://connect?server=https%3A%2F%2Fb%C3%A9.org",
        ).forEach { link -> assertNull(link, parse(link)) }
    }

    @Test
    fun `only a plain public https address is accepted`() {
        listOf(
            "http://books.example.org",
            "HTTPS://books.example.org",
            "ftp://books.example.org",
            "books.example.org",
            "https://",
            "https://user@books.example.org",
            "https://user:pw@books.example.org",
            "https://books.example.org?x=1",
            "https://books.example.org/#x",
            "https://books.example.org/a/../admin",
            "https://books.example.org/a/./b",
            "https://books.example.org/a//b",
            "https://books.example.org/%2e%2e",
            "https://books.example.org/a%2Fb",
            "https://books.example.org/a%20b",
            "https://books.example.org\\@evil.example",
            "https://[not-an-ipv6-address]",
            "https://books.example.org:99999",
            "https://books.example.org/a b",
            "javascript:alert(1)",
        ).forEach { value ->
            val encoded = value.toByteArray().joinToString("") { "%%%02X".format(it.toInt() and 0xff) }
            assertNull(value, parse("shelfarr://connect?server=$encoded"))
        }
    }

    @Test
    fun `an oversized link is ignored`() {
        val long = "https://books.example.org/" + "a".repeat(3_000)
        assertNull(parse(ConnectLink.build(address(long))))
    }

    private val here = address("https://books.example.org/shelfarr")
    private val there = address("https://other.example.org")
    private val session = Session(here, Me("7", "Ada"), "token")

    @Test
    fun `signed out and idle, a link starts signing in to its server`() {
        assertEquals(ConnectDecision.Connect(here), ConnectLinks.decide(here, SessionState.SignedOut))
    }

    @Test
    fun `signed in, a link never replaces the connection`() {
        assertEquals(ConnectDecision.AlreadyThere, ConnectLinks.decide(here, SessionState.SignedIn(session)))
        val explained = ConnectLinks.decide(there, SessionState.SignedIn(session)) as ConnectDecision.Explain
        assertTrue(explained.message.contains("https://other.example.org"))
        assertTrue(explained.message.contains("https://books.example.org/shelfarr"))
        assertTrue(explained.message.contains("Nothing was changed"))
        assertTrue(explained.message.contains("disconnect this device in Settings, then open the link again"))
    }

    @Test
    fun `an ended sign-in keeps its server unless the person switches by hand`() {
        val expired = SessionState.Expired(here, "Ada")
        assertEquals(ConnectDecision.Connect(here), ConnectLinks.decide(here, expired))
        val explained = ConnectLinks.decide(there, expired) as ConnectDecision.Explain
        assertTrue(explained.message.contains("still keeps its downloads"))
    }

    @Test
    fun `a sign-in under way isn't replaced`() {
        assertEquals(ConnectDecision.AlreadyThere, ConnectLinks.decide(here, SessionState.SignedOut, SignInActivity.IN_PROGRESS, here))
        val explained = ConnectLinks.decide(there, SessionState.SignedOut, SignInActivity.IN_PROGRESS, here) as ConnectDecision.Explain
        assertTrue(explained.message.contains("Cancel that sign-in first"))
    }
}
