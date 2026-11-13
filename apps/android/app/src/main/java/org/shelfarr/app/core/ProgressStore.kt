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
    fun samePlaceAs(progress: Progress): Boolean =
        assetId == progress.assetId && locator == progress.locator && positionSeconds == progress.positionSeconds

    companion object {
        fun from(progress: Progress): SavedPosition =
            SavedPosition(progress.assetId, progress.locator, progress.positionSeconds)
    }
}

/**
 * A progress write that may already have reached the server. It is immutable once
 * created: a retry must repeat the same body, activity time, flag and mutation id.
 */
@Serializable
data class PendingMutation(
    val position: SavedPosition,
    val expectedVersion: Int,
    val mutationId: String,
    /** When [position] was observed, epoch ms. Null for writes queued before activity times existed. */
    val observedAtEpochMs: Long? = null,
    /** An explicit "Keep this device" choice. Automatic rebasing never sets it. */
    val resolveConflict: Boolean = false,
) {
    fun toUpdate(): ProgressUpdate = ProgressUpdate(
        assetId = position.assetId,
        locator = position.locator,
        positionSeconds = position.positionSeconds,
        expectedVersion = expectedVersion,
        clientMutationId = mutationId,
        observedAt = observedAtEpochMs?.let(ActivityTime::format),
        resolveConflict = true.takeIf { resolveConflict },
    )
}

/**
 * This device's knowledge of one publication's position.
 *
 * Records written before activity times existed decode with [observedAtEpochMs]
 * null: unknown, so they keep the explicit-choice flow rather than borrowing a time.
 */
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
    /** When [position] was reached, here or on the device it was adopted from. Null when unknown. */
    val observedAtEpochMs: Long? = null,
    /** The assets this edition's positions may name, so a background sync can tell an unmappable place. */
    val assetIds: List<String>? = null,
    /**
     * The server refused this place (for example a replaced file or a wrong clock). It is
     * kept here, still unsynced, but not resent until the publication is opened again.
     */
    val rejected: Boolean = false,
) {
    val hasUnsyncedChanges: Boolean get() = dirty || pending != null
}

interface ProgressStore {
    suspend fun get(publicationId: String): LocalProgress?

    /** Throws [IOException] when the place could not be written. */
    suspend fun put(record: LocalProgress)
    suspend fun unsynced(): List<LocalProgress>
}

/** Records that background syncing should send now. */
internal fun Collection<LocalProgress>.sendable(): List<LocalProgress> =
    filter { it.hasUnsyncedChanges && it.conflict == null && !it.rejected }

/** One small JSON file per account, replaced atomically on each write. */
class FileProgressStore(private val file: File) : ProgressStore {
    private val mutex = Mutex()
    private var records: MutableMap<String, LocalProgress>? = null
    private var closed = false

    /** Stops all further writes, so nothing can recreate the file after a wipe. */
    suspend fun close() = mutex.withLock { closed = true }

    override suspend fun get(publicationId: String): LocalProgress? = mutex.withLock { loaded()[publicationId] }

    override suspend fun put(record: LocalProgress): Unit = mutex.withLock {
        if (closed) return@withLock
        val all = loaded()
        all[record.publicationId] = record
        withContext(Dispatchers.IO) {
            file.parentFile?.mkdirs()
            val temporary = File(file.path + ".tmp")
            temporary.writeText(ApiJson.encodeToString<Map<String, LocalProgress>>(all))
            if (!temporary.renameTo(file)) throw IOException("Could not save progress")
        }
    }

    override suspend fun unsynced(): List<LocalProgress> = mutex.withLock { loaded().values.sendable() }

    /** Reading failures throw and leave nothing cached, so a later write can't replace unread records. */
    private suspend fun loaded(): MutableMap<String, LocalProgress> {
        records?.let { return it }
        val parsed = withContext(Dispatchers.IO) {
            if (!file.exists()) return@withContext null
            val text = file.readText()
            try {
                ApiJson.decodeFromString<Map<String, LocalProgress>>(text)
            } catch (_: SerializationException) {
                setAside()
                null
            } catch (_: IllegalArgumentException) {
                setAside()
                null
            }
        }
        return (parsed?.toMutableMap() ?: mutableMapOf()).also { records = it }
    }

    /** Keeps an unreadable file for diagnosis instead of overwriting it on the next save. */
    private fun setAside() {
        file.renameTo(File(file.path + ".damaged"))
    }
}
