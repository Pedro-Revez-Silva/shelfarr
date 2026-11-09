package org.shelfarr.app.upgrade

import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContinueList
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.reader.ReaderFont
import org.shelfarr.app.reader.ReaderSettings
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.ui.theme.AppearanceMode

/**
 * The seed half of the upgrade check. It is NOT part of the current app's test sources:
 * `apps/android/tools/upgrade-preservation.sh` copies it into the published baseline's
 * source tree and builds it there, so it calls the old app with exactly the old app's
 * method signatures. Code compiled against the current app breaks as soon as a model
 * gains a field (its constructor and default-argument signatures change), which is why
 * the seed must never run from the current test APK.
 *
 * Keep it to APIs the baseline (`1b99abe`, published v3) has. The record it leaves is
 * plain JSON read by `UpgradePreservationTest.verify` in the updated app.
 */
@RunWith(AndroidJUnit4::class)
class UpgradeSeedTest {
    private val app = ApplicationProvider.getApplicationContext<ShelfarrApplication>()
    private val container get() = app.container

    private val epub = byteArrayOf('P'.code.toByte(), 'K'.code.toByte()) + ByteArray(48_000) { (it % 251).toByte() }
    private val book = Publication(
        id = "upgrade-book", title = "Kept across updates", author = "Fixture Author", bookType = BookType.EBOOK,
        assets = listOf(Asset("upgrade-epub", "kept.epub", "application/epub+zip", "epub", epub.size.toLong(), "/files/kept-epub")),
    )
    private val place = SavedPosition("upgrade-epub", buildJsonObject { put("href", JsonPrimitive("chapter-3.xhtml")) })

    @Test
    fun seed() {
        // No skip condition: the harness requires this to pass, and only the harness builds it.
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
        container.readerSettings.update {
            ReaderSettings(theme = ReaderTheme.entries.last(), font = ReaderFont.entries.last(), fontSize = 1.4, justify = true)
        }
        // The baseline predates this setting's accessor; write the preference the newer app reads.
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
        val record = JSONObject()
            .put("accountKey", session.accountKey)
            .put("server", server.display)
            .put("userId", session.user.id)
            .put("token", session.accessToken)
            .put("fileSha256", sha256(file))
            .put("fileName", file.relativeTo(app.filesDir).path)
            .put("versionCode", versionCode)
            .put("firstInstallTime", info.firstInstallTime)
            .put("lastUpdateTime", info.lastUpdateTime)
        File(app.filesDir, "upgrade-preservation-seed.json").writeText(record.toString())
        // Let asynchronous preference writes reach disk before the package is replaced.
        SystemClock.sleep(1_000)
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
