package org.shelfarr.app.core

import java.io.IOException

/** 2026-11-07T09:00:00Z: tests add virtual time to a realistic wall clock. */
const val TEST_EPOCH = 1_794_042_000_000L

class MemoryStore : ProgressStore {
    val records = HashMap<String, LocalProgress>()

    /** While true, writes fail like a full or read-only disk. */
    var failWrites = false

    override suspend fun get(publicationId: String) = records[publicationId]

    override suspend fun put(record: LocalProgress) {
        if (failWrites) throw IOException("No space left on device")
        records[record.publicationId] = record
    }

    override suspend fun unsynced() = records.values.sendable()
}

/**
 * An in-memory server following docs/consumer-api.md's progress rules, so client tests
 * exercise the real contract rather than a stub that accepts everything.
 */
class ContractServer(
    private val now: () -> Long,
    private val assets: Set<String> = setOf("a", "b"),
) {
    var stored: Progress? = null

    /** False behaves like a server from before activity times: the fields are ignored. */
    var knowsActivityTime = true

    val received = mutableListOf<ProgressUpdate>()

    /** Thrown before the write is applied: the request never arrived. */
    val failBefore = ArrayDeque<ApiException>()

    /** The write is applied, then the response is lost on the way back. */
    var loseResponses = 0

    fun remote(): ProgressRemote = ProgressRemote { _, update -> save(update) }

    fun save(update: ProgressUpdate): Progress {
        received += update
        failBefore.removeFirstOrNull()?.let { throw it }
        val saved = apply(update)
        if (loseResponses > 0) {
            loseResponses--
            throw ApiException.Offline()
        }
        return saved
    }

    private fun apply(update: ProgressUpdate): Progress {
        if (update.assetId !in assets) throw ApiException.Rejected("invalid")
        val observed = if (knowsActivityTime) {
            update.observedAt?.let { ActivityTime.parse(it) ?: throw ApiException.Rejected("invalid") }
        } else {
            null
        }
        if (observed != null && observed > now() + ActivityTime.FUTURE_TOLERANCE_MS) throw ApiException.Rejected("invalid")
        val resolve = knowsActivityTime && update.resolveConflict == true

        val current = stored
        if (current != null && current.clientMutationId == update.clientMutationId) {
            if (samePlace(current, update) && current.observedAtEpochMs == observed) return current
            throw ApiException.ProgressConflict(current)
        }
        if ((current?.version ?: 0) != update.expectedVersion) throw ApiException.ProgressConflict(current)
        if (current != null && !resolve) {
            val storedTime = current.observedAtEpochMs
            if (storedTime != null && observed != null) {
                if (observed < storedTime) throw ApiException.ProgressConflict(current)
                if (observed == storedTime && !samePlace(current, update)) throw ApiException.ProgressConflict(current)
            }
        }
        return Progress(
            assetId = update.assetId,
            locator = update.locator,
            positionSeconds = update.positionSeconds,
            version = (current?.version ?: 0) + 1,
            updatedAt = ActivityTime.format(now()),
            clientMutationId = update.clientMutationId,
            observedAt = observed?.let(ActivityTime::format),
        ).also { stored = it }
    }

    private fun samePlace(progress: Progress, update: ProgressUpdate) =
        progress.assetId == update.assetId && progress.locator == update.locator && progress.positionSeconds == update.positionSeconds
}
