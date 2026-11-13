package org.shelfarr.app.core

import java.io.File
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private class HandoverStore : SecureStore {
    val values = java.util.concurrent.ConcurrentHashMap<String, String>()
    override fun read(name: String) = values[name]
    override fun write(name: String, value: String) {
        values[name] = value
    }
    override fun delete(name: String) {
        values.remove(name)
    }
}

/**
 * The server's credential model for adding a permission in place (app/models/api_token.rb,
 * `ConsumerDeviceGrant`), over real HTTP with synthetic tokens: a device approval started
 * with a bearer replaces it, and exchanging the code issues the replacement in the same
 * connection while the old token keeps working; the first request authenticated with the
 * replacement retires the old token *before* it is handled or answered; revoking any token
 * revokes its whole connection.
 */
class RetiringServer {
    data class Token(val user: String, val scopes: List<String>, var replaces: String?, var revoked: Boolean = false, val connection: Int)
    data class Seen(val method: String, val path: String, val bearer: String?, val body: String, val status: Int)

    val server = MockWebServer()
    private val tokens = HashMap<String, Token>()
    private val devices = HashMap<String, String?>()
    private val counter = AtomicInteger()
    val seen = CopyOnWriteArrayList<Seen>()

    /** `/me` waits here after it has authenticated, so the old token is already retired. */
    @Volatile var meGate: CountDownLatch? = null

    /** `/me` waits here before it is authenticated: nothing is retired yet. */
    @Volatile var holdMe: CountDownLatch? = null
    val meHeld = AtomicInteger()
    val meArrivals = AtomicInteger()

    /** `/me` authenticates (retiring the old token) and then fails to answer. */
    @Volatile var meFails = false

    /** The replacement is issued to this user instead, as a server bug would. */
    @Volatile var approvesAs: String? = null

