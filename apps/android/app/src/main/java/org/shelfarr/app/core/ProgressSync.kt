package org.shelfarr.app.core

import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

sealed interface SyncStatus {
    data object Idle : SyncStatus
    data object Pending : SyncStatus
    data object Saved : SyncStatus

    /** Saved on this device; the server will get it once reachable. */
    data object WaitingForServer : SyncStatus

    /** Another device moved on. Nothing more is sent until the reader chooses. */
    data class Conflict(val local: SavedPosition?, val server: Progress) : SyncStatus

    data object NeedsSignIn : SyncStatus

    /** The server refused this position outright, e.g. the asset was replaced. */
    data object Rejected : SyncStatus
}

fun interface ProgressRemote {
    suspend fun save(publicationId: String, update: ProgressUpdate): Progress
}

data class SyncTiming(
    val debounceMs: Long = 5_000,
    val maxWaitMs: Long = 20_000,
    val firstRetryMs: Long = 5_000,
    val maxRetryMs: Long = 300_000,
    val maxRetries: Int = 8,
)

/**
 * Keeps one publication's position safe locally and in step with the server.
 *
 * Every position lands on disk first. Sends are debounced, serial and idempotent: a
 * write keeps its mutation id until the server has given a definite answer, while
 * newer positions wait behind it.
 */
