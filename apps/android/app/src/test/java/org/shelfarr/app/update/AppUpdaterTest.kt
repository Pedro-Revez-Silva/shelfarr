package org.shelfarr.app.update

import android.content.Intent
import android.content.pm.PackageInstaller
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockResponseBody
import okio.Buffer
import okio.BufferedSink
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Drives the updater against a real HTTPS publisher, with PackageManager, Android's
 * installer and the player replaced by recorders.
 */
class AppUpdaterTest {
    @get:Rule val folder = TemporaryFolder()

    private val origin = TestTls.httpsServer()
    private val apk = Random(3).nextBytes(200_000)
    private val source = requireNotNull(UpdateSource.parse(origin.url("/downloads/android-development.json").toString()))
    private val inspector = FakeInspector()
    private val installer = FakeInstaller()
    private val playback = FakePlayback()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var now = 1_800_000_000_000L
    private var saves = 0
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = folder.newFolder("updates")
    }

    @After
    fun tearDown() {
        scope.cancel()
        origin.close()
    }

    private fun updater(
        source: UpdateSource? = this.source,
        sessionInstaller: PackageSessionInstaller = installer,
        start: Boolean = true,
    ): AppUpdater = AppUpdater(
        source = source,
        channel = "development",
        fetcher = source?.let { UpdateFetcher(TestTls.trustingClient(), it) },
        inspector = inspector,
        installer = sessionInstaller,
        directory = directory,
        playback = playback,
        scope = scope,
        beforeInstall = { saves++ },
        clock = { now },
        sdkInt = 35,
    ).also { updater -> if (start) updater.start()?.let { runBlocking { it.join() } } }

    private fun AppUpdater.await(predicate: (UpdateState) -> Boolean): UpdateState =
        runBlocking { withTimeout(10_000) { state.first(predicate) } }

    private fun publish(versionCode: Int = 3, bytes: ByteArray = apk, vararg extra: Pair<String, JsonPrimitive>) {
        // Version code n is named 0.1.(n-1): the installed build is 2, "0.1.1-debug".
        origin.enqueue(ok(feedJson(origin, bytes, versionCode, "0.1.${versionCode - 1}-debug", overrides = extra.toMap())))
    }

    private fun serveApk(bytes: ByteArray = apk) = origin.enqueue(ok(bytes))

    private fun files(): Set<String> = directory.list().orEmpty().toSet() - "state.json"

    /** An updater holding a verified download of version 3. */
    private fun ready(): AppUpdater = updater().apply {
        publish()
        checkNow()
        await { it is UpdateState.Available }
        serveApk()
        download()
        await { it is UpdateState.Ready }
    }

    private fun waitUntil(condition: () -> Boolean) = runBlocking {
        withTimeout(10_000) { while (!condition()) delay(10) }
    }

    @Test
    fun `offers nothing when the feed announces this version or an older one`() {
        val updater = updater()
        listOf(2, 1).forEach { version ->
            publish(versionCode = version)
            now += 1
            updater.checkNow()
            val state = updater.await { it is UpdateState.Idle && it.lastCheckedAtMs == now && !it.checking }
            assertNull((state as UpdateState.Idle).problem)
        }
        assertEquals("Only the feed was fetched", 2, origin.requestCount)
        assertTrue(files().isEmpty())
    }

    @Test
    fun `offers a newer release and downloads only when asked`() {
        val updater = updater()
        publish()
        updater.checkNow()
        val available = updater.await { it is UpdateState.Available } as UpdateState.Available
        assertEquals("0.1.2-debug", available.release.versionName)
        assertEquals("Faster library loading.", available.release.releaseNotes)
        Thread.sleep(200)
        assertEquals("Nothing downloaded without asking", 1, origin.requestCount)

        serveApk()
        updater.download()
        updater.await { it is UpdateState.Ready }
        assertEquals(setOf("update-3.apk"), files())
        assertTrue(apk.contentEquals(File(directory, "update-3.apk").readBytes()))
        assertTrue(installer.committed.isEmpty())
    }

    @Test
    fun `refuses a download that isn't this app, this version or this publisher`() {
        val updater = updater()
        publish()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        val impostors = listOf(
            AppIdentity("com.evil.debug", 3, "0.1.2-debug", setOf(SIGNER)),
            AppIdentity(PACKAGE, 3, "0.1.2-debug", setOf(OTHER_SIGNER)),
            AppIdentity(PACKAGE, 3, "0.1.2-debug", setOf(SIGNER, OTHER_SIGNER)),
            AppIdentity(PACKAGE, 4, "0.1.2-debug", setOf(SIGNER)),
            AppIdentity(PACKAGE, 3, "0.1.9-debug", setOf(SIGNER)),
            AppIdentity(PACKAGE, 3, "0.1.2-debug", setOf(SIGNER), minSdk = 36),
            null,
        )
        impostors.forEach { impostor ->
            inspector.archive = { impostor }
            serveApk()
            updater.download()
            val state = updater.await { it is UpdateState.Available && it.problem != null } as UpdateState.Available
            assertNotNull("$impostor", state.problem)
            assertTrue("$impostor left a file behind", files().isEmpty())
        }
        assertTrue(installer.committed.isEmpty())
    }

    @Test
    fun `an apk that isn't newer than the installed app is refused even if the feed says so`() {
        inspector.installed = inspector.installed.copy(versionCode = 2)
        inspector.archive = { AppIdentity(PACKAGE, 2, "0.1.2-debug", setOf(SIGNER)) }
        val updater = updater()
        publish()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        serveApk()
        updater.download()
        val state = updater.await { it is UpdateState.Available && it.problem != null } as UpdateState.Available
        assertEquals("The update file isn't the announced version", state.problem)
    }

    @Test
    fun `a tampered download is refused before Android ever sees it`() {
        val updater = updater()
        publish()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        serveApk(apk.copyOf().also { it[0] = (it[0] + 1).toByte() })
        updater.download()
        val state = updater.await { it is UpdateState.Available && it.problem != null } as UpdateState.Available
        assertEquals("The update file doesn't match its published checksum", state.problem)
        assertTrue(inspector.inspected.isEmpty())
        assertTrue(files().isEmpty())
    }

    @Test
    fun `asking twice downloads once`() {
        val updater = updater()
        publish()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        origin.enqueue(MockResponse.Builder().code(200).body(Buffer().write(apk)).throttleBody(50_000, 100, TimeUnit.MILLISECONDS).build())
        repeat(3) { updater.download() }
        updater.await { it is UpdateState.Ready }
        assertEquals(2, origin.requestCount)
    }

    @Test
    fun `cancelling a download leaves nothing behind and it can be retried`() {
        val updater = updater()
        publish()
        updater.checkNow()
        updater.await { it is UpdateState.Available }
        val firstChunk = CountDownLatch(1)
        val finishBody = CountDownLatch(1)
        val body = object : MockResponseBody {
            override val contentLength = apk.size.toLong()
            override fun writeTo(sink: BufferedSink) {
                sink.write(apk, 0, 8_192)
                sink.flush()
                firstChunk.countDown()
                check(finishBody.await(10, TimeUnit.SECONDS))
                sink.write(apk, 8_192, apk.size - 8_192)
            }
        }
        try {
            origin.enqueue(MockResponse.Builder().code(200).body(body).build())
            updater.download()
            assertTrue(firstChunk.await(10, TimeUnit.SECONDS))
            // Small files need not emit intermediate progress. Hold the response
            // until bytes are on disk so cancellation cannot race a completed transfer.
            waitUntil {
                directory.listFiles().orEmpty().any {
                    it.name.endsWith(".apk.part") && it.length() in 1 until apk.size.toLong()
                }
            }
            updater.cancelDownload()
            assertTrue(updater.state.value is UpdateState.Available)
            waitUntil { files().isEmpty() }
            finishBody.countDown()

            serveApk()
            updater.download()
            updater.await { it is UpdateState.Ready }
            assertEquals(setOf("update-3.apk"), files())
        } finally {
            finishBody.countDown()
        }
    }

    @Test
    fun `cancelled archive inspection cannot delete an immediate retry's partial file`() {
        val inspecting = CountDownLatch(1)
        val finishInspection = CountDownLatch(1)
        val inspections = AtomicInteger()
        inspector.archive = {
            if (inspections.getAndIncrement() == 0) {
                inspecting.countDown()
                check(finishInspection.await(10, TimeUnit.SECONDS))
            }
            AppIdentity(PACKAGE, 3, "0.1.2-debug", setOf(SIGNER))
        }
        val updater = updater()
        try {
            publish()
            updater.checkNow()
            updater.await { it is UpdateState.Available }
            serveApk()
            updater.download()
            assertTrue(inspecting.await(10, TimeUnit.SECONDS))
            updater.cancelDownload()
            origin.enqueue(MockResponse.Builder().code(200).body(Buffer().write(apk))
                .throttleBody(8_192, 25, TimeUnit.MILLISECONDS).build())
            updater.download()
            waitUntil {
                directory.listFiles().orEmpty().any {
                    it.name.endsWith(".apk.part") && it.length() in 1 until apk.size.toLong()
                }
            }
            finishInspection.countDown()
            updater.await { it is UpdateState.Ready }
            waitUntil { files() == setOf("update-3.apk") }
            assertTrue(apk.contentEquals(File(directory, "update-3.apk").readBytes()))
        } finally {
            finishInspection.countDown()
        }
    }

    @Test
    fun `installs only when asked, after saving places, and reports Android's confirmation`() {
        val updater = ready()
        assertEquals(InstallRequest.STARTED, updater.install())
        waitUntil { installer.committed.isNotEmpty() }
        assertTrue(apk.contentEquals(installer.committed.single()))
        assertEquals(1, saves)

        val session = installer.open.single()
        val prompt = Intent()
        updater.onInstallStatus(InstallStatus(session, PackageInstaller.STATUS_PENDING_USER_ACTION, prompt))
        assertEquals(PendingConfirmation(session, prompt), updater.confirmation.value)
        assertEquals(true, (updater.state.value as UpdateState.Installing).awaitingConfirmation)
        updater.confirmationShown(session)
        assertNull(updater.confirmation.value)
        updater.showPromptAgain()
        assertNotNull(updater.confirmation.value)

        updater.onInstallStatus(installer.finish(session))
        assertEquals("Updated to 0.1.2-debug", (updater.state.value as UpdateState.Idle).notice)
        assertTrue(files().isEmpty())
    }

    @Test
    fun `never interrupts audio on its own`() {
        val updater = ready()
        playback.playing = true
        assertEquals(InstallRequest.PLAYBACK_ACTIVE, updater.install())
        Thread.sleep(200)
        assertEquals(0, playback.pauses)
        assertTrue(installer.committed.isEmpty())
        assertTrue(updater.state.value is UpdateState.Ready)

        assertEquals(InstallRequest.STARTED, updater.install(pausePlayback = true))
        assertEquals(1, playback.pauses)
        waitUntil { installer.committed.isNotEmpty() }
    }

    @Test
    fun `asks for the install permission, and continues only once it is allowed`() {
        installer.allowed = false
        val updater = ready()
        assertEquals(InstallRequest.NEEDS_PERMISSION, updater.install())
        assertTrue(updater.state.value is UpdateState.NeedsPermission)
        // Came back from Android's settings without allowing it.
        assertEquals(InstallRequest.NEEDS_PERMISSION, updater.onPermissionReturned())
        updater.dismissPermission()
        assertTrue(updater.state.value is UpdateState.Ready)
        assertTrue(installer.committed.isEmpty())

        updater.install()
        installer.allowed = true
        assertEquals(InstallRequest.STARTED, updater.onPermissionReturned())
        waitUntil { installer.committed.isNotEmpty() }
    }

    @Test
    fun `a downloaded file changed afterwards is fetched again, not installed`() {
        val updater = ready()
        File(directory, "update-3.apk").writeBytes(apk.copyOf().also { it[10] = (it[10] + 1).toByte() })
        updater.install()
        val state = updater.await { it is UpdateState.Available } as UpdateState.Available
        assertEquals("The downloaded update has changed. Download it again.", state.problem)
        assertTrue(installer.committed.isEmpty())
        assertTrue(files().isEmpty())
    }

    @Test
    fun `Android's outcomes are reported, and only a rejected file is thrown away`() {
        val updater = ready()
        val outcomes = listOf(
            PackageInstaller.STATUS_FAILURE_ABORTED to "Installation cancelled",
            PackageInstaller.STATUS_FAILURE_STORAGE to "There isn't enough space to install the update",
            PackageInstaller.STATUS_FAILURE_BLOCKED to "Android blocked the installation",
            PackageInstaller.STATUS_FAILURE to "Android couldn't install the update",
        )
        outcomes.forEach { (code, notice) ->
            assertEquals(InstallRequest.STARTED, updater.install())
            waitUntil { installer.open.isNotEmpty() }
            val session = installer.open.single()
            // A report for some other session changes nothing.
            updater.onInstallStatus(InstallStatus(session + 100, PackageInstaller.STATUS_SUCCESS))
            assertTrue(updater.state.value is UpdateState.Installing)
            updater.onInstallStatus(installer.finish(session, code))
            assertEquals(UpdateState.Ready(updater.state.value.release!!, notice), updater.state.value)
            assertEquals(setOf("update-3.apk"), files())
        }

        updater.install()
        waitUntil { installer.open.isNotEmpty() }
        updater.onInstallStatus(installer.finish(installer.open.single(), PackageInstaller.STATUS_FAILURE_INVALID))
        assertTrue(updater.state.value is UpdateState.Available)
        assertTrue(files().isEmpty())
    }

    @Test
    fun `one installation at a time`() {
        val updater = ready()
        assertEquals(InstallRequest.STARTED, updater.install())
        assertEquals(InstallRequest.IGNORED, updater.install())
        assertEquals(InstallRequest.IGNORED, updater.install(pausePlayback = true))
        waitUntil { installer.committed.isNotEmpty() }
        Thread.sleep(100)
        assertEquals(1, installer.committed.size)
        updater.download()
        updater.checkNow()
        Thread.sleep(200)
        assertEquals("No check or download while installing", 2, origin.requestCount)
    }

    @Test
    fun `cancelling an installation abandons its session and keeps the download`() {
        val updater = ready()
        updater.install()
        waitUntil { installer.open.isNotEmpty() }
        val session = installer.open.single()
        updater.cancelInstall()
        assertEquals(listOf(session), installer.abandoned)
        assertTrue(updater.state.value is UpdateState.Ready)
        assertEquals(setOf("update-3.apk"), files())
    }

    @Test
    fun `a session created after Cancel is abandoned and never committed`() {
        val creating = CountDownLatch(1)
        val finishCreation = CountDownLatch(1)
        val commitFinished = CountDownLatch(1)
        val commits = AtomicInteger()
        val delayed = object : PackageSessionInstaller by installer {
            override suspend fun commit(apk: File, onCreated: (Int) -> Unit) = withContext(Dispatchers.IO) {
                try {
                    creating.countDown()
                    check(finishCreation.await(10, TimeUnit.SECONDS))
                    // Like a blocking Android call, creation itself did not suspend.
                    onCreated(77)
                    commits.incrementAndGet()
                    Unit
                } finally {
                    commitFinished.countDown()
                }
            }
        }
        val updater = updater(sessionInstaller = delayed)
        try {
            publish()
            updater.checkNow()
            updater.await { it is UpdateState.Available }
            serveApk()
            updater.download()
            updater.await { it is UpdateState.Ready }
            updater.install()
            assertTrue(creating.await(10, TimeUnit.SECONDS))
            updater.cancelInstall()
            finishCreation.countDown()
            assertTrue(commitFinished.await(10, TimeUnit.SECONDS))
            assertEquals(0, commits.get())
            assertTrue(77 in installer.abandoned)
            assertTrue(updater.state.value is UpdateState.Ready)
        } finally {
            finishCreation.countDown()
        }
    }

    @Test
    fun `a session Android dropped without reporting is noticed`() {
        val updater = ready()
        updater.install()
        waitUntil { installer.open.isNotEmpty() }
        updater.reconcileInstalling()
        assertTrue("Still open: keep waiting", updater.state.value is UpdateState.Installing)
        installer.open.clear()
        updater.reconcileInstalling()
        assertEquals("The installation didn't finish", (updater.state.value as UpdateState.Ready).notice)
    }

    @Test
    fun `a relaunch keeps a verified download`() {
        ready()
        val relaunched = updater()
        assertTrue(relaunched.state.value is UpdateState.Ready)
        assertEquals("Nothing fetched again", 2, origin.requestCount)
    }

    @Test
    fun `a relaunch during installation keeps waiting for Android, then recovers`() {
        val first = ready()
        first.install()
        waitUntil { installer.open.isNotEmpty() }
        val session = installer.open.single()

        val relaunched = updater()
        assertTrue(relaunched.state.value is UpdateState.Installing)
        assertFalse("The open session is left to Android", session in installer.abandoned)
        // Android's prompt for that session can still arrive in the new process.
        relaunched.onInstallStatus(InstallStatus(session, PackageInstaller.STATUS_PENDING_USER_ACTION, Intent()))
        assertNotNull(relaunched.confirmation.value)

        installer.open.clear()
        val later = updater()
        assertEquals("The last installation didn't finish", (later.state.value as UpdateState.Ready).notice)
    }

    @Test
    fun `a cold installer confirmation waits for the saved session to be restored`() {
        val first = ready()
        first.install()
        waitUntil { installer.open.isNotEmpty() }
        val session = installer.open.single()
        val restoring = CountDownLatch(1)
        val finishRestore = CountDownLatch(1)
        val delayed = object : PackageSessionInstaller by installer {
            override fun isOpen(sessionId: Int): Boolean {
                restoring.countDown()
                check(finishRestore.await(10, TimeUnit.SECONDS))
                return installer.isOpen(sessionId)
            }
        }
        val cold = updater(sessionInstaller = delayed, start = false)
        try {
            val restore = requireNotNull(cold.start())
            assertTrue(restoring.await(10, TimeUnit.SECONDS))
            cold.onInstallStatus(InstallStatus(session, PackageInstaller.STATUS_PENDING_USER_ACTION, Intent()))
            assertNull(cold.confirmation.value)
            finishRestore.countDown()
            runBlocking { withTimeout(10_000) { restore.join() } }
            cold.await { it is UpdateState.Installing && it.awaitingConfirmation }
            assertNotNull(cold.confirmation.value)
            val state = cold.state.value as UpdateState.Installing
            assertTrue(state.awaitingConfirmation)
            assertTrue(state.canShowPrompt)
        } finally {
            finishRestore.countDown()
        }
    }

    @Test
    fun `after Android installs the update, the next launch says so and cleans up`() {
        val updater = ready()
        updater.install()
        waitUntil { installer.open.isNotEmpty() }
        // Android replaced the process: no status ever reached the old one.
        inspector.installed = inspector.installed.copy(versionCode = 3, versionName = "0.1.2-debug")
        installer.open.clear()
        val relaunched = updater()
        assertEquals("Updated to 0.1.2-debug", (relaunched.state.value as UpdateState.Idle).notice)
        assertTrue(files().isEmpty())
    }

    @Test
    fun `unreadable saved state is forgotten, not trusted`() {
        File(directory, "state.json").writeText("{\"release\": \"{\\\"schema_version\\\": 9}\", \"artifact\": \"../../evil.apk\"}")
        File(directory, "leftover.apk.part").writeBytes(ByteArray(10))
        val updater = updater()
        assertEquals(UpdateState.Idle(), updater.state.value)
        assertTrue(files().isEmpty())
        File(directory, "state.json").writeText("not json")
        assertEquals(UpdateState.Idle(), updater().state.value)
    }

    @Test
    fun `checks on its own at most every few hours, and retries a failure sooner`() {
        val updater = updater()
        publish(versionCode = 2)
        updater.onForeground()
        updater.await { it is UpdateState.Idle && it.lastCheckedAtMs == now }
        updater.onForeground()
        Thread.sleep(200)
        assertEquals(1, origin.requestCount)

        now += AppUpdater.AUTO_CHECK_INTERVAL_MS
        origin.enqueue(MockResponse.Builder().code(503).build())
        updater.onForeground()
        waitUntil { origin.requestCount == 2 }
        Thread.sleep(200)
        assertNull("An automatic check fails quietly", (updater.state.value as UpdateState.Idle).problem)

        now += AppUpdater.RETRY_INTERVAL_MS - 1
        updater.onForeground()
        Thread.sleep(200)
        assertEquals(2, origin.requestCount)
        now += 1
        publish(versionCode = 3)
        updater.onForeground()
        updater.await { it is UpdateState.Available }
    }

    @Test
    fun `a check the person asked for explains a failure`() {
        val updater = updater()
        origin.enqueue(ok("{\"schema_version\": 1, \"channel\": \"development\", \"package_name\": \"org.shelfarr.app\"}"))
        updater.checkNow()
        val state = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertEquals("The update feed is for a different app", state.problem)
    }

    @Test
    fun `an update that needs a newer Android isn't offered`() {
        val updater = updater()
        publish(3, apk, "min_sdk" to JsonPrimitive(36))
        updater.checkNow()
        val state = updater.await { it is UpdateState.Idle && it.problem != null } as UpdateState.Idle
        assertEquals("Version 0.1.2-debug needs a newer version of Android", state.problem)
    }

    @Test
    fun `a newer release replaces an older download`() {
        val updater = ready()
        val newer = Random(4).nextBytes(150_000)
        publish(versionCode = 4, bytes = newer)
        now += 1
        updater.checkNow()
        val state = updater.await { it is UpdateState.Available } as UpdateState.Available
        assertEquals(4, state.release.versionCode)
        waitUntil { files().isEmpty() }
    }

    @Test
    fun `a build without a feed never reaches the network`() {
        val updater = updater(source = null)
        assertEquals(UpdateState.Disabled, updater.state.value)
        updater.onForeground()
        updater.checkNow()
        updater.download()
        assertEquals(InstallRequest.IGNORED, updater.install())
        Thread.sleep(200)
        assertEquals(0, origin.requestCount)
        assertFalse(updater.enabled)
    }
}
