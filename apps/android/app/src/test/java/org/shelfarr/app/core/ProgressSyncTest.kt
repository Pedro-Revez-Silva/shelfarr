package org.shelfarr.app.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class MemoryStore : ProgressStore {
    val records = HashMap<String, LocalProgress>()
    override suspend fun get(publicationId: String) = records[publicationId]
    override suspend fun put(record: LocalProgress) {
        records[record.publicationId] = record
    }
    override suspend fun unsynced() = records.values.filter { it.hasUnsyncedChanges && it.conflict == null }
}

private class FakeRemote : ProgressRemote {
    val calls = mutableListOf<ProgressUpdate>()
    var version = 0
    val failures = ArrayDeque<ApiException>()

    override suspend fun save(publicationId: String, update: ProgressUpdate): Progress {
        calls += update
        failures.removeFirstOrNull()?.let { throw it }
        version++
        return Progress(
            update.assetId,
            update.locator,
            update.positionSeconds,
            version,
            clientMutationId = update.clientMutationId,
        )
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ProgressSyncTest {
    private val store = MemoryStore()
    private val remote = FakeRemote()
    private var ids = 0

    private fun TestScope.sync(): ProgressSync =
        ProgressSync("p", store, remote, backgroundScope, now = { currentTime }, newMutationId = { "m${++ids}" })

    private fun at(seconds: Double) = SavedPosition("a", positionSeconds = seconds)

    @Test
    fun `saves locally at once and sends after the debounce`() = runTest {
        val sync = sync()
        sync.update(at(1.0))
        assertEquals(at(1.0), store.records["p"]?.position)
        assertEquals(0, remote.calls.size)

        advanceTimeBy(5_001)
        runCurrent()
        assertEquals(1, remote.calls.size)
        assertEquals(0, remote.calls.single().expectedVersion)
        assertEquals(SyncStatus.Saved, sync.status.value)
        assertEquals(1, store.records["p"]?.baseVersion)
    }

    @Test
    fun `constant movement is still sent within the maximum wait`() = runTest {
        val sync = sync()
        repeat(30) { tick ->
            sync.update(at(tick.toDouble()))
            advanceTimeBy(1_000)
            runCurrent()
        }
        assertTrue("sent ${remote.calls.size}", remote.calls.size in 1..3)
    }

    @Test
    fun `repeating the same place sends nothing`() = runTest {
        val sync = sync()
        sync.begin(at(4.0), 2)
        sync.update(at(4.0))
        advanceTimeBy(60_000)
        runCurrent()
        assertEquals(0, remote.calls.size)
    }

    @Test
    fun `flush sends immediately and uses the latest version`() = runTest {
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        sync.update(at(2.0))
        sync.flush()
        assertEquals(listOf(0, 1), remote.calls.map { it.expectedVersion })
        assertEquals(listOf("m1", "m2"), remote.calls.map { it.clientMutationId })
    }

    @Test
    fun `a failed send retries with the same mutation id and body`() = runTest {
        remote.failures += ApiException.Offline()
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        assertEquals(SyncStatus.WaitingForServer, sync.status.value)

        advanceTimeBy(5_001)
        runCurrent()
        assertEquals(2, remote.calls.size)
        assertEquals(remote.calls[0], remote.calls[1])
        assertEquals(SyncStatus.Saved, sync.status.value)
    }

    @Test
    fun `newer places wait behind an unanswered write, then go as a new mutation`() = runTest {
        remote.failures += ApiException.Server(503)
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        sync.update(at(2.0))
        sync.flush()

        assertEquals(listOf("m1", "m1", "m2"), remote.calls.map { it.clientMutationId })
        assertEquals(1.0, remote.calls[1].positionSeconds)
        assertEquals(2.0, remote.calls[2].positionSeconds)
        assertEquals(1, remote.calls[2].expectedVersion)
    }

    @Test
    fun `an unanswered write survives a restart with its id`() = runTest {
        remote.failures += ApiException.Offline()
        val first = sync()
        first.update(at(1.0))
        first.flush()

        val restored = sync()
        restored.flush()
        assertEquals(listOf("m1", "m1"), remote.calls.map { it.clientMutationId })
    }

    @Test
    fun `a conflict reporting our own mutation counts as saved`() = runTest {
        val echo = Progress("a", positionSeconds = 1.0, version = 8, clientMutationId = "m1")
        remote.failures += ApiException.ProgressConflict(echo)
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()

        assertEquals(SyncStatus.Saved, sync.status.value)
        assertEquals(8, store.records["p"]?.baseVersion)
        assertFalse(store.records["p"]!!.hasUnsyncedChanges)
    }

    @Test
    fun `a real conflict stops sending and asks`() = runTest {
        val theirs = Progress("a", positionSeconds = 90.0, version = 8, clientMutationId = "other")
        remote.failures += ApiException.ProgressConflict(theirs)
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()

        assertEquals(SyncStatus.Conflict(at(1.0), theirs), sync.status.value)
        sync.update(at(2.0))
        sync.flush()
        assertEquals(1, remote.calls.size)
        assertEquals(at(2.0), store.records["p"]?.position)
    }

    @Test
    fun `keeping this device writes on top of the newer version`() = runTest {
        remote.failures += ApiException.ProgressConflict(Progress("a", positionSeconds = 90.0, version = 8, clientMutationId = "o"))
        remote.version = 8
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        sync.keepLocal()

        assertEquals(8, remote.calls.last().expectedVersion)
        assertEquals("m2", remote.calls.last().clientMutationId)
        assertEquals(SyncStatus.Saved, sync.status.value)
    }

    @Test
    fun `using the other device adopts its place and sends nothing`() = runTest {
        remote.failures += ApiException.ProgressConflict(Progress("a", positionSeconds = 90.0, version = 8, clientMutationId = "o"))
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()

        assertEquals(at(90.0), sync.useServer())
        assertEquals(1, remote.calls.size)
        assertEquals(8, store.records["p"]?.baseVersion)
        assertFalse(store.records["p"]!!.hasUnsyncedChanges)
    }

    @Test
    fun `an invalid position is dropped rather than retried forever`() = runTest {
        remote.failures += ApiException.Rejected("invalid")
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(1, remote.calls.size)
        assertEquals(SyncStatus.Rejected, sync.status.value)
    }

    @Test
    fun `a lost session keeps the write for after sign-in`() = runTest {
        remote.failures += ApiException.Unauthorized()
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        assertEquals(SyncStatus.NeedsSignIn, sync.status.value)
        assertTrue(store.records["p"]!!.hasUnsyncedChanges)
    }

    @Test
    fun `retries stop eventually instead of looping in the background`() = runTest {
        repeat(50) { remote.failures += ApiException.Offline() }
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        advanceTimeBy(3_600_000)
        runCurrent()
        assertTrue("attempts ${remote.calls.size}", remote.calls.size <= 9)
        assertEquals(SyncStatus.WaitingForServer, sync.status.value)
    }

    @Test
    fun `begin drops a write built on an older version`() = runTest {
        remote.failures += ApiException.Offline()
        val sync = sync()
        sync.update(at(1.0))
        sync.flush()
        sync.begin(at(9.0), 5)
        assertNull(store.records["p"]?.pending)
        assertFalse(store.records["p"]!!.dirty)
    }
}
