package org.shelfarr.app.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Two devices against a server that follows the activity-time contract. Each device
 * has its own store, clock and mutation ids; "restarting" one builds a new
 * [ProgressSync] over the same store.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ProgressReconciliationTest {
    private fun at(seconds: Double, asset: String = "a") = SavedPosition(asset, positionSeconds = seconds)

    private inner class Device(
        private val name: String,
        private val test: TestScope,
        private val server: ContractServer,
        /** How far this device's clock is from the server's. */
        var skewMs: Long = 0,
    ) {
        val store = MemoryStore()
        private var ids = 0

        /** No connection: requests never leave the device. */
        var offline = false

        /** Requests that reach the server but fail before it applies them. */
        val failures = ArrayDeque<ApiException>()

        private val attempts = mutableListOf<ProgressUpdate>()
        private val remote = ProgressRemote { _, update ->
            if (offline) throw ApiException.Offline()
            attempts += update
            failures.removeFirstOrNull()?.let { throw it }
            server.save(update)
        }
        var live = start()

        fun clock() = TEST_EPOCH + test.currentTime + skewMs

        fun start() = ProgressSync("p", store, remote, test.backgroundScope, now = ::clock, newMutationId = { "$name-${++ids}" })

        fun restart() {
            live = start()
        }

        val record: LocalProgress get() = store.records.getValue("p")

        /** Every request that left this device, in order. */
        fun sent(): List<ProgressUpdate> = attempts.toList()

        /** Moves to [position] at the device's current time, as a page turn or checkpoint would. */
        suspend fun reach(position: SavedPosition): Long = clock().also { live.update(position, it) }
    }

    private class World(test: TestScope) {
        val server = ContractServer(now = { TEST_EPOCH + test.currentTime })
    }

    /** Both devices open the book synced at version 1, 10s in, reached at the start of the test. */
    private suspend fun TestScope.shared(world: World, vararg devices: Device) {
        val started = TEST_EPOCH + currentTime
        world.server.stored = Progress(
            "a", positionSeconds = 10.0, version = 1, clientMutationId = "seed",
            observedAt = ActivityTime.format(started),
        )
        devices.forEach { it.live.begin(at(10.0), 1, started, listOf("a", "b")) }
    }

    private fun TestScope.both(): Triple<World, Device, Device> {
        val world = World(this)
        return Triple(world, Device("A", this, world.server), Device("B", this, world.server))
    }

    @Test
    fun `matching places still publish the later activity before a third device reconnects`() = runTest {
        val world = World(this)
        val a = Device("A", this, world.server)
        val b = Device("B", this, world.server)
        val c = Device("C", this, world.server)
        shared(world, a, b, c)
        b.live.update(at(120.0), TEST_EPOCH + 1000)
        c.live.update(at(30.0), TEST_EPOCH + 2000)
        a.live.update(at(120.0), TEST_EPOCH + 3000)
        b.live.flush()
        a.live.flush()
        assertEquals(ActivityTime.format(TEST_EPOCH + 3000), world.server.stored!!.observedAt)
        c.live.flush()
        assertEquals(120.0, world.server.stored!!.positionSeconds)
        assertEquals(TEST_EPOCH + 3000, c.record.observedAtEpochMs)
        assertFalse(a.record.hasUnsyncedChanges)
        assertTrue(a.sent().none { it.resolveConflict == true })
    }

    @Test
    fun `matching places adopt the canonical later timestamp`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        a.live.update(at(120.0), TEST_EPOCH + 1000)
        b.live.update(at(120.0), TEST_EPOCH + 3000)
        b.live.flush()
        a.live.flush()
        assertEquals(TEST_EPOCH + 3000, a.record.observedAtEpochMs)
        assertFalse(a.record.hasUnsyncedChanges)
        assertEquals(1, a.sent().size)
    }

    @Test
    fun `later activity wins when the earlier device syncs first, even after seeking backward`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        a.offline = true
        b.offline = true
        advanceTimeBy(60_000)
        a.reach(at(500.0))
        advanceTimeBy(60_000)
        // B is used later and deliberately goes back, nearer the start of the book.
        val bTime = b.reach(at(100.0))
        advanceTimeBy(60_000)
        runCurrent()

        a.offline = false
        b.offline = false
        a.live.flush()
        b.live.flush()
        runCurrent()

        val stored = world.server.stored!!
        assertEquals(100.0, stored.positionSeconds)
        assertEquals(ActivityTime.format(bTime), stored.observedAt)
        // B's first write lost on version, then went again on top with its original time and a new id.
        val bWrites = b.sent()
        assertEquals(2, bWrites.map { it.clientMutationId }.distinct().size)
        assertTrue(bWrites.all { it.observedAt == ActivityTime.format(bTime) })
        assertTrue(bWrites.none { it.resolveConflict == true })
        assertEquals(SyncStatus.Saved, b.live.status.value)
    }

    @Test
    fun `later activity wins when the later device syncs first`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        a.offline = true
        b.offline = true
        advanceTimeBy(60_000)
        a.reach(at(500.0))
        advanceTimeBy(60_000)
        val bTime = b.reach(at(100.0))
        advanceTimeBy(60_000)
        runCurrent()

        a.offline = false
        b.offline = false
        b.live.flush()
        a.live.flush()
        runCurrent()

        assertEquals(100.0, world.server.stored!!.positionSeconds)
        assertEquals(2, world.server.stored!!.version)
        // A's stale retry was refused and A adopted B's later place without writing again.
        val aWrites = a.sent()
        assertEquals(1, aWrites.map { it.clientMutationId }.distinct().size)
        assertEquals(at(100.0), a.record.position)
        assertEquals(bTime, a.record.observedAtEpochMs)
        assertFalse(a.record.hasUnsyncedChanges)
        assertEquals(SyncStatus.Saved, a.live.status.value)
        // Opening A now resumes B's place.
        val book = Publication("p", "T", bookType = BookType.AUDIOBOOK, assets = listOf(Asset("a", format = "mp3", contentUrl = "/a")))
        assertEquals(
            ResumeDecision.Continue(at(100.0), 2, bTime),
            ResumeDecision.decide(book, world.server.stored, a.record, now = a.clock()),
        )
    }

    @Test
    fun `both orders still converge after both devices restart`() = runTest {
        for (laterFirst in listOf(true, false)) {
            val (world, a, b) = both()
            shared(world, a, b)
            a.offline = true
            b.offline = true
            advanceTimeBy(60_000)
            a.reach(at(700.0))
            advanceTimeBy(60_000)
            b.reach(at(50.0))
            runCurrent()
            a.restart()
            b.restart()
            a.offline = false
            b.offline = false
            if (laterFirst) b.live.flush() else a.live.flush()
            if (laterFirst) a.live.flush() else b.live.flush()
            runCurrent()
            assertEquals("laterFirst=$laterFirst", 50.0, world.server.stored!!.positionSeconds)
            // A converges too: adopted at once, or resumed from the server when opened next.
            val book = Publication("p", "T", bookType = BookType.AUDIOBOOK, assets = listOf(Asset("a", format = "mp3", contentUrl = "/a")))
            val decision = ResumeDecision.decide(book, world.server.stored, a.live.snapshot(), now = a.clock())
            assertEquals("laterFirst=$laterFirst", at(50.0), (decision as ResumeDecision.Continue).position)
        }
    }

    @Test
    fun `a retry keeps its body and time while a newer local place queued behind it still wins`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        advanceTimeBy(10_000)
        repeat(3) { a.failures += ApiException.Server(503) }
        val first = a.reach(at(20.0))
        a.live.flush()
        val firstAttempt = a.sent().first()

        // B moves on in between, then A keeps listening behind its unanswered write.
        advanceTimeBy(10_000)
        b.reach(at(900.0))
        b.live.flush()
        advanceTimeBy(10_000)
        val newest = a.reach(at(30.0))
        a.live.flush()

        val attempts = a.sent()
        assertEquals("the retry repeats the same request", firstAttempt, attempts[1])
        assertEquals(ActivityTime.format(first), attempts[1].observedAt)
        // After the definite conflict the newest local place goes, keeping its own time.
        val rebased = attempts.last()
        assertEquals(30.0, rebased.positionSeconds)
        assertEquals(ActivityTime.format(newest), rebased.observedAt)
        assertNotEquals(firstAttempt.clientMutationId, rebased.clientMutationId)
        assertNull(rebased.resolveConflict)
        assertEquals(30.0, world.server.stored!!.positionSeconds)
    }

    @Test
    fun `a stale retry never overwrites the other device's later place`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        advanceTimeBy(10_000)
        repeat(3) { a.failures += ApiException.Server(503) }
        a.reach(at(20.0))
        a.live.flush()
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        // B is used after everything A queued.
        advanceTimeBy(10_000)
        val bTime = b.reach(at(5.0))
        b.live.flush()

        a.live.flush()
        assertEquals(5.0, world.server.stored!!.positionSeconds)
        assertEquals(at(5.0), a.record.position)
        assertEquals(bTime, a.record.observedAtEpochMs)
        assertNull(a.record.pending)
        assertFalse(a.record.dirty)
    }

    @Test
    fun `an answer lost in transit is retried after a restart without a second write`() = runTest {
        val (world, a) = both()
        shared(world, a)
        advanceTimeBy(5_000)
        world.server.loseResponses = 1
        val reached = a.reach(at(42.0))
        a.live.flush()
        assertEquals(2, world.server.stored!!.version)

        a.restart()
        a.live.flush()
        val attempts = a.sent()
        assertEquals(attempts[0], attempts[1])
        assertEquals(2, world.server.stored!!.version)
        assertEquals(2, a.record.baseVersion)
        assertEquals("acknowledging is not new activity", reached, a.record.observedAtEpochMs)
    }

    @Test
    fun `a place is on disk with its time the moment it is reported`() = runTest {
        val (world, a) = both()
        shared(world, a)
        a.offline = true
        advanceTimeBy(3_000)
        val reached = a.reach(at(77.5))
        // The process dies here: nothing else ran.
        val saved = a.store.records.getValue("p")
        assertEquals(at(77.5), saved.position)
        assertEquals(reached, saved.observedAtEpochMs)
        assertTrue(saved.dirty)

        a.restart()
        val book = Publication("p", "T", bookType = BookType.AUDIOBOOK, assets = listOf(Asset("a", format = "mp3", contentUrl = "/a")))
        assertEquals(
            ResumeDecision.Continue(at(77.5), 1, reached),
            ResumeDecision.decide(book, world.server.stored, a.live.snapshot(), offline = true, now = a.clock()),
        )
    }

    @Test
    fun `the time sent is when the place was reached, not when it was processed`() = runTest {
        val (world, a) = both()
        shared(world, a)
        advanceTimeBy(1_000)
        val reached = a.clock()
        advanceTimeBy(30_000)
        a.live.update(at(12.0), reached)
        a.live.flush()
        assertEquals(ActivityTime.format(reached), a.sent().single().observedAt)
    }

    @Test
    fun `a clock that steps back keeps one device's places in order`() = runTest {
        val (world, a) = both()
        shared(world, a)
        advanceTimeBy(10_000)
        val first = a.reach(at(20.0))
        a.live.flush()
        a.skewMs = -2_000
        a.reach(at(25.0))
        a.live.flush()
        assertEquals(25.0, world.server.stored!!.positionSeconds)
        assertEquals(first + 1, a.record.observedAtEpochMs)
    }

    @Test
    fun `an older server without activity times keeps the explicit choice`() = runTest {
        val (world, a, b) = both()
        world.server.knowsActivityTime = false
        shared(world, a, b)
        world.server.stored = world.server.stored!!.copy(observedAt = null)
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        a.live.flush()
        advanceTimeBy(10_000)
        b.reach(at(60.0))
        b.live.flush()

        val conflict = b.live.status.value as SyncStatus.Conflict
        assertEquals(at(60.0), conflict.local)
        assertNull(conflict.server.observedAt)

        advanceTimeBy(5_000)
        val chosenAt = b.clock()
        b.live.keepLocal()
        val choice = b.sent().last()
        assertEquals(true, choice.resolveConflict)
        assertEquals(ActivityTime.format(chosenAt), choice.observedAt)
        assertEquals(2, choice.expectedVersion)
        assertEquals(60.0, world.server.stored!!.positionSeconds)
        assertEquals(SyncStatus.Saved, b.live.status.value)
    }

    @Test
    fun `a write queued by an older app version is retried as it was, and a conflict asks`() = runTest {
        val world = World(this)
        val a = Device("A", this, world.server)
        // Saved before activity times existed: no observed time anywhere.
        val legacy = """{"p":{"publicationId":"p","position":{"assetId":"a","positionSeconds":33.0},"baseVersion":1,
            |"pending":{"position":{"assetId":"a","positionSeconds":33.0},"expectedVersion":1,"mutationId":"A-legacy"},
            |"updatedAtEpochMs":5}}""".trimMargin()
        a.store.records.putAll(ApiJson.decodeFromString<Map<String, LocalProgress>>(legacy))
        world.server.stored = Progress("a", positionSeconds = 80.0, version = 2, clientMutationId = "B-1", observedAt = ActivityTime.format(TEST_EPOCH))

        a.restart()
        a.live.flush()
        val retry = a.sent().single()
        assertEquals("A-legacy", retry.clientMutationId)
        assertNull(retry.observedAt)
        assertTrue(a.live.status.value is SyncStatus.Conflict)
        assertEquals("the local place is kept for the choice", at(33.0), a.record.position)
        assertTrue(a.record.hasUnsyncedChanges)
    }

    @Test
    fun `equal times at different places ask`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        b.reach(at(60.0))
        a.live.flush()
        b.live.flush()
        assertTrue(b.live.status.value is SyncStatus.Conflict)
        assertEquals(30.0, world.server.stored!!.positionSeconds)
        assertEquals(at(60.0), b.record.position)
    }

    @Test
    fun `a server time too far ahead of this device asks instead of adopting`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        // B's clock is four minutes fast (the server allows it); A's is four minutes slow.
        b.skewMs = 4 * 60_000
        a.skewMs = -4 * 60_000
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        b.reach(at(60.0))
        b.live.flush()
        a.live.flush()
        assertTrue(a.live.status.value is SyncStatus.Conflict)
        assertEquals(at(30.0), a.record.position)
    }

    @Test
    fun `a device clock that was never set asks instead of losing its place`() = runTest {
        val (world, a) = both()
        shared(world, a)
        a.skewMs = -(TEST_EPOCH - 86_400_000)
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        a.live.flush()
        // The server refused an "older" time; that time can't be trusted to adopt by.
        assertTrue(a.live.status.value is SyncStatus.Conflict)
        assertEquals(at(30.0), a.record.position)
    }

    @Test
    fun `a time the server calls future is refused and kept`() = runTest {
        val (world, a) = both()
        shared(world, a)
        a.skewMs = 10 * 60_000
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        a.live.flush()
        assertEquals(SyncStatus.Rejected, a.live.status.value)
        assertEquals(at(30.0), a.record.position)
        assertTrue(a.record.hasUnsyncedChanges)
        assertEquals(10.0, world.server.stored!!.positionSeconds)
    }

    @Test
    fun `a place on an asset this edition can't map asks even with known times`() = runTest {
        val (world, a, b) = both()
        shared(world, a, b)
        a.live.begin(at(10.0), 1, null, listOf("a"))
        advanceTimeBy(10_000)
        b.reach(at(60.0, asset = "b"))
        b.live.flush()
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        a.live.flush()
        assertTrue(a.live.status.value is SyncStatus.Conflict)
    }

    @Test
    fun `keeping this device is a new choice, on disk before it is sent, and later rebases don't resend the flag`() = runTest {
        val world = World(this)
        val a = Device("A", this, world.server)
        world.server.stored = Progress("a", positionSeconds = 80.0, version = 3, clientMutationId = "B-1")
        a.live.begin(at(10.0), 1, null, listOf("a"))
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        a.live.flush()
        assertTrue(a.live.status.value is SyncStatus.Conflict)

        // Someone else writes again, with a known time, before the choice reaches the server.
        var seenOnDisk: PendingMutation? = null
        val guarded = ProgressSync("p", a.store, { id, update ->
            if (update.resolveConflict == true) {
                seenOnDisk = a.store.records.getValue("p").pending
                world.server.stored = Progress("a", positionSeconds = 81.0, version = 4, clientMutationId = "B-2", observedAt = ActivityTime.format(TEST_EPOCH + 1_000))
            }
            world.server.save(update)
        }, backgroundScope, now = a::clock, newMutationId = { "A-c${world.server.received.size}" })
        advanceTimeBy(20_000)
        val chosenAt = a.clock()
        guarded.keepLocal()

        assertEquals(true, seenOnDisk?.resolveConflict)
        assertEquals(chosenAt, seenOnDisk?.observedAtEpochMs)
        val choice = world.server.received[world.server.received.size - 2]
        val rebase = world.server.received.last()
        assertEquals(true, choice.resolveConflict)
        assertNull("automatic rebasing never sets the flag", rebase.resolveConflict)
        assertEquals(choice.observedAt, rebase.observedAt)
        assertEquals(30.0, world.server.stored!!.positionSeconds)
        assertEquals(chosenAt, a.store.records.getValue("p").observedAtEpochMs)
    }

    @Test
    fun `a wiped server takes the local place on top of nothing`() = runTest {
        val world = World(this)
        val a = Device("A", this, world.server)
        a.live.begin(at(10.0), 4, TEST_EPOCH, listOf("a"))
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        a.live.flush()
        assertEquals(30.0, world.server.stored!!.positionSeconds)
        assertEquals(0, a.sent().last().expectedVersion)
    }

    @Test
    fun `a storage failure is surfaced, keeps the place in memory and still syncs`() = runTest {
        val (world, a) = both()
        shared(world, a)
        a.store.failWrites = true
        advanceTimeBy(10_000)
        a.reach(at(30.0))
        assertEquals(SyncStatus.StorageFailed, a.live.status.value)
        assertEquals(at(30.0), a.live.snapshot().position)
        a.live.flush()
        assertEquals(30.0, world.server.stored!!.positionSeconds)
        assertEquals(SyncStatus.StorageFailed, a.live.status.value)

        a.store.failWrites = false
        a.reach(at(31.0))
        a.live.flush()
        assertEquals(SyncStatus.Saved, a.live.status.value)
        assertEquals(at(31.0), a.store.records.getValue("p").position)
    }

    @Test
    fun `opening and restoring a place is not new activity`() = runTest {
        val (world, a) = both()
        shared(world, a)
        advanceTimeBy(60_000)
        a.live.update(at(10.0), a.clock())
        a.live.flush()
        assertTrue(a.sent().isEmpty())
        assertEquals(TEST_EPOCH, a.record.observedAtEpochMs)
    }

    @Test
    fun `a persisted record round-trips its activity fields`() {
        val record = LocalProgress(
            "p", at(1.0), baseVersion = 3, pending = PendingMutation(at(1.0), 3, "m", 123L, resolveConflict = true),
            observedAtEpochMs = 123L, assetIds = listOf("a"), rejected = true,
        )
        val json = ApiJson.encodeToString(record)
        assertEquals(record, ApiJson.decodeFromString<LocalProgress>(json))
    }
}