class ProgressSync(
    val publicationId: String,
    private val store: ProgressStore,
    private val remote: ProgressRemote,
    private val scope: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
    private val timing: SyncTiming = SyncTiming(),
    private val newMutationId: () -> String = { UUID.randomUUID().toString() },
) {
    private val state = Mutex()
    private val sending = Mutex()
    private var record: LocalProgress? = null
    private var dirtySinceMs: Long? = null
    private var timer: Job? = null
    private var retries = 0

    private val mutableStatus = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val status: StateFlow<SyncStatus> = mutableStatus.asStateFlow()

    private suspend fun current(): LocalProgress =
        record ?: (store.get(publicationId) ?: LocalProgress(publicationId)).also {
            record = it
            it.conflict?.let { server -> mutableStatus.value = SyncStatus.Conflict(it.position, server) }
        }

    suspend fun snapshot(): LocalProgress = state.withLock { current() }

    /** Anchors this session after a [ResumeDecision], before the first [update]. */
    suspend fun begin(position: SavedPosition?, baseVersion: Int) = state.withLock {
        val existing = current()
        val unchanged = existing.position == position && existing.baseVersion == baseVersion
        if (unchanged) return@withLock
        // A pending write is only still valid if it was built on this same version.
        val pending = existing.pending?.takeIf { it.expectedVersion == baseVersion }
        save(
            existing.copy(
                position = position,
                baseVersion = baseVersion,
                dirty = existing.dirty && existing.position == position,
                pending = pending,
                conflict = null,
            ),
        )
        mutableStatus.value = SyncStatus.Idle
    }

    /** Records the latest place. Cheap enough to call on every page turn or tick. */
    suspend fun update(position: SavedPosition) = state.withLock {
        val existing = current()
        if (existing.position == position) return@withLock
        save(existing.copy(position = position, dirty = true, updatedAtEpochMs = now()))
        if (existing.conflict != null) return@withLock

        mutableStatus.value = SyncStatus.Pending
        val started = dirtySinceMs ?: now().also { dirtySinceMs = it }
        val remaining = timing.maxWaitMs - (now() - started)
        schedule(minOf(timing.debounceMs, remaining).coerceAtLeast(0))
    }

    /** Sends everything outstanding now. Call on pause, stop and background. */
    suspend fun flush() {
        state.withLock { timer?.cancel(); timer = null }
        sending.withLock { send() }
    }

    /** Keeps this device's place, replacing what the other device saved. */
    suspend fun keepLocal() {
        state.withLock {
            val existing = current()
            val server = existing.conflict ?: return@withLock
            save(existing.copy(baseVersion = server.version, conflict = null, pending = null, dirty = true))
            mutableStatus.value = SyncStatus.Pending
        }
        flush()
    }

    /** Adopts the other device's place and forgets the unsent local one. */
    suspend fun useServer(): SavedPosition? = state.withLock {
        val existing = current()
        val server = existing.conflict ?: return@withLock null
        val position = SavedPosition.from(server)
        save(
            existing.copy(
                position = position,
                baseVersion = server.version,
                conflict = null,
                pending = null,
                dirty = false,
            ),
        )
        mutableStatus.value = SyncStatus.Saved
        position
    }

    /** Resolves a choice raised before opening, when no write has conflicted yet. */
    suspend fun chooseAtOpen(position: SavedPosition, serverVersion: Int, keepLocal: Boolean) {
        state.withLock {
            val existing = current()
            save(
                existing.copy(
                    position = position,
                    baseVersion = serverVersion,
                    dirty = keepLocal,
                    pending = null,
                    conflict = null,
                ),
            )
        }
        if (keepLocal) flush()
    }

    private suspend fun send() {
        while (true) {
            val mutation = state.withLock {
                val existing = current()
                if (existing.conflict != null) return
                val queued = existing.pending
                if (queued != null) return@withLock queued
                val position = existing.position
                if (!existing.dirty || position == null) {
                    if (mutableStatus.value !is SyncStatus.Rejected) {
                        mutableStatus.value = if (existing.updatedAtEpochMs > 0) SyncStatus.Saved else SyncStatus.Idle
                    }
                    dirtySinceMs = null
                    return
                }
                val created = PendingMutation(position, existing.baseVersion, newMutationId())
                save(existing.copy(pending = created, dirty = false))
                created
            }

            try {
                accept(remote.save(publicationId, mutation.toUpdate()))
            } catch (error: ApiException.ProgressConflict) {
                val server = error.current
                when {
                    // Our own earlier attempt landed and only the response was lost.
                    server != null && server.clientMutationId == mutation.mutationId -> accept(server)
                    server != null -> {
                        raiseConflict(server)
                        return
                    }
                    else -> {
                        discard()
                        return
                    }
                }
            } catch (error: ApiException) {
                when {
                    error is ApiException.Unauthorized -> mutableStatus.value = SyncStatus.NeedsSignIn
                    error.isRetryable -> waitAndRetry()
                    else -> discard()
                }
                return
            }
        }
    }

    private suspend fun accept(saved: Progress) = state.withLock {
        val existing = current()
        retries = 0
        save(existing.copy(baseVersion = saved.version, pending = null, updatedAtEpochMs = maxOf(existing.updatedAtEpochMs, 1)))
    }

    private suspend fun raiseConflict(server: Progress) = state.withLock {
        val existing = current()
        save(existing.copy(conflict = server, pending = null, dirty = true))
        mutableStatus.value = SyncStatus.Conflict(existing.position, server)
    }

    private suspend fun discard() = state.withLock {
        save(current().copy(pending = null, dirty = false))
        mutableStatus.value = SyncStatus.Rejected
    }

    private suspend fun waitAndRetry() = state.withLock {
        mutableStatus.value = SyncStatus.WaitingForServer
        if (retries >= timing.maxRetries) return@withLock
        val delayMs = minOf(timing.maxRetryMs, timing.firstRetryMs shl minOf(retries, 16))
        retries++
        schedule(delayMs)
    }

    private suspend fun save(updated: LocalProgress) {
        record = updated
        store.put(updated)
    }

    private fun schedule(delayMs: Long) {
        timer?.cancel()
        timer = scope.launch {
            delay(delayMs)
            sending.withLock { send() }
        }
    }

    private fun PendingMutation.toUpdate() = ProgressUpdate(
        assetId = position.assetId,
        locator = position.locator,
        positionSeconds = position.positionSeconds,
        expectedVersion = expectedVersion,
        clientMutationId = mutationId,
    )
}

/** Live [ProgressSync] instances for one account. */
class ProgressRegistry(
    private val store: ProgressStore,
    private val remote: ProgressRemote,
    private val scope: CoroutineScope,
) {
    private val syncs = HashMap<String, ProgressSync>()

    @Synchronized
    fun sync(publicationId: String): ProgressSync =
        syncs.getOrPut(publicationId) { ProgressSync(publicationId, store, remote, scope) }

    /** Retries whatever earlier sessions could not deliver. */
    suspend fun flushAll() {
        store.unsynced().forEach { sync(it.publicationId).flush() }
    }
}
