package org.shelfarr.app.core

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.shelfarr.app.reader.ReaderFont
import org.shelfarr.app.reader.ReaderSettings
import org.shelfarr.app.reader.ReaderSettingsStore
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.ui.theme.AppearanceMode

/**
 * An app update keeps the package's storage, but only helps if the new version reads
 * the same places in the same way. These pin every name and derivation earlier
 * versions wrote with, and reload data through fresh objects as a new process does.
 *
 * This is a simulation in one JVM: Robolectric has no Android Keystore or package
 * update. `UpgradePreservationTest` with `apps/android/tools/upgrade-preservation.sh`
 * checks the same data across a real package update on an emulator.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class StorageLayoutTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun address(value: String) = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address

    @Test
    fun `names written by earlier versions never change`() {
        assertEquals("preferences", StorageLayout.PREFERENCES)
        assertEquals("appearance", StorageLayout.KEY_APPEARANCE)
        assertEquals("asked_notifications", StorageLayout.KEY_ASKED_NOTIFICATIONS)
        assertEquals("reader_settings", StorageLayout.KEY_READER_SETTINGS)
        assertEquals("auto_download_updates", StorageLayout.KEY_AUTO_DOWNLOAD_UPDATES)
        assertEquals("shelfarr.session.v1", StorageLayout.KEYSTORE_ALIAS)
        assertEquals(File(context.noBackupFilesDir, "secure"), StorageLayout.secureDirectory(context))
        assertEquals(File(context.noBackupFilesDir, "updates"), StorageLayout.updatesDirectory(context))
        assertEquals(File(context.filesDir, "accounts/abc"), StorageLayout.accountDirectory(context, "abc"))
        assertEquals("progress.json", StorageLayout.PROGRESS_FILE)
        assertEquals("downloads", StorageLayout.DOWNLOADS_DIRECTORY)
        assertEquals("library.json", StorageLayout.LIBRARY_FILE)
        assertEquals("epub", StorageLayout.EPUB_CACHE_DIRECTORY)
        assertEquals("covers", StorageLayout.COVER_CACHE_DIRECTORY)
    }

    @Test
    fun `an account keeps its key, however its address was typed`() {
        // Values computed by earlier versions; a different key would orphan every download and place.
        assertEquals("158b71b211d36bb673e69100ce8f12c4", accountKey(address("https://books.example.org/shelfarr"), "42"))
        assertEquals("158b71b211d36bb673e69100ce8f12c4", accountKey(address("books.example.org/shelfarr/"), "42"))
        assertEquals("c1d48c1304c74eafe7aa6cdfafc5846f", accountKey(address("HTTPS://Books.Example.org"), "ada"))
    }

    @Test
    fun `appearance is stored by position, so the order is fixed`() {
        assertEquals(listOf("SYSTEM", "LIGHT", "DARK"), AppearanceMode.entries.map { it.name })
    }

    @Test
    fun `reader settings saved by an earlier version read back the same`() {
        val preferences = context.getSharedPreferences(StorageLayout.PREFERENCES, Context.MODE_PRIVATE)
        preferences.edit().putString(
            StorageLayout.KEY_READER_SETTINGS,
            """{"theme":"NIGHT","font":"ORIGINAL","fontSize":1.4,"lineHeight":1.7,"margins":1.2,"justify":true,"scroll":true}""",
        ).commit()
        val restored = ReaderSettingsStore(context.getSharedPreferences(StorageLayout.PREFERENCES, Context.MODE_PRIVATE)).settings.value
        assertEquals(ReaderSettings(ReaderTheme.NIGHT, ReaderFont.ORIGINAL, 1.4, 1.7, 1.2, justify = true, scroll = true), restored)
    }

    @Test
    fun `a session, a queued place and preferences reload in a fresh process`() = runBlocking {
        // A file-backed stand-in for the Keystore store: same file, new objects.
        val secure = File(context.noBackupFilesDir, "simulated-secure").apply { mkdirs() }
        class FileStore : SecureStore {
            override fun read(name: String) = File(secure, name).takeIf(File::isFile)?.readText()
            override fun write(name: String, value: String) = File(secure, name).writeText(value)
            override fun delete(name: String) {
                File(secure, name).delete()
            }
        }
        val server = address("https://books.example.org/shelfarr")
        val session = Session(server, Me("42", "Ada"), "token-1")
        SessionManager(FileStore()).signIn(session)

        val directory = StorageLayout.accountDirectory(context, session.accountKey)
        val place = SavedPosition("epub-1", buildJsonObject { put("href", JsonPrimitive("chapter-2.xhtml")) })
        FileProgressStore(File(directory, StorageLayout.PROGRESS_FILE)).apply {
            put(LocalProgress("book", position = place, dirty = true, updatedAtEpochMs = 5))
            close()
        }
        context.getSharedPreferences(StorageLayout.PREFERENCES, Context.MODE_PRIVATE).edit()
            .putInt(StorageLayout.KEY_APPEARANCE, AppearanceMode.DARK.ordinal)
            .putBoolean(StorageLayout.KEY_AUTO_DOWNLOAD_UPDATES, true)
            .commit()

        // "After the update": nothing in memory, the same files.
        val reloaded = SessionManager(FileStore()).signedIn
        assertEquals(session, reloaded)
        assertEquals(directory, StorageLayout.accountDirectory(context, reloaded!!.accountKey))
        val queued = FileProgressStore(File(directory, StorageLayout.PROGRESS_FILE)).unsynced()
        assertEquals(listOf(place), queued.map { it.position })
        val preferences = context.getSharedPreferences(StorageLayout.PREFERENCES, Context.MODE_PRIVATE)
        assertEquals(AppearanceMode.DARK, AppearanceMode.entries[preferences.getInt(StorageLayout.KEY_APPEARANCE, 0)])
        assertTrue(preferences.getBoolean(StorageLayout.KEY_AUTO_DOWNLOAD_UPDATES, false))
    }
}
