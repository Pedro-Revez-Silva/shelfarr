package org.shelfarr.app.core

import android.content.Context
import java.io.File

/**
 * Where this app keeps what it knows, in one place. An app update keeps the package's
 * private storage only because every later version looks in exactly the same places:
 * renaming any directory, file, preference key or Keystore alias here would make an
 * updated app look signed out, forget downloads or settings, or orphan saved places.
 * `StorageLayoutTest` pins each value; change one only together with a migration.
 */
object StorageLayout {
    /** Display preferences (appearance, reader settings, update choices). No credential belongs here. */
    const val PREFERENCES = "preferences"
    const val KEY_APPEARANCE = "appearance"
    const val KEY_ASKED_NOTIFICATIONS = "asked_notifications"
    const val KEY_READER_SETTINGS = "reader_settings"
    const val KEY_AUTO_DOWNLOAD_UPDATES = "auto_download_updates"

    /** Encrypted session and pending sign-in, under `noBackupFilesDir`. */
    const val SECURE_DIRECTORY = "secure"

    /** The non-exportable Android Keystore key that encrypts [SECURE_DIRECTORY]. */
    const val KEYSTORE_ALIAS = "shelfarr.session.v1"

    /** Updater state and verified APKs, under `noBackupFilesDir`. */
    const val UPDATES_DIRECTORY = "updates"

    /** Per-account files, under `filesDir`, keyed by [accountKey]. */
    const val ACCOUNTS_DIRECTORY = "accounts"
    const val PROGRESS_FILE = "progress.json"
    const val DOWNLOADS_DIRECTORY = "downloads"
    const val LIBRARY_FILE = "library.json"

    /** Disposable copies under `cacheDir`; Android may clear them at any time. */
    const val EPUB_CACHE_DIRECTORY = "epub"
    const val COVER_CACHE_DIRECTORY = "covers"

    fun secureDirectory(context: Context): File = File(context.noBackupFilesDir, SECURE_DIRECTORY)

    fun updatesDirectory(context: Context): File = File(context.noBackupFilesDir, UPDATES_DIRECTORY)

    fun accountDirectory(context: Context, accountKey: String): File =
        File(context.filesDir, "$ACCOUNTS_DIRECTORY/$accountKey")
}
