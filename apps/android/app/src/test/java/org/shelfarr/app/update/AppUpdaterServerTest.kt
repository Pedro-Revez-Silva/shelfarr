package org.shelfarr.app.update

import android.content.pm.PackageInstaller
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.shelfarr.app.core.ServerAddress

/**
 * The updater with server discovery: a Shelfarr server (two subpaths standing for two
 * servers) and a separate built-in publisher, both real HTTPS origins with routed responses.
 */
class AppUpdaterServerTest {
    @get:Rule val folder = TemporaryFolder()

    private val shelfarr = TestTls.httpsServer()
    private val publisher = TestTls.httpsServer()
    private val routes = ConcurrentHashMap<String, () -> MockResponse>()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()
    private val apk = Random(5).nextBytes(150_000)
    private val newer = Random(6).nextBytes(120_000)

    private val serverA = address(shelfarr.url("/a").toString())
    private val serverB = address(shelfarr.url("/b").toString())
    private val builtIn = requireNotNull(UpdateSource.parse(publisher.url("/downloads/android-development.json").toString()))

    @Volatile private var current: ServerAddress? = serverA
    @Volatile private var autoDownload = false
    private val inspector = FakeInspector()
    private val installer = FakeInstaller()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var now = 1_800_000_000_000L
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = folder.newFolder("updates")
        val dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                return routes[request.target]?.invoke() ?: MockResponse.Builder().code(404).build()
            }
        }
        shelfarr.dispatcher = dispatcher
        publisher.dispatcher = dispatcher
    }

    @After
    fun tearDown() {
        scope.cancel()
        shelfarr.close()
        publisher.close()
    }

    private fun address(value: String) = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address

    private fun updater(builtIn: UpdateSource? = this.builtIn): AppUpdater = AppUpdater(
        builtIn = builtIn,
        channel = "development",
        fetcherFor = { UpdateFetcher(TestTls.trustingClient(), it) },
        inspector = inspector,
        installer = installer,
        directory = directory,
        playback = FakePlayback(),
        scope = scope,
        clock = { now },
        sdkInt = 35,
        discovery = ServerDiscovery(TestTls.trustingClient()),
        server = { current },
        autoDownload = { autoDownload },
    ).also { it.start()?.let { job -> runBlocking { job.join() } } }

    private fun AppUpdater.await(predicate: (UpdateState) -> Boolean): UpdateState =
        runBlocking { withTimeout(10_000) { state.first(predicate) } }

    private fun waitUntil(condition: () -> Boolean) = runBlocking { withTimeout(10_000) { while (!condition()) delay(10) } }

    private fun files(): Set<String> = directory.list().orEmpty().toSet() - "state.json"

    private fun json(body: String): () -> MockResponse = { ok(body) }

    /** [server] describes itself with a development feed at its usual place. */
    private fun describe(server: ServerAddress, versions: String = "[1]", channel: String = "development") {
        val base = server.baseUrl.encodedPath
        routes["$base/api/consumer/v1/server.json"] = json(
            """{"schema_version":1,"server_version":"2026.11.1","consumer_api_versions":$versions,""" +
                """"android":{"$channel":{"feed_url":"$base/apps/android/$channel.json","download_page_url":"$base/apps/android"}}}""",
        )
    }

    /** [server]'s own feed announcing [bytes] as [versionCode], served from its cache. */
    private fun serverFeed(
        server: ServerAddress,
        bytes: ByteArray = apk,
        versionCode: Int = 3,
        apiVersions: List<Int>? = listOf(1),
        slowApk: Boolean = false,
    ) {
        val base = server.baseUrl.encodedPath
        val apkPath = "$base/apps/android/development/$versionCode-${sha256Hex(bytes)}.apk"
        val overrides = mutableMapOf<String, JsonElement?>(
            "consumer_api_versions" to apiVersions?.let { list -> JsonArray(list.map(::JsonPrimitive)) },
        )
        routes["$base/apps/android/development.json"] = json(feedJson(shelfarr, bytes, versionCode, "0.1.${versionCode - 1}-debug", apkPath, overrides))
        routes[apkPath] = {
            MockResponse.Builder().code(200).body(Buffer().write(bytes)).apply {
                if (slowApk) throttleBody(4_000, 100, TimeUnit.MILLISECONDS)
            }.build()
        }
        inspector.archive = { AppIdentity(PACKAGE, versionCode.toLong(), "0.1.${versionCode - 1}-debug", setOf(SIGNER), minSdk = 26) }
    }

    /** The built-in publisher announcing [bytes] as version 3, without the API field, as v3-era feeds do. */
    private fun publisherFeed(bytes: ByteArray = apk) {
        routes["/downloads/android-development.json"] = json(feedJson(publisher, bytes, 3, "0.1.2-debug"))
        routes["/downloads/shelfarr-3.apk"] = { ok(bytes) }
    }

    private fun requestsTo(origin: MockWebServer) = requests.filter { it.url.port == origin.port }

    @Test
    fun `prefers the server's feed and sends no credential anywhere`() {
        describe(serverA)
        serverFeed(serverA)
        publisherFeed()
        val updater = updater()
        updater.checkNow()
        val available = updater.await { it is UpdateState.Available } as UpdateState.Available
        assertEquals("/a/apps/android/development/3-${sha256Hex(apk)}.apk", available.release.apkUrl.encodedPath)
        assertEquals(setOf(1), available.release.consumerApiVersions)
        assertEquals(UpdateSource.Kind.SERVER, updater.currentBinding?.source?.kind)

        updater.download()
        updater.await { it is UpdateState.Ready }
        assertTrue(requestsTo(publisher).isEmpty())
        assertEquals(3, requests.size)
        requests.forEach { request ->
            assertNull(request.target, request.headers["Authorization"])
            assertNull(request.target, request.headers["Cookie"])
        }
        assertTrue(installer.committed.isEmpty())
    }

    @Test
    fun `a server from before discovery falls back to the built-in feed`() {
        publisherFeed()
        val updater = updater()
        updater.checkNow()
        val available = updater.await { it is UpdateState.Available } as UpdateState.Available
        assertEquals(publisher.port, available.release.apkUrl.port)
        assertEquals(UpdateBinding(builtIn, serverA.identity, null), updater.currentBinding)
    }

    @Test
    fun `a server that can't answer never moves updates to another publisher`() {
        routes["/a/api/consumer/v1/server.json"] = { MockResponse.Builder().code(503).build() }
        publisherFeed()
        val updater = updater()
        updater.checkNow()
        val idle = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertEquals("The update server answered 503", idle.problem)
        assertTrue("The built-in publisher was not asked", requestsTo(publisher).isEmpty())
        assertNull(updater.currentBinding)
    }

    @Test
    fun `when discovery fails, the feed chosen before for the same server is used again`() {
        describe(serverA)
        serverFeed(serverA)
        publisherFeed()
        val updater = updater()
        updater.checkNow()
        updater.await { it is UpdateState.Available }

        routes["/a/api/consumer/v1/server.json"] = { MockResponse.Builder().code(500).build() }
        serverFeed(serverA, newer, versionCode = 4)
        now += 1
        updater.checkNow()
        val state = updater.await { it is UpdateState.Available && it.release.versionCode == 4 } as UpdateState.Available
        assertEquals("/a/apps/android/development/4-${sha256Hex(newer)}.apk", state.release.apkUrl.encodedPath)
        assertTrue(requestsTo(publisher).isEmpty())
    }

    @Test
    fun `a server that doesn't offer this channel offers nothing, and the built-in feed isn't used`() {
        describe(serverA, channel = "release")
        publisherFeed()
        val updater = updater()
        updater.checkNow()
        val idle = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertTrue(idle.problem!!.contains("doesn't offer development build updates"))
        assertTrue(requestsTo(publisher).isEmpty())
    }

    @Test
    fun `a server's feed must say which API generations each build speaks`() {
        describe(serverA)
        serverFeed(serverA, apiVersions = null)
        val updater = updater()
        updater.checkNow()
        val idle = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertEquals("The update feed is missing consumer_api_versions", idle.problem)
    }

    @Test
    fun `a build that can't talk to this server isn't offered`() {
        describe(serverA, versions = "[1]")
        serverFeed(serverA, apiVersions = listOf(2))
        val updater = updater()
        updater.checkNow()
        val idle = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertEquals("Version 0.1.2-debug needs a newer Shelfarr server", idle.problem)
        assertTrue(files().isEmpty())
    }

    @Test
    fun `changing server drops the previous server's download and asks the new one`() {
        describe(serverA)
        serverFeed(serverA, slowApk = true)
        describe(serverB)
        val updater = updater()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        updater.download()
        updater.await { it is UpdateState.Downloading }
        waitUntil { requests.any { it.target.startsWith("/a/") && it.target.endsWith(".apk") } }

        // Server B serves a different build; its feed uses the same version code.
        val base = serverB.baseUrl.encodedPath
        val apkPath = "$base/apps/android/development/4-${sha256Hex(newer)}.apk"
        routes["$base/apps/android/development.json"] = json(
            feedJson(shelfarr, newer, 4, "0.1.3-debug", apkPath, mapOf("consumer_api_versions" to JsonArray(listOf(JsonPrimitive(1))))),
        )
        routes[apkPath] = { ok(newer) }
        inspector.archive = { AppIdentity(PACKAGE, 4, "0.1.3-debug", setOf(SIGNER), minSdk = 26) }

        current = serverB
        updater.onServerChanged()
        val offered = updater.await { it is UpdateState.Available && it.release.versionCode == 4 } as UpdateState.Available
        assertEquals(apkPath, offered.release.apkUrl.encodedPath)
        assertEquals(serverB.identity, updater.currentBinding?.context)
        waitUntil { files().none { it.endsWith(".part") } }

        updater.download()
        updater.await { it is UpdateState.Ready }
        assertEquals(setOf("update-4.apk"), files())
        assertTrue(apk.size != newer.size && File(directory, "update-4.apk").readBytes().contentEquals(newer))
    }

    @Test
    fun `an answer for the previous server is discarded`() {
        describe(serverA)
        routes["/a/apps/android/development.json"] = {
            Thread.sleep(400)
            ok(feedJson(shelfarr, apk, 3, "0.1.2-debug", "/a/apps/android/development/3-x.apk", mapOf("consumer_api_versions" to JsonArray(listOf(JsonPrimitive(1))))))
        }
        val updater = updater()
        updater.checkNow()
        waitUntil { requests.any { it.target == "/a/apps/android/development.json" } }
        current = null
        Thread.sleep(800)
        assertFalse(updater.state.value.hasUpdate)
    }

    @Test
    fun `a relaunch keeps a verified download only for the server it was chosen for`() {
        describe(serverA)
        serverFeed(serverA)
        val first = updater()
        first.checkNow()
        first.await { it is UpdateState.Available }
        first.download()
        first.await { it is UpdateState.Ready }

        val same = updater()
        assertTrue(same.state.value is UpdateState.Ready)
        assertEquals(serverA.identity, same.currentBinding?.context)

        // Signed in elsewhere since: the next launch neither offers nor keeps it, and checks again.
        current = serverB
        val elsewhere = updater()
        assertEquals(UpdateState.Idle(), elsewhere.state.value)
        assertTrue(files().isEmpty())
        describe(serverB)
        serverFeed(serverB)
        elsewhere.onForeground()
        elsewhere.await { it is UpdateState.Available && it.release.apkUrl.encodedPath.startsWith("/b/") }
    }

    private fun installingForA(): AppUpdater {
        describe(serverA)
        serverFeed(serverA)
        val updater = updater()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        updater.download()
        updater.await { it is UpdateState.Ready }
        assertEquals(InstallRequest.STARTED, updater.install())
        waitUntil { installer.open.size == 1 }
        return updater
    }

    private fun changeToIncompatibleB(updater: AppUpdater) {
        describe(serverB, versions = "[2]")
        serverFeed(serverB, apiVersions = listOf(1))
        current = serverB
        updater.onServerChanged()
    }

    private fun assertBCheckedWithoutOldOffer(updater: AppUpdater) {
        updater.await { it is UpdateState.Idle && updater.currentBinding?.context == serverB.identity && it.problem != null }
        assertEquals(InstallRequest.IGNORED, updater.install())
        assertTrue(files().isEmpty())
        assertEquals(1, installer.committed.size)
    }

    @Test
    fun `cancelling an installation reconciles a deferred server change immediately`() {
        val updater = installingForA()
        changeToIncompatibleB(updater)
        updater.cancelInstall()
        assertBCheckedWithoutOldOffer(updater)
    }

    @Test
    fun `an installer failure reconciles a deferred server change immediately`() {
        val updater = installingForA()
        val session = installer.open.single()
        changeToIncompatibleB(updater)
        runBlocking { updater.onInstallStatus(installer.finish(session, PackageInstaller.STATUS_FAILURE_STORAGE)).join() }
        assertBCheckedWithoutOldOffer(updater)
    }

    @Test
    fun `a disappeared installer session reconciles a deferred server change immediately`() {
        val updater = installingForA()
        changeToIncompatibleB(updater)
        installer.open.clear()
        updater.reconcileInstalling()
        assertBCheckedWithoutOldOffer(updater)
    }

    @Test
    fun `cancelling a restored installation checks the newly connected server`() {
        val first = installingForA()
        changeToIncompatibleB(first)
        val restored = updater()
        assertTrue(restored.state.value is UpdateState.Installing)
        restored.cancelInstall()
        assertBCheckedWithoutOldOffer(restored)
    }

    @Test
    fun `install refuses a stale offer even before the server-change event is handled`() {
        describe(serverA)
        serverFeed(serverA)
        val updater = updater()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        updater.download()
        updater.await { it is UpdateState.Ready }
        describe(serverB, versions = "[2]")
        serverFeed(serverB, apiVersions = listOf(1))
        current = serverB
        assertEquals(InstallRequest.IGNORED, updater.install())
        updater.await { it is UpdateState.Idle && updater.currentBinding?.context == serverB.identity && it.problem != null }
        assertTrue(installer.committed.isEmpty())
    }

    @Test
    fun `state saved by the version before discovery still reports a finished update`() {
        // What v3 (built-in feed only) left after handing version 4 to Android.
        val release = UpdateManifest.parse(feedJson(publisher, apk, 4, "0.1.3-debug", "/downloads/shelfarr-4.apk"), FeedExpectation(builtIn, "development", PACKAGE))
        File(directory, "state.json").writeText(
            kotlinx.serialization.json.buildJsonObject {
                put("last_checked_at", JsonPrimitive(now))
                put("release", JsonPrimitive(release.toJson()))
                put("artifact", JsonPrimitive("update-4.apk"))
                put("session_id", JsonPrimitive(77))
            }.toString(),
        )
        File(directory, "update-4.apk").writeBytes(apk)
        inspector.installed = inspector.installed.copy(versionCode = 4, versionName = "0.1.3-debug")
        val updater = updater()
        assertEquals("Updated to 0.1.3-debug", (updater.state.value as UpdateState.Idle).notice)
        assertTrue(files().isEmpty())
    }

    @Test
    fun `state saved by the version before discovery is kept while signed out`() {
        current = null
        val release = UpdateManifest.parse(feedJson(publisher, apk, 3, "0.1.2-debug"), FeedExpectation(builtIn, "development", PACKAGE))
        File(directory, "state.json").writeText(
            """{"last_checked_at":$now,"release":${JsonPrimitive(release.toJson())},"artifact":"update-3.apk"}""",
        )
        File(directory, "update-3.apk").writeBytes(apk)
        val updater = updater()
        assertEquals(UpdateState.Ready(release), updater.state.value)
        assertEquals(builtIn, updater.currentBinding?.source)
    }

    @Test
    fun `automatic downloads start after a successful check and never install`() {
        describe(serverA)
        serverFeed(serverA)
        autoDownload = true
        val updater = updater()
        updater.onForeground()
        updater.await { it is UpdateState.Ready }
        Thread.sleep(200)
        assertTrue("Installing always waits for the person", installer.committed.isEmpty())
        assertTrue(installer.open.isEmpty())
    }

    @Test
    fun `without automatic downloads only the feed is fetched`() {
        describe(serverA)
        serverFeed(serverA)
        val updater = updater()
        updater.onForeground()
        updater.await { it is UpdateState.Available }
        Thread.sleep(300)
        assertEquals(listOf("/a/api/consumer/v1/server.json", "/a/apps/android/development.json"), requests.map { it.target })
    }

    @Test
    fun `signed out, only the built-in feed is used`() {
        current = null
        describe(serverA)
        serverFeed(serverA)
        publisherFeed()
        val updater = updater()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        assertTrue(requestsTo(shelfarr).isEmpty())
        assertEquals(UpdateBinding(builtIn, null, null), updater.currentBinding)
    }

    @Test
    fun `signed out without a built-in feed explains when asked`() {
        current = null
        val updater = updater(builtIn = null)
        assertTrue(updater.enabled)
        updater.checkNow()
        val idle = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertEquals("Connect to your Shelfarr server to check for updates", idle.problem)
        assertTrue(requests.isEmpty())
    }
}
