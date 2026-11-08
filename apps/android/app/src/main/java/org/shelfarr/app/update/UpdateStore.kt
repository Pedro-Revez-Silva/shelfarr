package org.shelfarr.app.update

import android.util.Log
import java.io.File
import java.io.IOException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** The little the updater keeps across launches. Everything in it is re-checked before use. */
@Serializable
data class SavedUpdate(
    @SerialName("last_checked_at") val lastCheckedAtMs: Long? = null,
    @SerialName("last_attempt_at") val lastAttemptAtMs: Long? = null,
    /** The announced release, in feed form, so it is parsed with the same rules again. */
    @SerialName("release") val release: String? = null,
    /** File name of the verified APK inside the updater's directory. */
    @SerialName("artifact") val artifact: String? = null,
    /** The PackageInstaller session committed for [release], if one may still be open. */
    @SerialName("session_id") val sessionId: Int? = null,
)

/** One small JSON file, replaced atomically. Unreadable state is treated as none. */
class UpdateStore(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true }

    @Synchronized
    fun read(): SavedUpdate {
        if (!file.exists() || file.length() > MAX_BYTES) return SavedUpdate()
        return try {
            json.decodeFromString(SavedUpdate.serializer(), file.readText())
        } catch (error: SerializationException) {
            Log.w(TAG, "Discarding unreadable updater state", error)
            SavedUpdate()
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "Discarding unreadable updater state", error)
            SavedUpdate()
        } catch (error: IOException) {
            Log.w(TAG, "Could not read updater state", error)
            SavedUpdate()
        }
    }

    @Synchronized
    fun write(state: SavedUpdate) {
        try {
            file.parentFile?.mkdirs()
            val temporary = File(file.path + ".tmp")
            temporary.writeText(json.encodeToString(SavedUpdate.serializer(), state))
            if (!temporary.renameTo(file)) throw IOException("Could not replace ${file.name}")
        } catch (error: IOException) {
            // Losing this only means checking or downloading again.
            Log.w(TAG, "Could not save updater state", error)
        }
    }

    @Synchronized
    fun update(change: (SavedUpdate) -> SavedUpdate): SavedUpdate = change(read()).also(::write)

    private companion object {
        const val TAG = "ShelfarrUpdater"
        const val MAX_BYTES = 32L * 1024
    }
}