    val address: ServerAddress
        get() = (ServerAddress.parse(server.url("/shelfarr").toString(), allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address

    fun start(): RetiringServer {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = handle(request)
        }
        server.start()
        return this
    }

    fun shutdown() {
        meGate?.countDown()
        holdMe?.countDown()
        server.close()
    }

    @Synchronized
    fun issue(user: String = "u1"): String {
        val number = counter.incrementAndGet()
        return "synthetic-$number".also { tokens[it] = Token(user, RequestScopes.BASE, null, connection = number) }
    }

    @Synchronized
    fun usable(token: String): Boolean = tokens[token]?.revoked == false

    @Synchronized
    fun revokeConnection(token: String) {
        val connection = tokens[token]?.connection ?: return
        tokens.values.filter { it.connection == connection }.forEach { it.revoked = true }
    }

    fun refusals(path: String, token: String) = seen.count { it.status == 401 && it.path == path && it.bearer == token }

    private fun json(code: Int, body: String, headers: Map<String, String> = emptyMap()) = MockResponse.Builder().code(code)
        .addHeader("Content-Type", "application/json")
        .apply { headers.forEach { (name, value) -> addHeader(name, value) } }
        .body(body).build()

    /** `APIToken.authenticate`: usable, then retire what it replaces. */
    @Synchronized
    private fun authenticate(bearer: String?): Token? {
        val token = bearer?.let { tokens[it] }?.takeIf { !it.revoked } ?: return null
        token.replaces?.let { previous ->
            val replaced = tokens[previous]
            if (replaced == null || replaced.revoked) return null
            replaced.revoked = true
            token.replaces = null
        }
        return token
    }

    private fun handle(request: RecordedRequest): MockResponse {
        val path = request.url.encodedPath.removePrefix("/shelfarr/api/consumer/v1/")
        val bearer = request.headers["Authorization"]?.removePrefix("Bearer ")
        val body = request.body?.utf8().orEmpty()
        val response = respond(request.method ?: "GET", path, bearer, body)
        seen += Seen(request.method ?: "GET", path, bearer, body, response.code)
        return response
    }

    private fun respond(method: String, path: String, bearer: String?, body: String): MockResponse {
        if (path == "auth/device") {
            val replaces = bearer?.also { if (authenticate(it) == null) return json(401, "{}") }
            val code = "dev-${counter.incrementAndGet()}"
            synchronized(this) { devices[code] = replaces }
            val base = server.url("/shelfarr/consumer/connect").toString()
            return json(200, """{"device_code":"$code","user_code":"ABCD-EFGH","verification_uri":"$base","verification_uri_complete":"$base?user_code=ABCD-EFGH","expires_in":600,"interval":1}""")
        }
        if (path == "auth/token") {
            val code = Json.parseToJsonElement(body).jsonObject["device_code"]?.jsonPrimitive?.contentOrNull
            val token = synchronized(this) {
                val replaces = devices.remove(code) ?: return json(400, """{"error":"expired_token"}""")
                val previous = tokens[replaces]?.takeIf { !it.revoked } ?: return json(400, """{"error":"expired_token"}""")
                val number = counter.incrementAndGet()
                // Exchange alone leaves the old token working: a lost token response costs nothing.
                "synthetic-$number".also {
                    tokens[it] = Token(approvesAs ?: previous.user, RequestScopes.ALL_SCOPES, replaces, connection = previous.connection)
                }
            }
            return json(200, """{"access_token":"$token","token_type":"Bearer","scope":"${RequestScopes.ALL_SCOPES.joinToString(" ")}","expires_in":2592000}""")
        }
        if (path == "me") {
            meHeld.incrementAndGet()
            holdMe?.await(10, TimeUnit.SECONDS)
        }
        val owner = authenticate(bearer) ?: return json(401, "{}")
        return when {
            path == "me" -> {
                meArrivals.incrementAndGet()
                meGate?.await(10, TimeUnit.SECONDS)
                if (meFails) {
                    json(503, "{}")
                } else {
                    json(200, """{"id":"${owner.user}","name":"Ada","username":"ada","scopes":[${owner.scopes.joinToString(",") { "\"$it\"" }}]}""")
                }
            }
            method == "POST" && path == "auth/revoke" -> {
                revokeConnection(bearer!!)
                MockResponse.Builder().code(204).build()
            }
            method == "PUT" && path.endsWith("/progress") -> {
                val fields = Json.parseToJsonElement(body).jsonObject
                val version = (fields["expected_version"]?.jsonPrimitive?.intOrNull ?: 0) + 1
                val asset = fields["asset_id"]?.jsonPrimitive?.contentOrNull
                val seconds = fields["position_seconds"]?.jsonPrimitive?.doubleOrNull
                val mutation = fields["client_mutation_id"]?.jsonPrimitive?.contentOrNull
                json(200, """{"progress":{"asset_id":"$asset","position_seconds":$seconds,"version":$version,"client_mutation_id":"$mutation"}}""")
            }
            path == "assets/a1/content" -> json(206, "ABCD", mapOf("Content-Range" to "bytes 0-3/10"))
            else -> json(404, """{"error":"not_found"}""")
        }
    }
}

private val RequestScopes.ALL_SCOPES: List<String> get() = BASE + REQUESTING

/**
 * The old token is refused from the moment the server first authenticates its replacement,
 * before the app has read that answer. Work already running follows the sign-in over.
 */
class HandoverTest {
    @get:Rule val folder = TemporaryFolder()

    private val fixture = RetiringServer().start()
    private val store = HandoverStore()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var sessions = SessionManager(store)
    private var requesting = requesting(sessions)

    /** The app's wiring (AppContainer): the global client and the account's own. */
    private fun globalClient(manager: SessionManager = sessions): OkHttpClient = buildHttpClient(
        manager,
        { rejected, canceled -> manager.resolveRefusalBlocking(rejected, canceled = canceled) },
    ) { manager.markExpired(it) }

    private fun accountClient(session: Session, manager: SessionManager = sessions): OkHttpClient = buildHttpClient(
        { manager.continuing(session)?.let { Credential(it.server, it.accessToken) } },
        { rejected, canceled -> manager.resolveRefusalBlocking(rejected, session, canceled) },
    ) { manager.markExpired(it) }

    private fun requesting(manager: SessionManager): RequestingAccess {
        val api = ConsumerApi(globalClient(manager))
        return RequestingAccess(
            object : RequestingBackend {
                override val sessions = manager
                override val api = api
                override val authorizer = DeviceAuthorizer(api)
                override fun apiFor(credential: Credential) = ConsumerApi(buildHttpClient({ credential }))
            },
            scope,
            "Shelfarr Android",
        )
    }

