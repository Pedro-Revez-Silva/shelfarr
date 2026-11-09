package org.shelfarr.app.upgrade

import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.KeystoreSecureStore
import org.shelfarr.app.core.Me
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
 * `apps/android/tools/upgrade-preservation.sh` installs the published baseline build
 * with a test APK built from the baseline's own sources plus
 * `apps/android/tools/upgrade-seed/UpgradeSeedTest.kt`, and runs that seed in the old
 * app. The seed is compiled against the old app on purpose: this file's code runs only
 * in the new app, so new model fields can never break the seed with a missing
 * constructor. The script then updates the package in place with a newer build signed
 * with the same key through Android's PackageInstaller (`adb install -r`), installs this
 * test APK, and runs [verify] in the new version's fresh process (instrumentation
 * argument `shelfarrUpgradeStage=verify`). Without the argument, as in an ordinary
 * `connectedDebugAndroidTest`, [verify] is skipped and only
 * [aFreshStoreReadsTheSessionBack] runs, which proves Keystore reading across store
 * instances but not across an update.
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

    private val place = SavedPosition("upgrade-epub", buildJsonObject { put("href", JsonPrimitive("chapter-3.xhtml")) })
    private val reader = ReaderSettings(theme = ReaderTheme.entries.last(), font = ReaderFont.entries.last(), fontSize = 1.4, justify = true)

    /** Written by the baseline-compiled `UpgradeSeedTest` as plain JSON, so neither side shares model classes. */
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
    ) {
        companion object {
            fun from(json: JSONObject) = Seed(
                accountKey = json.getString("accountKey"),
                server = json.getString("server"),
                userId = json.getString("userId"),
                token = json.getString("token"),
                fileSha256 = json.getString("fileSha256"),
                fileName = json.getString("fileName"),
                versionCode = json.getLong("versionCode"),
                firstInstallTime = json.getLong("firstInstallTime"),
                lastUpdateTime = json.getLong("lastUpdateTime"),
            )
        }
    }

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
    fun verify() {
        assumeTrue("Only when run by upgrade-preservation.sh", stage == "verify")
        assertTrue("The seed stage's record survived", seedFile.isFile)
        val seed = Seed.from(JSONObject(seedFile.readText()))

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

    private fun sha256(file: File): String =
        MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
}
