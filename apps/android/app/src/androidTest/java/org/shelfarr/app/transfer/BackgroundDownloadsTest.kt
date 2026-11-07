package org.shelfarr.app.transfer

import android.Manifest
import android.app.NotificationManager
import android.app.job.JobScheduler
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.SystemClock
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsNodeInteractionCollection
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContinueList
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.ui.MainActivity

/**
 * Drives the real app: Library → details → Download, then the OS host, the progress
 * notification and its Cancel and open actions, a system stop and forced re-run while
 * the UI is stopped, and offline Library browsing once the server is gone. Uses a
 * test-only account against a local fixture server; nothing here touches real data.
 *
 * The test process is the app process, so it can't show survival of a killed process;
 * the JVM tests cover reloading from disk. What it does show is the OS callbacks.
 */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class BackgroundDownloadsTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container
    private val web = MockWebServer()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()
    private val slow = AtomicBoolean(true)
    private lateinit var session: Session

    private val track = ByteArray(480_000) { (it % 253).toByte() }
    private val epub = byteArrayOf('P'.code.toByte(), 'K'.code.toByte()) + ByteArray(20_000) { 7 }

    private val book = Publication(
        id = "bg-book", title = "Background book", author = "Fixture Author", bookType = BookType.EBOOK,
        assets = listOf(Asset("bg-epub", "b.epub", "application/epub+zip", "epub", epub.size.toLong(), "/files/epub")),
    )
    private val audiobook = Publication(
        id = "bg-audio", title = "Background audio", author = "Fixture Narrator", bookType = BookType.AUDIOBOOK,
        assets = listOf(Asset("bg-track", "1.wav", "audio/wav", "wav", track.size.toLong(), "/files/track", 1)),
    )

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                if (request.headers["Authorization"] != "Bearer background-fixture") return MockResponse.Builder().code(401).build()
                return when (request.target.substringBefore('?')) {
                    "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me("background-fixture")))
                    "/api/consumer/v1/continue" -> json(ApiJson.encodeToString(ContinueList()))
                    "/api/consumer/v1/library" -> json(ApiJson.encodeToString(LibraryPage(listOf(audiobook, book))))
                    "/api/consumer/v1/library/bg-book" -> json(ApiJson.encodeToString(book))
                    "/api/consumer/v1/library/bg-audio" -> json(ApiJson.encodeToString(audiobook))
                    "/files/epub" -> ranged(request, epub, "\"epub\"")
                    "/files/track" -> ranged(request, track, "\"track\"")
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        session = Session(server, Me("background-fixture"), "background-fixture")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.POST_NOTIFICATIONS)
        }
        container.askedForNotifications = true
        container.sessions.signIn(session)
    }

    @After
    fun tearDown() {
        runBlocking {
            container.currentAccount()?.let { account ->
                account.close()
                account.directory.deleteRecursively()
            }
        }
        container.transfers.cancel()
        container.transferNotifications.cancelProgress()
        container.sessions.clear()
        runCatching { web.close() }
    }

    @Test
    fun downloadsFromTheLibraryKeepGoingInTheBackgroundAndBrowseOffline() {
        ActivityScenario.launch<MainActivity>(Intent(app, MainActivity::class.java)).use { scenario ->
            // Library → details → Download.
            compose.waitUntil(15_000) { compose.onAllNodes(hasText("Library") and hasClickAction()).exists() }
            compose.onAllNodes(hasText("Library") and hasClickAction())[0].performClick()
            waitForText("Background audio")
            compose.onAllNodesWithText("Background audio")[0].performClick()
            waitForText("Download ·", substring = true)
            compose.onAllNodesWithText("Download ·", substring = true)[0].performClick()
            awaitState("bg-audio", DownloadState.DOWNLOADING)

            // Android was asked for a user-visible transfer while the app was on screen.
            val jobs = app.getSystemService(JobScheduler::class.java)
            val job = requireNotNull(jobs.getPendingJob(TransferScheduler.JOB_ID)) { "No download job was scheduled" }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) assertTrue("User-initiated transfer", job.isUserInitiated)

            // The progress notification names the title and can cancel it.
            val notification = awaitProgressNotification()
            val title = notification.extras.getCharSequence("android.title").toString()
            assertTrue(title, title.contains("Background audio"))
            val cancel = notification.actions.single()
            assertEquals("Cancel", cancel.title.toString())
            cancel.actionIntent.send()
            awaitState("bg-audio", DownloadState.CANCELLED)
            assertEquals(0L, record("bg-audio").bytesDone)

            // Tapping the notification opens Downloads.
            notification.contentIntent.send()
            waitForText("Download cancelled")
            capture("downloads-after-cancel.png")

            // Start again, then leave the app: the OS host keeps it going.
            compose.onAllNodesWithText("Download again")[0].performClick()
            awaitState("bg-audio", DownloadState.DOWNLOADING)
            awaitProgressNotification()
            scenario.moveToState(Lifecycle.State.CREATED)
            await("the app is no longer visible") { !container.isVisible }

            // The system stops the job, as on a quota or timeout: bytes are kept, nothing is called ready.
            shell("cmd jobscheduler timeout ${app.packageName} ${TransferScheduler.JOB_ID}")
            await("the transfer paused for the next run") { record("bg-audio").state == DownloadState.QUEUED && record("bg-audio").bytesDone > 0 }
            assertTrue(container.currentAccount()!!.downloads.ready("bg-audio") == null)
            assertNotNull("The stopped job is rescheduled", jobs.getPendingJob(TransferScheduler.JOB_ID))

            // The OS runs it again while the UI is still stopped: it resumes with a validated range.
            slow.set(false)
            val before = requests.count { it.target == "/files/track" }
            shell("cmd jobscheduler run -f ${app.packageName} ${TransferScheduler.JOB_ID}")
            awaitState("bg-audio", DownloadState.READY)
            val resumed = requests.filter { it.target == "/files/track" }.drop(before).first()
            assertTrue(resumed.headers["Range"].orEmpty().startsWith("bytes="))
            assertEquals("\"track\"", resumed.headers["If-Range"])
            val file = container.currentAccount()!!.downloads.let { it.filesFor(it.ready("bg-audio")!!) }!!.values.single()
            assertTrue("The resumed file is byte-identical", file.readBytes().contentEquals(track))

            // The server goes away. The library still browses from this device, and says so.
            web.close()
            scenario.moveToState(Lifecycle.State.RESUMED)
            scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
            waitForText("Offline · saved on this device")
            waitForText("Background book")
            capture("library-offline.png")
            compose.onNode(hasSetTextAction()).performTextInput("audio")
            compose.waitUntil(10_000) { !compose.onAllNodesWithText("Background book").exists() }
            compose.onAllNodesWithText("Background audio")[0].performClick()
            waitForText("Offline. Opening the download on this device.")
            capture("details-offline-download.png")
        }
    }

    @Test
    fun aNotificationCancelForAnotherAccountIsIgnored() {
        val downloads = container.currentAccount()!!.downloads
        runBlocking {
            downloads.start()
            downloads.enqueue(audiobook)
        }
        awaitState("bg-audio", DownloadState.DOWNLOADING)
        app.sendBroadcast(cancelIntent("another-account"))
        SystemClock.sleep(1_500)
        assertTrue("Still downloading", record("bg-audio").isActive)
        app.sendBroadcast(cancelIntent(session.accountKey))
        awaitState("bg-audio", DownloadState.CANCELLED)
    }

    private fun cancelIntent(accountKey: String) = Intent(app, DownloadActionReceiver::class.java)
        .setAction(DownloadActionReceiver.ACTION_CANCEL)
        .putExtra(DownloadActionReceiver.EXTRA_ACCOUNT, accountKey)
        .putExtra(DownloadActionReceiver.EXTRA_IDS, arrayOf("bg-audio"))

    private fun ranged(request: RecordedRequest, bytes: ByteArray, etag: String): MockResponse {
        val start = request.headers["Range"]?.removePrefix("bytes=")?.substringBefore('-')?.toIntOrNull()
        val builder = if (start != null && request.headers["If-Range"] == etag) {
            MockResponse.Builder().code(206)
                .addHeader("Content-Range", "bytes $start-${bytes.size - 1}/${bytes.size}")
                .body(Buffer().write(bytes, start, bytes.size - start))
        } else {
            MockResponse.Builder().code(200).body(Buffer().write(bytes))
        }
        builder.addHeader("ETag", etag)
        // Slow enough to observe and interrupt; a real phone would be on a real network.
        if (slow.get()) builder.throttleBody(16_000, 250, TimeUnit.MILLISECONDS)
        return builder.build()
    }

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private fun record(id: String): DownloadRecord = requireNotNull(container.currentAccount()?.downloads?.record(id)) { "No record for $id" }

    private fun awaitState(id: String, state: DownloadState) = await("$id is $state") {
        container.currentAccount()?.downloads?.record(id)?.state == state
    }

    private fun awaitProgressNotification(): android.app.Notification {
        val manager = app.getSystemService(NotificationManager::class.java)
        var found: android.app.Notification? = null
        await("a progress notification with a Cancel action") {
            found = manager.activeNotifications.firstOrNull { it.id == TransferNotifications.PROGRESS_ID && it.notification.actions?.isNotEmpty() == true }?.notification
            found != null
        }
        return found!!
    }

    private fun shell(command: String) {
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command).use { descriptor ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() }
        }
    }

    private fun waitForText(text: String, substring: Boolean = false) =
        compose.waitUntil(20_000) { compose.onAllNodesWithText(text, substring = substring).exists() }

    private fun SemanticsNodeInteractionCollection.exists() = fetchSemanticsNodes().isNotEmpty()

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        assertTrue("Timed out waiting for $description", condition())
    }

    private fun capture(name: String) {
        val output = InstrumentationRegistry.getArguments().getString("additionalTestOutputDir") ?: return
        val folder = File(output)
        if (!folder.isDirectory && !folder.mkdirs()) return
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        File(folder, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