    /** A new process over the same Keystore files and server. */
    private fun relaunch() {
        sessions = SessionManager(store).apply {
            useCandidateCheck { candidate -> ConsumerApi(buildHttpClient({ candidate })).me(candidate.server) }
        }
        requesting = requesting(sessions)
    }

    private fun signIn(user: String = "u1"): Session =
        Session(fixture.address, Me(user, "Ada", "ada"), fixture.issue(user), RequestScopes.BASE).also(sessions::signIn)

    private fun stream(client: OkHttpClient) = client.newCall(
        Request.Builder().url(fixture.server.url("/shelfarr/api/consumer/v1/assets/a1/content")).header("Range", "bytes=0-3").build(),
    )

    private suspend fun until(what: String, condition: () -> Boolean) {
        withTimeout(10_000) { while (!condition()) delay(2) }
        assertTrue(what, condition())
    }

    private suspend fun settled(): RequestAccess =
        withTimeout(10_000) { requesting.state.first { it !is RequestAccess.Approving && it != RequestAccess.Checking } }

    /** Starts adding requesting; returns once the server retired [before]'s token while holding back its answer. */
    private suspend fun startHandover(before: Session) {
        fixture.meGate = CountDownLatch(1)
        assertNotNull(requesting.start(before))
        until("the replacement's first request retired the old token") { !fixture.usable(before.accessToken) }
    }

    @After
    fun tearDown() {
        scope.cancel()
        fixture.shutdown()
    }

    @Test
    fun `a stream refused before the new token is confirmed continues with it`() = runBlocking {
        val before = signIn()
        val client = accountClient(before)
        startHandover(before)
        assertEquals("nothing is adopted before the server answers", before.accessToken, sessions.signedIn?.accessToken)

        val playing = scope.async { stream(client).execute().use { it.code to it.body.string() } }
        until("the old token's refusal") { fixture.refusals("assets/a1/content", before.accessToken) == 1 }
        assertNotNull("the refusal waits for the replacement instead of signing out", sessions.signedIn)

        fixture.meGate?.countDown()
        assertEquals(206 to "ABCD", playing.await())
        assertEquals(RequestAccess.Allowed, settled())
        val after = requireNotNull(sessions.signedIn)
        assertEquals(before.accountKey, after.accountKey)
        assertNotEquals(before.accessToken, after.accessToken)
        assertTrue(after.canRequest)
        assertTrue("the confirmed replacement is never revoked", fixture.usable(after.accessToken))
        assertEquals(listOf(before.accessToken, after.accessToken), fixture.seen.filter { it.path == "assets/a1/content" }.map { it.bearer })
        assertEquals("work bound to the first token follows at once", after, sessions.continuing(before))
    }

    @Test
    fun `a place refused during the handover is resent unchanged while local checkpoints go on`() = runBlocking {
        val before = signIn()
        val api = ConsumerApi(accountClient(before))
        val progress = FileProgressStore(File(folder.root, "progress.json"))
        val registry = ProgressRegistry(progress, { id, update -> api.saveProgress(before.server, id, update) }, scope)
        val sync = registry.sync("pub-1")
        sync.begin(null, 0)
        startHandover(before)

        sync.update(SavedPosition("a1", positionSeconds = 42.0), 1_000)
        val sending = scope.async { sync.flush() }
        until("the place sent with the old token was refused") { fixture.refusals("library/pub-1/progress", before.accessToken) == 1 }

        // Five-second checkpoints keep landing on the device while the answer waits.
        withTimeout(2_000) { sync.update(SavedPosition("a1", positionSeconds = 47.0), 6_000) }
        assertEquals("a local checkpoint is never held up by the handover", 47.0, progress.get("pub-1")?.position?.positionSeconds)
        assertNotNull(sessions.signedIn)

        fixture.meGate?.countDown()
        sending.await()
        sync.flush()
        val after = requireNotNull(sessions.signedIn)
        val writes = fixture.seen.filter { it.path == "library/pub-1/progress" }
        assertEquals(before.accessToken, writes[0].bearer)
        assertEquals(401, writes[0].status)
        assertEquals(after.accessToken, writes[1].bearer)
        assertEquals("the same mutation, activity time and place", writes[0].body, writes[1].body)
        assertEquals(200, writes[1].status)
        assertEquals(after.accessToken, writes.last().bearer)
        val delivered = sync.snapshot()
        assertFalse(delivered.hasUnsyncedChanges)
        assertEquals(47.0, delivered.position?.positionSeconds)
    }

