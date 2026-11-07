package org.shelfarr.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class MapStore : SecureStore {
    val values = HashMap<String, String>()
    override fun read(name: String) = values[name]
    override fun write(name: String, value: String) {
        values[name] = value
    }
    override fun delete(name: String) {
        values.remove(name)
    }
}

class SessionManagerTest {
    private val store = MapStore()
    private val server = (ServerAddress.parse("https://example.org/s") as ServerAddress.ParseResult.Valid).address
    private val account = Session(server, Me("u1", "Pedro", "pedro"), "token")

    @Test
    fun `sessions survive a restart`() {
        SessionManager(store).signIn(account)
        val restored = SessionManager(store)
        assertEquals(account.accountKey, restored.signedIn?.accountKey)
        assertEquals("token", restored.current()?.accessToken)
    }

    @Test
    fun `an expired session forgets the token but remembers the server`() {
        val sessions = SessionManager(store).apply { signIn(account) }
        sessions.markExpired(Credential(server, "token"))

        assertNull(sessions.current())
        assertFalse(store.values.values.any { it.contains("\"token\"") })
        val state = SessionManager(store).session.value as SessionState.Expired
        assertEquals(server, state.server)
    }

    @Test
    fun `a late 401 for an old token cannot sign out a newer session`() {
        val sessions = SessionManager(store).apply { signIn(account) }
        sessions.markExpired(Credential(server, "older"))
        assertTrue(sessions.session.value is SessionState.SignedIn)
    }

    @Test
    fun `clearing removes every stored secret`() {
        val sessions = SessionManager(store).apply { signIn(account) }
        sessions.savePendingAuthorization(PendingAuthorization(server, DeviceGrant("d", "c", "/v", "/v", 600), Long.MAX_VALUE))
        sessions.clear()
        assertTrue(store.values.isEmpty())
        assertEquals(SessionState.SignedOut, sessions.session.value)
    }

    @Test
    fun `a pending authorization resumes until it expires`() {
        val sessions = SessionManager(store)
        sessions.savePendingAuthorization(PendingAuthorization(server, DeviceGrant("d", "c", "/v", "/v", 600), 1_000))
        assertEquals("d", sessions.pendingAuthorization(999)?.grant?.deviceCode)
        assertNull(sessions.pendingAuthorization(1_000))
        assertTrue(store.values.isEmpty())
    }

    @Test
    fun `a provisional token is usable but never stored`() {
        val sessions = SessionManager(store)
        sessions.useProvisional(Credential(server, "fresh"))
        assertEquals("fresh", sessions.current()?.accessToken)
        assertTrue(store.values.isEmpty())
    }

    @Test
    fun `account keys differ by user and by server`() {
        val other = (ServerAddress.parse("https://example.org/t") as ServerAddress.ParseResult.Valid).address
        assertNotEquals(accountKey(server, "u1"), accountKey(server, "u2"))
        assertNotEquals(accountKey(server, "u1"), accountKey(other, "u1"))
    }
}
