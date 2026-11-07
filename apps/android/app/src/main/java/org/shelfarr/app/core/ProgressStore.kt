package org.shelfarr.app.core

import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject

/** A place in one specific asset: a Readium locator or a time within an audio file. */
@Serializable
data class SavedPosition(
    val assetId: String,
    val locator: JsonObject? = null,
    val positionSeconds: Double? = null,
) {
    companion object {
        fun from(progress: Progress): SavedPosition =
            SavedPosition(progress.assetId, progress.locator, progress.positionSeconds)
    }
}

/**
 * A progress write that may already have reached the server. It is immutable once
 * created: a retry must repeat the same body and mutation id.
 */
@Serializable
data class PendingMutation(
    val position: SavedPosition,
    val expectedVersion: Int,
    val mutationId: String,
)

/** This device's knowledge of one publication's position. */
@Serializable
data class LocalProgress(
    val publicationId: String,
    val position: SavedPosition? = null,
    /** The server version this position was built on. */
    val baseVersion: Int = 0,
    /** True when [position] holds something the server has not been sent yet. */
    val dirty: Boolean = false,
    val pending: PendingMutation? = null,
    val conflict: Progress? = null,
    val updatedAtEpochMs: Long = 0,
) {
    val hasUnsyncedChanges: Boolean get() = dirty || pending != null
}

interface ProgressStore {
    suspend fun get(publicationId: String): LocalProgress?
    suspend fun put(record: LocalProgress)
    suspend fun unsynced(): List<LocalProgress>
}

/** One small JSON file per account, replaced atomically on each write. */
class FileProgressStore(private val file: File) : ProgressStore {
    private val mutex = Mutex()
    private var records: MutableMap<String, LocalProgress>? = null

    override suspend fun get(publicationId: String): LocalProgress? = mutex.withLock { loaded()[publicationId] }

    override suspend fun put(record: LocalProgress) = mutex.withLock {
        val all = loaded()
        all[record.publicationId] = record
        withContext(Dispatchers.IO) {
            file.parentFile?.mkdirs()
            val temporary = File(file.path + ".tmp")
            temporary.writeText(ApiJson.encodeToString<Map<String, LocalProgress>>(all))
            if (!temporary.renameTo(file)) throw IOException("Could not save progress")
        }
    }

    override suspend fun unsynced(): List<LocalProgress> =
        mutex.withLock { loaded().values.filter { it.hasUnsyncedChanges && it.conflict == null } }

    private suspend fun loaded(): MutableMap<String, LocalProgress> {
        records?.let { return it }
        val parsed = withContext(Dispatchers.IO) {
            if (!file.exists()) return@withContext null
            try {
                ApiJson.decodeFromString<Map<String, LocalProgress>>(file.readText())
            } catch (_: SerializationException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
        }
        return (parsed?.toMutableMap() ?: mutableMapOf()).also { records = it }
    }
}
