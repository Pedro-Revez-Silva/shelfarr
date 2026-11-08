package org.shelfarr.app.upgrade

import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContinueList
import org.shelfarr.app.core.KeystoreSecureStore
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionManager
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.core.StorageLayout
import org.shelfarr.app.reader.ReaderFont
import org.shelfarr.app.reader.ReaderSettings
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.ui.theme.AppearanceMode

/**
 * What an app update must keep, checked across a real package update.
 *
 * `apps/android/tools/upgrade-preservation.sh` installs an older build, runs the
 * `seed` stage (instrumentation argument `shelfarrUpgradeStage=seed`), updates the
 * package in place with a newer build signed with the same key through Android's
 * PackageInstaller (`adb install -r`), then runs `verify` in the new version's fresh
 * process. Between them Android replaces the APK; nothing in the app runs. Without
 * the argument, as in an ordinary `connectedDebugAndroidTest`, both stages are skipped
 * and only [aFreshStoreReadsTheSessionBack] runs, which proves Keystore reading
 * across store instances but not across an update.
 *
 * Fixture data only: a local HTTP fixture server and a synthetic account.
 */
@RunWith(AndroidJUnit4::class)
class UpgradePreservationTest {
    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container
    private val arguments = InstrumentationRegistry.getArguments()
    private val stage: String? = arguments.getString("shelfarrUpgradeStage")
    private val seedFile get() = File(app.filesDir, "upgrade-preservation-seed.json")

    private val epub = byteArrayOf('P'.code.toByte(), 'K'.code.toByte()) + ByteArray(48_000) { (it % 251).toByte() }
    private val book = Publication(
        id = "upgrade-book", title = "Kept across updates", author = "Fixture Author", bookType = BookType.EBOOK,
        assets = listOf(Asset("upgrade-epub", "kept.epub", "application/epub+zip", "epub", epub.size.toLong(), "/files/kept-epub")),
    )
    private val place = SavedPosition("upgrade-epub", buildJsonObject { put("href", JsonPrimitive("chapter-3.xhtml")) })
    private val reader = ReaderSettings(theme = ReaderTheme.entries.last(), font = ReaderFont.entries.last(), fontSize = 1.4, justify = true)

    @Serializable
    private data class Seed(
        val accountKey: String,
        val server: String,
        val userId: String,
        val token: String,
        val fileSha256: String,
        val fileName: String,
        val versionCode: Long,
        val firstInstallTime: Long,
        val lastUpdateTime: Long,
    )

    @Test
    fun aFreshStoreReadsTheSessionBack() {
        val server = (ServerAddress.parse("https://keystore-fixture.invalid") as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me("keystore-fixture"), "keystore-fixture-token")
        // Separate instances read the same encrypted file with the same Keystore key, as a new process would.
        val writer = SessionManager(KeystoreSecureStore(app))
        val previous = writer.session.value
        assumeTrue("Leave a real session alone", previous == SessionState.SignedOut)
        writer.signIn(session)
        try {
            assertEquals(SessionState.SignedIn(session), SessionManager(KeystoreSecureStore(app)).session.value)
            assertTrue(File(StorageLayout.secureDirectory(app), "session.bin").isFile)
        } finally {
            writer.clear()
            container.sessions.clear()
        }
    }