    @Test
    fun `a revoked connection still signs out after waiting for the replacement`() = runBlocking {
        val before = signIn()
        val client = accountClient(before)
        fixture.holdMe = CountDownLatch(1)
        assertNotNull(requesting.start(before))
        until("the replacement's first request") { fixture.meHeld.get() == 1 }
        assertTrue(sessions.hasPendingHandover(before))
        // Disconnected on the server between exchange and first use: the whole connection.
        fixture.revokeConnection(before.accessToken)
        val playing = scope.async { stream(client).execute().use { it.code } }
        until("the old token's refusal") { fixture.refusals("assets/a1/content", before.accessToken) == 1 }
        assertNotNull("it waits for the replacement's answer", sessions.signedIn)

        fixture.holdMe?.countDown()
        assertEquals(401, playing.await())
        settled()
        assertTrue("a revocation ends the sign-in", sessions.session.value is SessionState.Expired)
        assertEquals("nothing to replay with", 1, fixture.seen.count { it.path == "assets/a1/content" })
        assertNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))
    }

    @Test
    fun `an unanswered check keeps the replacement and the next process recovers the same sign-in`() = runBlocking {
        val before = signIn()
        fixture.meFails = true
        requesting.start(before)
        val notice = (settled() as RequestAccess.NotAllowed).notice
        assertTrue(notice.orEmpty().contains("couldn't confirm"))
        assertFalse("the server retired the old token although its answer failed", fixture.usable(before.accessToken))
        assertEquals(before.accessToken, sessions.signedIn?.accessToken)
        val kept = requireNotNull(sessions.pendingUpgrade(before.accountKey, Long.MAX_VALUE)?.issued) { "the replacement is stored" }
        assertTrue(fixture.usable(kept.accessToken))

        // Still unanswered: refused work waits for the connection, it isn't signed out.
        try {
            stream(accountClient(before)).execute().close()
            fail("the replacement can't be confirmed yet")
        } catch (_: HandoverPendingIOException) {
        }
        assertEquals("nothing ended", before.accessToken, sessions.signedIn?.accessToken)

        // The process dies. The next one confirms the stored replacement for this account.
        fixture.meFails = false
        relaunch()
        assertEquals(before.accessToken, sessions.signedIn?.accessToken)
        assertEquals(206, stream(accountClient(before)).execute().use { it.code })
        val after = requireNotNull(sessions.signedIn)
        assertEquals(kept.accessToken, after.accessToken)
        assertEquals(before.accountKey, after.accountKey)
        assertTrue(after.canRequest)
        assertNull(sessions.pendingUpgrade(before.accountKey, System.currentTimeMillis()))
        assertEquals("adopted durably", after, SessionManager(store).signedIn)
    }

    @Test
    fun `after a restart requesting confirms the stored replacement without asking again`() = runBlocking {
        val before = signIn()
        fixture.meFails = true
        requesting.start(before)
        settled()
        fixture.meFails = false

        relaunch()
        requesting.resume(before)
        assertEquals(RequestAccess.Allowed, settled())
        assertTrue(sessions.signedIn?.canRequest == true)
        assertEquals("no second approval", 1, fixture.seen.count { it.path == "auth/device" })
    }

    @Test
    fun `cancelling a waiting call does not stop the handover`() = runBlocking {
        val before = signIn()
        startHandover(before)
        val call = stream(accountClient(before))
        val playing = scope.async { runCatching { call.execute().close() } }
        until("the old token's refusal") { fixture.refusals("assets/a1/content", before.accessToken) == 1 }
        call.cancel()
        assertTrue("a cancelled call stops waiting", withTimeout(2_000) { playing.await() }.exceptionOrNull() is IOException)
        assertNotNull("cancelling one call ends nothing", sessions.signedIn)

        fixture.meGate?.countDown()
        assertEquals(RequestAccess.Allowed, settled())
        assertNotEquals(before.accessToken, sessions.signedIn?.accessToken)
    }

    @Test
    fun `signing out or in as someone else releases waiting work without borrowing their token`() = runBlocking {
        for (switchAccount in listOf(false, true)) {
            val before = signIn()
            val account = accountClient(before)
            val global = globalClient()
            startHandover(before)
            val bound = scope.async { stream(account).execute().use { it.code } }
            val cover = scope.async { stream(global).execute().use { it.code } }
            until("both refusals") { fixture.refusals("assets/a1/content", before.accessToken) == 2 }

            val other = if (switchAccount) signIn("u2") else null.also { sessions.clear() }
            assertEquals("released at once, without waiting for the server", 401, withTimeout(2_000) { bound.await() })
            assertEquals(401, withTimeout(2_000) { cover.await() })
            fixture.meGate?.countDown()
            settled()
            assertEquals("the replacement never becomes anyone's credential", other, sessions.signedIn)
            if (other != null) assertTrue("another sign-in's token is never borrowed", fixture.seen.none { it.bearer == other.accessToken })
            assertNull(sessions.pendingUpgrade(before.accountKey, Long.MAX_VALUE)?.issued)
            sessions.clear()
        }
    }

    @Test
    fun `the app-wide client replays only for the sign-in that held the refused token`() = runBlocking {
        val before = signIn()
        startHandover(before)
        val cover = scope.async { stream(globalClient()).execute().use { it.code } }
        until("the old token's refusal") { fixture.refusals("assets/a1/content", before.accessToken) == 1 }
        fixture.meGate?.countDown()
        assertEquals(206, cover.await())
        assertEquals(RequestAccess.Allowed, settled())
    }

    @Test
    fun `a replacement for another account is dropped and the refusal honoured`() = runBlocking {
        val before = signIn()
        fixture.approvesAs = "u2"
        startHandover(before)
        val playing = scope.async { stream(accountClient(before)).execute().use { it.code } }
        until("the old token's refusal") { fixture.refusals("assets/a1/content", before.accessToken) == 1 }
        fixture.meGate?.countDown()
        assertEquals(401, playing.await())
        val notice = (settled() as RequestAccess.NotAllowed).notice
        assertTrue(notice.orEmpty().contains("different account"))
        assertNull("nothing of this account replaces the refused token", sessions.signedIn)
        assertEquals(1, fixture.seen.count { it.path == "assets/a1/content" })
    }

    @Test
    fun `transitions do not interleave with their storage writes`() {
        val paused = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val pausing = object : SecureStore {
            val values = java.util.concurrent.ConcurrentHashMap<String, String>()
            @Volatile var pauseNext = false
            override fun read(name: String) = values[name]
            override fun write(name: String, value: String) {
                if (name == "session" && pauseNext) {
                    pauseNext = false
                    paused.countDown()
                    resume.await(5, TimeUnit.SECONDS)
                }
                values[name] = value
            }
            override fun delete(name: String) {
                values.remove(name)
            }
        }
        val manager = SessionManager(pausing)
        val old = Session(fixture.address, Me("u1"), "synthetic-old")
        val upgraded = old.copy(accessToken = "synthetic-upgraded")
        val next = old.copy(accessToken = "synthetic-next")
        manager.signIn(old)
        pausing.pauseNext = true
        val replacing = Thread { assertTrue(manager.replaceToken(old, upgraded)) }.apply { start() }
        assertTrue(paused.await(5, TimeUnit.SECONDS))
        val signingIn = Thread {
            manager.clear()
            manager.signIn(next)
        }.apply { start() }
        signingIn.join(200)
        assertTrue("the sign-out waits for the transition under way", signingIn.isAlive)
        resume.countDown()
        replacing.join(5_000)
        signingIn.join(5_000)
        assertEquals(next, manager.signedIn)
        assertNull(manager.continuing(old))
        assertEquals(next, manager.continuing(next))
        assertEquals(next, SessionManager(pausing).signedIn)
    }
}
