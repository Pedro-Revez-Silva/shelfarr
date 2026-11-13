package org.shelfarr.app.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class MapSecureStore : SecureStore {
    val values = java.util.concurrent.ConcurrentHashMap<String, String>()
    override fun read(name: String) = values[name]
    override fun write(name: String, value: String) {
        values[name] = value
    }
    override fun delete(name: String) {
        values.remove(name)
    }
}

/** The opt-in requesting permission, against a real HTTP fixture of the server contract. */
class RequestingAccessTest {
    private val fixture = RequestFixtureApi().start()
    private val store = MapSecureStore()
    private val sessions = SessionManager(store)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val api = ConsumerApi(buildHttpClient(sessions) { sessions.markExpired(it) })
    private val backend = object : RequestingBackend {
        override val sessions = this@RequestingAccessTest.sessions
        override val api = this@RequestingAccessTest.api
        override val authorizer = DeviceAuthorizer(api)
        override fun apiFor(credential: Credential) = ConsumerApi(buildHttpClient({ credential }))
    }
    private val access = RequestingAccess(backend, scope, "Shelfarr Android")

    private fun signIn(): Session {
        val token = fixture.issue()
        val session = Session(fixture.address, Me("u1", "Ada", "ada"), token, RequestScopes.BASE)
        sessions.signIn(session)
        return session
    }

    private suspend fun settled(): RequestAccess = withTimeout(10_000) { access.state.first { it !is RequestAccess.Approving && it != RequestAccess.Checking } }

    @After
    fun tearDown() {
        scope.cancel()
        fixture.shutdown()
    }

    @Test
    fun `an approved upgrade keeps the account and its files, swaps the token and retires the old one`() = runBlocking {
        val before = signIn()
        store.write("unrelated-setting", "kept")
        access.refresh(before)
        assertEquals(RequestAccess.NotAllowed(), access.state.value)

        val page = access.start(before)
        assertNotNull(page)
        assertTrue(page!!.startsWith(fixture.server.url("/shelfarr/consumer/connect").toString()))
        val device = fixture.deviceRequests.single()
        assertEquals("Bearer ${before.accessToken}", device.headers["Authorization"])
        assertTrue(access.state.value is RequestAccess.Approving)
        assertNotNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))

        assertEquals(RequestAccess.Allowed, settled())
        val after = requireNotNull(sessions.signedIn)
        assertEquals(before.accountKey, after.accountKey)
        assertEquals(before.server, after.server)
        assertNotEquals(before.accessToken, after.accessToken)
        assertTrue(after.canRequest)
        assertTrue(before.accessToken in fixture.revoked)
        assertNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))
        assertEquals("kept", store.read("unrelated-setting"))
        // A restart restores the upgraded connection.
        assertTrue(SessionManager(store).signedIn!!.canRequest)
    }

    @Test
    fun `declining keeps the read-only connection exactly as it was`() = runBlocking {
        val before = signIn()
        fixture.decision = RequestFixtureApi.Decision.DENY
        access.start(before)
        val ended = settled() as RequestAccess.NotAllowed
        assertTrue(ended.notice!!.contains("wasn't allowed"))
        assertEquals(before, sessions.signedIn)
        assertTrue(fixture.revoked.isEmpty())
    }

    /**
     * The remaining-time refresh runs beside the token poll. A refresh that checked
     * "still approving" just before the approval ended (a thread descheduled on a busy
     * machine) must not write "approving" back over the outcome. The clock holds that tick
     * at exactly that point, between its check and its write, until the outcome is set.
     */
    @Test
    fun `a countdown tick caught mid-update never revives an approval that has ended`() = runBlocking {
        val testThread = Thread.currentThread()
        val held = CountDownLatch(1)
        lateinit var gated: RequestingAccess
        val clock = {
            if (Thread.currentThread() !== testThread && gated.state.value is RequestAccess.Approving && held.count > 0) {
                held.countDown()
                val until = System.currentTimeMillis() + 5_000
                while (gated.state.value is RequestAccess.Approving && System.currentTimeMillis() < until) Thread.onSpinWait()
            }
            System.currentTimeMillis()
        }
        gated = RequestingAccess(backend, scope, "Shelfarr Android", now = clock)
        val before = signIn()
        fixture.decision = RequestFixtureApi.Decision.DENY
        gated.start(before)
        assertTrue("the countdown never ticked", held.await(5, TimeUnit.SECONDS))
        val ended = withTimeout(10_000) { gated.state.first { it is RequestAccess.NotAllowed } }
        // The held tick has now resumed; the outcome must still stand.
        withTimeout(2_000) { while (held.count > 0) delay(10) }
        delay(300)
        assertEquals(ended, gated.state.value)
    }

    @Test
    fun `an approval by another account never switches accounts and its token is dropped`() = runBlocking {
        val before = signIn()
        fixture.decision = RequestFixtureApi.Decision.APPROVE_AS_OTHER_USER
        access.start(before)
        val ended = settled() as RequestAccess.NotAllowed
        assertTrue(ended.notice!!.contains("different account"))
        assertEquals(before, sessions.signedIn)
        assertEquals(1, fixture.revoked.size)
        assertFalse(before.accessToken in fixture.revoked)
    }

    @Test
    fun `repeated taps start a single approval`() = runBlocking {
        val before = signIn()
        val first = access.start(before)
        val second = access.start(before)
        assertEquals(first, second)
        assertEquals(1, fixture.deviceRequests.size)
        access.cancel()
        assertNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))
    }

    @Test
    fun `an older server is explained without opening the browser`() = runBlocking {
        fixture.oldServer = true
        val before = signIn()
        access.refresh(before)
        assertEquals(RequestAccess.ServerTooOld, access.state.value)
        assertTrue(fixture.deviceRequests.isEmpty())
    }

    @Test
    fun `an older server that ignores the scope leaves requesting off and says so`() = runBlocking {
        val before = signIn()
        access.refresh(before)
        fixture.oldServer = true
        access.start(before)
        assertEquals(RequestAccess.ServerTooOld, settled())
        assertFalse(sessions.signedIn!!.canRequest)
        assertEquals(before.accountKey, sessions.signedIn!!.accountKey)
    }

    @Test
    fun `offline is explained and nothing is stored`() = runBlocking {
        val before = signIn()
        fixture.shutdown()
        assertNull(access.start(before))
        val state = access.state.value as RequestAccess.NotAllowed
        assertTrue(state.notice!!.contains("offline"))
        assertNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))
        assertEquals(before, sessions.signedIn)
    }

    @Test
    fun `an approval interrupted by the app being killed resumes for the same account only`() = runBlocking {
        val before = signIn()
        access.start(before)
        scope.coroutineContext[kotlinx.coroutines.Job]!!.children.forEach { it.cancel() }
        val revived = RequestingAccess(backend, scope, "Shelfarr Android")
        revived.resume(before.copy(user = Me("someone-else")))
        assertEquals(RequestAccess.Checking, revived.state.value)
        assertNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))
    }

    @Test
    fun `sessions saved before scopes were kept read as read-only`() {
        store.write("session", """{"server":"${fixture.address.display}","accessToken":"t","user":{"id":"u1"}}""")
        val restored = SessionManager(store).signedIn!!
        assertEquals(RequestScopes.BASE, restored.scopes)
        assertFalse(restored.canRequest)
    }
}
