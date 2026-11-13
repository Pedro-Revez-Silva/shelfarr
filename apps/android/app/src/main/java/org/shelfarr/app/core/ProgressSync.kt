package org.shelfarr.app.core

import java.io.IOException
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

    /** The devices can't be ordered by time. Nothing more is sent until the reader chooses. */
    data class Conflict(val local: SavedPosition?, val server: Progress) : SyncStatus

    data object NeedsSignIn : SyncStatus

    /** The server refused this position, e.g. the asset was replaced. It is still kept on this device. */
    data object Rejected : SyncStatus

    /** This device could not write its place. It is held in memory and still sent to the server. */
    data object StorageFailed : SyncStatus
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
 * Every position lands on disk first, with the time it was reached. Sends are
 * debounced, serial and idempotent: a write keeps its body, activity time and
 * mutation id until the server has given a definite answer, while newer positions
 * wait behind it. A definite conflict is settled by activity time when both sides
 * have a trustworthy one; otherwise the reader chooses.
 *
 * Nothing here moves a live reader or player. Adopting another device's later place
 * only changes the saved record, which the next open resumes from.
 */
class ProgressSync(
    val publicationId: String,
    private val store: ProgressStore,
    private val remote: ProgressRemote,
    private val scope: CoroutineScope,
    /** Wall-clock milliseconds: debouncing, explicit choices and plausibility checks. */
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
    private var storageFailed = false

    /** The last place the open session reported or started from; repeating it is not new activity. */
    private var reported: SavedPosition? = null

    private val mutableStatus = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val status: StateFlow<SyncStatus> = mutableStatus.asStateFlow()

    private suspend fun current(): LocalProgress {
        record?.let { return it }
        val loaded = try {
            store.get(publicationId)
        } catch (_: IOException) {
            storageFailed = true
            null
        }
        return (loaded ?: LocalProgress(publicationId)).also {
            record = it
            it.conflict?.let { server -> publish(SyncStatus.Conflict(it.position, server)) }
            if (storageFailed) publish(SyncStatus.StorageFailed)
        }
    }

    suspend fun snapshot(): LocalProgress = state.withLock { current() }

    /**
     * Anchors this session after a [ResumeDecision], before the first [update]. Restoring
     * a place is not activity: it keeps the time the place was reached, [observedAtEpochMs].
     */
    suspend fun begin(
        position: SavedPosition?,
        baseVersion: Int,
        observedAtEpochMs: Long? = null,
        assets: Collection<String>? = null,
    ) = state.withLock {
        val existing = current()
        reported = position
        val assetIds = assets?.toList() ?: existing.assetIds
        val samePlace = existing.position == position
        val base = if (samePlace) maxOf(existing.baseVersion, baseVersion) else baseVersion
        // A pending write is only still valid if it was built on this same version.
        val pending = existing.pending?.takeIf { it.expectedVersion == base }
        // A dropped write that held this place still has to reach the server, rebased.
        val dirty = samePlace && (existing.dirty || (existing.pending != null && pending == null))
        val updated = existing.copy(
            position = position,
            baseVersion = base,
            dirty = dirty,
            pending = pending,
            conflict = null,
            observedAtEpochMs = if (samePlace) existing.observedAtEpochMs ?: observedAtEpochMs else observedAtEpochMs,
            assetIds = assetIds,
            rejected = false,
        )
        if (updated != existing) save(updated)
        publish(if (updated.hasUnsyncedChanges) SyncStatus.Pending else SyncStatus.Idle)
        if (updated.hasUnsyncedChanges) schedule(0)
    }

    /**
     * Records a place the reader or listener actually reached at [observedAtEpochMs], the
     * wall-clock time captured when it happened (before any waiting). Cheap enough to call
     * on every page turn or checkpoint.
     */
    suspend fun update(position: SavedPosition, observedAtEpochMs: Long, send: Boolean = true) = state.withLock {
        val existing = current()
        if (position == reported || existing.position == position) {
            reported = position
            return@withLock
        }
        reported = position
        save(
            existing.copy(
                position = position,
                dirty = true,
                updatedAtEpochMs = now(),
                observedAtEpochMs = ActivityTime.next(observedAtEpochMs, existing.observedAtEpochMs),
            ),
        )
        if (existing.conflict != null || existing.rejected) return@withLock

        publish(SyncStatus.Pending)
        if (dirtySinceMs == null) dirtySinceMs = now()
        if (send) scheduleDebounced()
    }

    /**
     * Schedules sending what [update] saved with `send = false`. Paired places (an ebook and
     * its audiobook heard together) are both on disk before either is sent.
     */
    suspend fun requestSend() = state.withLock {
        val existing = current()
        if (!existing.hasUnsyncedChanges || existing.conflict != null || existing.rejected) return@withLock
        scheduleDebounced()
    }

    /**
     * The activity time [update] would record for [observedAtEpochMs] (see [ActivityTime.next]),
     * so places observed together can be written with one identical time.
     */
    suspend fun observationTime(observedAtEpochMs: Long): Long = state.withLock {
        ActivityTime.next(observedAtEpochMs, current().observedAtEpochMs)
    }

    /**
     * Names the assets this publication's places may refer to, without anchoring a session.
     * A paired audiobook written from read-along needs it to tell a mappable conflict.
     */
    suspend fun knowAssets(assets: Collection<String>) = state.withLock {
        val existing = current()
        val ids = (existing.assetIds.orEmpty() + assets).distinct()
        if (existing.assetIds == ids) return@withLock
        save(existing.copy(assetIds = ids))
    }

    private fun scheduleDebounced() {
        val started = dirtySinceMs ?: now().also { dirtySinceMs = it }
        val remaining = timing.maxWaitMs - (now() - started)
        schedule(minOf(timing.debounceMs, remaining).coerceAtLeast(0))
    }

    /** Sends everything outstanding now. Call on pause, stop and background. */
    suspend fun flush() {
        state.withLock { timer?.cancel(); timer = null }
        sending.withLock { send() }
    }

    /**
     * Keeps this device's place over the other device's. This is a new, explicit choice:
     * it gets its own activity time and the resolve flag, on disk before it is sent.
     */
    suspend fun keepLocal() {
        val chosenAt = now()
        state.withLock {
            val existing = current()
            val server = existing.conflict ?: return@withLock
            val position = existing.position ?: return@withLock
            val choice = PendingMutation(position, server.version, newMutationId(), chosenAt, resolveConflict = true)
            save(
                existing.copy(
                    baseVersion = server.version,
                    conflict = null,
                    pending = choice,
                    dirty = false,
                    observedAtEpochMs = chosenAt,
                    rejected = false,
                ),
            )
            publish(SyncStatus.Pending)
        }
        flush()
    }

    /** Adopts the other device's place and forgets the unsent local one. */
    suspend fun useServer(): SavedPosition? = state.withLock {
        val existing = current()
        val server = existing.conflict ?: return@withLock null
        val position = SavedPosition.from(server)
        reported = position
        save(adopted(existing, server))
        publish(SyncStatus.Saved)
        position
    }

    /**
     * Resolves a choice raised before opening, when no write has conflicted yet. The choice
     * is on disk when this returns; keeping this device's place is sent in the background.
     */
    suspend fun chooseAtOpen(position: SavedPosition, server: Progress, keepLocal: Boolean) {
        val chosenAt = now()
        state.withLock {
            val existing = current()
            reported = position
            val updated = if (keepLocal) {
                existing.copy(
                    position = position,
                    baseVersion = server.version,
                    dirty = false,
                    pending = PendingMutation(position, server.version, newMutationId(), chosenAt, resolveConflict = true),
                    conflict = null,
                    observedAtEpochMs = chosenAt,
                    rejected = false,
                )
            } else {
                adopted(existing, server)
            }
            save(updated)
            if (keepLocal) {
                publish(SyncStatus.Pending)
                schedule(0)
            } else {
                publish(SyncStatus.Saved)
            }
        }
    }

    private fun adopted(existing: LocalProgress, server: Progress) = existing.copy(
        position = SavedPosition.from(server),
        baseVersion = server.version,
        conflict = null,
        pending = null,
        dirty = false,
        observedAtEpochMs = server.observedAtEpochMs,
        rejected = false,
    )

    private suspend fun send() {
        var rebases = 0
        while (true) {
            // Never between the halves of a paired observation (see [together]).
            val mutation = observation.withLock { state.withLock {
                val existing = current()
                if (existing.conflict != null || existing.rejected) return
                val queued = existing.pending
                if (queued != null) return@withLock queued
                val position = existing.position
                if (!existing.dirty || position == null) {
                    publish(if (existing.updatedAtEpochMs > 0) SyncStatus.Saved else SyncStatus.Idle)
                    dirtySinceMs = null
                    return
                }
                val created = PendingMutation(position, existing.baseVersion, newMutationId(), existing.observedAtEpochMs)
                save(existing.copy(pending = created, dirty = false))
                created
            } }

            try {
                accept(mutation, remote.save(publicationId, mutation.toUpdate()))
            } catch (error: ApiException.ProgressConflict) {
                val server = error.current
                // Our own earlier attempt landed and only the response was lost.
                if (server != null && server.clientMutationId == mutation.mutationId) {
                    accept(mutation, server)
                    continue
                }
                if (!reconcile(mutation, server)) return
                if (++rebases > MAX_REBASES) {
                    waitAndRetry()
                    return
                }
            } catch (error: ApiException) {
                when {
                    error is ApiException.Unauthorized -> publish(SyncStatus.NeedsSignIn)
                    // An unreadable answer (a captive portal, a proxy) may or may not have landed: retry it as it is.
                    error.isRetryable || error is ApiException.Protocol || error is ApiException.RedirectBlocked -> waitAndRetry()
                    else -> reject(mutation)
                }
                return
            }
        }
    }

    /**
     * Settles a definite conflict. Returns true when there is something new to send.
     *
     * The newest local observation, including places queued behind [mutation], is
     * compared with the server's canonical checkpoint. The later real activity wins
     * wherever it is in the book. Equal, unknown or implausible times, and places this
     * edition can't map, are left to the reader.
     */
    private suspend fun reconcile(mutation: PendingMutation, server: Progress?): Boolean = state.withLock {
        val existing = current()
        // Something else (a new session, a choice) replaced this write meanwhile.
        if (existing.pending?.mutationId != mutation.mutationId) return@withLock true
        val local = existing.position ?: mutation.position
        val serverVersion = server?.version ?: 0
        when {
            // Nothing usable to compare with: this device holds the only place.
            server == null || !server.isUsable -> {
                rebase(existing, local, serverVersion)
                true
            }
            local.samePlaceAs(server) -> {
                val clock = now()
                val mine = existing.observedAtEpochMs?.takeIf { ActivityTime.isPlausible(it, clock) }
                val theirs = server.observedAtEpochMs?.takeIf { ActivityTime.isPlausible(it, clock) }
                // Reaching the same place later still matters: another offline device
                // may hold a different place reached between these two observations.
                if (mine != null && theirs != null && mine > theirs) {
                    rebase(existing, local, serverVersion)
                } else if (theirs != null && (mine == null || theirs >= mine)) {
                    save(adopted(existing, server))
                } else {
                    save(existing.copy(baseVersion = serverVersion, pending = null, dirty = false))
                }
                true
            }
            else -> {
                val clock = now()
                val mappable = existing.assetIds?.contains(server.assetId) ?: (server.assetId == local.assetId)
                val serverTime = server.observedAtEpochMs?.takeIf { ActivityTime.isPlausible(it, clock) }
                val localTime = existing.observedAtEpochMs?.takeIf { ActivityTime.isPlausible(it, clock) }
                when {
                    !mappable || serverTime == null || localTime == null || serverTime == localTime -> {
                        save(existing.copy(conflict = server, pending = null, dirty = true))
                        publish(SyncStatus.Conflict(local, server))
                        false
                    }
                    localTime > serverTime -> {
                        rebase(existing, local, serverVersion)
                        true
                    }
                    else -> {
                        // The other device was used later. Its place becomes the saved one.
                        save(adopted(existing, server))
                        publish(SyncStatus.Saved)
                        false
                    }
                }
            }
        }
    }

    /** Resends the newest local place on top of [version]: a new id, the original activity time. */
    private suspend fun rebase(existing: LocalProgress, local: SavedPosition, version: Int) {
        val rebased = PendingMutation(local, version, newMutationId(), existing.observedAtEpochMs)
        save(existing.copy(baseVersion = version, pending = rebased, dirty = false))
    }

    private suspend fun accept(mutation: PendingMutation, saved: Progress) = state.withLock {
        val existing = current()
        retries = 0
        // An answer to a write a newer session already replaced changes nothing.
        if (existing.pending?.mutationId != mutation.mutationId) return@withLock
        save(existing.copy(baseVersion = saved.version, pending = null, updatedAtEpochMs = maxOf(existing.updatedAtEpochMs, 1)))
    }

    private suspend fun reject(mutation: PendingMutation) = state.withLock {
        val existing = current()
        if (existing.pending?.mutationId != mutation.mutationId) return@withLock
        // Keep the place: it is still where this device was, and still unsynced.
        save(existing.copy(pending = null, dirty = true, rejected = true))
        publish(SyncStatus.Rejected)
    }

    private suspend fun waitAndRetry() = state.withLock {
        publish(SyncStatus.WaitingForServer)
        if (retries >= timing.maxRetries) return@withLock
        val delayMs = minOf(timing.maxRetryMs, timing.firstRetryMs shl minOf(retries, 16))
        retries++
        schedule(delayMs)
    }

    /** Writes locally. A failed write keeps the record in memory and is surfaced, never thrown. */
    private suspend fun save(updated: LocalProgress) {
        record = updated
        try {
            store.put(updated)
            storageFailed = false
        } catch (_: IOException) {
            storageFailed = true
            publish(mutableStatus.value)
        }
    }

    private fun publish(status: SyncStatus) {
        mutableStatus.value = if (storageFailed && status !is SyncStatus.Conflict) SyncStatus.StorageFailed else status
    }

    private fun schedule(delayMs: Long) {
        timer?.cancel()
        timer = scope.launch {
            delay(delayMs)
            sending.withLock { send() }
        }
    }

    companion object {
        /** Rebases in one send before backing off, in case another device keeps writing. */
        private const val MAX_REBASES = 4

        private val observation = Mutex()

        /**
         * Runs [block] as one observation across publications: no sync starts a new send
         * until it returns, so places heard together (an ebook and its paired audiobook)
         * are all on this device before any of them is sent. Never call [flush] inside it.
         */
        suspend fun <T> together(block: suspend () -> T): T = observation.withLock { block() }
    }
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

    /** Retries whatever earlier sessions could not deliver. A store that can't be read retries nothing. */
    suspend fun flushAll() {
        val outstanding = try {
            store.unsynced()
        } catch (_: IOException) {
            emptyList()
        }
        outstanding.forEach { sync(it.publicationId).flush() }
    }
}