    @Test
    fun seed() {
        assumeTrue("Only when run by upgrade-preservation.sh", stage == "seed")
        val web = MockWebServer()
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.headers["Authorization"] != "Bearer upgrade-fixture-token") return MockResponse.Builder().code(401).build()
                return when (request.target.substringBefore('?')) {
                    "/api/consumer/v1/me" -> json(ApiJson.encodeToString(Me("upgrade-fixture", "Upgrade Reader")))
                    "/api/consumer/v1/continue" -> json(ApiJson.encodeToString(ContinueList()))
                    "/api/consumer/v1/library" -> json(ApiJson.encodeToString(LibraryPage(listOf(book))))
                    "/api/consumer/v1/library/upgrade-book" -> json(ApiJson.encodeToString(book))
                    "/files/kept-epub" -> MockResponse.Builder().code(200).addHeader("ETag", "\"kept\"").body(Buffer().write(epub)).build()
                    // The fixture refuses progress, so the place stays queued on the device.
                    else -> MockResponse.Builder().code(503).build()
                }
            }
        }
        web.start()
        val server = (ServerAddress.parse(web.url("/").toString(), allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me("upgrade-fixture", "Upgrade Reader"), "upgrade-fixture-token")
        container.sessions.signIn(session)
        container.setAppearance(AppearanceMode.DARK)
        container.readerSettings.update { reader }
        // The seed also runs against the published v3 app, before this setting had
        // an accessor. Write its future preference using Android's stable API.
        assertTrue(app.getSharedPreferences("preferences", 0).edit().putBoolean("auto_download_updates", true).commit())
        container.askedForNotifications = true

        val account = container.account(session)
        runBlocking {
            account.ready.join()
            account.downloads.enqueue(book)
        }
        await("the download to finish") { account.downloads.ready(book.id) != null }
        val file = account.downloads.filesFor(account.downloads.ready(book.id)!!)!!.values.single()
        web.close()
        runBlocking {
            val sync = account.progress.sync(book.id)
            sync.begin(null, 0, assets = listOf("upgrade-epub"))
            sync.update(place, System.currentTimeMillis())
            account.progress.flushAll()
            assertTrue("The place waits to be sent", sync.snapshot().let { it.dirty || it.pending != null })
        }

        val info = app.packageManager.getPackageInfo(app.packageName, 0)
        @Suppress("DEPRECATION")
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        val seed = Seed(
            accountKey = session.accountKey,
            server = server.display,
            userId = session.user.id,
            token = session.accessToken,
            fileSha256 = sha256(file),
            fileName = file.relativeTo(app.filesDir).path,
            versionCode = versionCode,
            firstInstallTime = info.firstInstallTime,
            lastUpdateTime = info.lastUpdateTime,
        )
        seedFile.writeText(Json.encodeToString(seed))
        // Let asynchronous preference writes reach disk before the package is replaced.
        SystemClock.sleep(1_000)
    }

    @Test
    fun verify() {
        assumeTrue("Only when run by upgrade-preservation.sh", stage == "verify")
        assertTrue("The seed stage's record survived", seedFile.isFile)
        val seed = Json.decodeFromString<Seed>(seedFile.readText())

        // This really is the same installation, updated in place, at the newer version.
        val info = app.packageManager.getPackageInfo(app.packageName, 0)
        @Suppress("DEPRECATION")
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()
        arguments.getString("shelfarrExpectVersionCode")?.let { assertEquals(it.toLong(), versionCode) }
        assertTrue("Version code grew", versionCode > seed.versionCode)
        assertEquals("Not a reinstall", seed.firstInstallTime, info.firstInstallTime)
        assertTrue("The package was updated", info.lastUpdateTime > seed.lastUpdateTime)

        // The Keystore-encrypted session, its server normalization and account key.
        val signedIn = container.sessions.signedIn
        assertNotNull("Still signed in", signedIn)
        assertEquals(seed.server, signedIn!!.server.display)
        assertEquals(seed.userId, signedIn.user.id)
        assertEquals(seed.token, signedIn.accessToken)
        assertEquals(seed.accountKey, signedIn.accountKey)

        // Preferences.
        assertEquals(AppearanceMode.DARK, container.appearance.value)
        assertEquals(reader, container.readerSettings.settings.value)
        assertEquals(true, container.autoDownloadUpdates.value)
        assertEquals(true, container.askedForNotifications)

        // The downloaded book, its manifest, and the place still waiting to be sent.
        val account = requireNotNull(container.currentAccount())
        assertEquals(StorageLayout.accountDirectory(app, seed.accountKey), account.directory)
        runBlocking { account.ready.join() }
        val record = requireNotNull(account.downloads.ready("upgrade-book")) { "The download is still ready" }
        val file = account.downloads.filesFor(record)!!.values.single()
        assertEquals(seed.fileName, file.relativeTo(app.filesDir).path)
        assertEquals(seed.fileSha256, sha256(file))
        runBlocking {
            val local = account.progress.sync("upgrade-book").snapshot()
            assertEquals(place, local.position)
            assertTrue("Still queued for the server", local.dirty || local.pending != null)
        }

        if (arguments.getString("shelfarrUpgradeCleanup") == "true") {
            runBlocking { account.close() }
            account.directory.deleteRecursively()
            container.sessions.clear()
            seedFile.delete()
        }
    }

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private fun sha256(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 45_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        assertTrue("Timed out waiting for $description", condition())
    }
}
