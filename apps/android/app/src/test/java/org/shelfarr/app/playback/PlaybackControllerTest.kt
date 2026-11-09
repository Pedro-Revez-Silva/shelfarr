package org.shelfarr.app.playback

import android.app.Application
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.test.core.app.ApplicationProvider
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ContractServer
import org.shelfarr.app.core.LocalProgress
import org.shelfarr.app.core.MemoryStore
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.TEST_EPOCH

/** A scripted audio player: position advances with Robolectric's clock while playing. */
@OptIn(UnstableApi::class)
private class FakeAudioPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
    private var items: List<MediaItem> = emptyList()
    private var index = 0
    private var basePositionMs = 0L
    private var baseAt = 0L
    private var playWhenReady = false
    private var playWhenReadyReason = Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST
    private var state = Player.STATE_IDLE
    private var discontinuity: Pair<Int, Long>? = null

    /** Every seek the player was asked for, as (track index, milliseconds). */
    val seeks = mutableListOf<Pair<Int, Long>>()

    val trackIndex: Int get() = index
    val positionMs: Long get() = now()

    private fun now(): Long =
        if (playWhenReady && state == Player.STATE_READY) basePositionMs + (SystemClock.elapsedRealtime() - baseAt) else basePositionMs

    private fun freeze() {
        basePositionMs = now()
        baseAt = SystemClock.elapsedRealtime()
    }

    override fun getState(): State {
        val builder = State.Builder()
            .setAvailableCommands(Player.Commands.Builder().addAllCommands().build())
            .setPlayWhenReady(playWhenReady, playWhenReadyReason)
            .setContentPositionMs { now() }
        if (items.isEmpty()) {
            builder.setPlaybackState(Player.STATE_IDLE)
        } else {
            builder.setPlaylist(items.mapIndexed { i, item -> MediaItemData.Builder(i).setMediaItem(item).setDurationUs(TRACK_MS * 1_000).build() })
                .setCurrentMediaItemIndex(index)
                .setPlaybackState(state)
        }
        discontinuity?.let { (reason, position) -> builder.setPositionDiscontinuity(reason, position) }
        return builder.build()
    }

    private fun publish() {
        invalidateState()
        discontinuity = null
    }

    override fun handleSetMediaItems(mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
        items = mediaItems.toList()
        index = if (startIndex == C.INDEX_UNSET) 0 else startIndex
        basePositionMs = if (startPositionMs == C.TIME_UNSET) 0 else startPositionMs
        baseAt = SystemClock.elapsedRealtime()
        return Futures.immediateVoidFuture()
    }

    override fun handlePrepare(): ListenableFuture<*> {
        freeze()
        state = Player.STATE_READY
        return Futures.immediateVoidFuture()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        freeze()
        this.playWhenReady = playWhenReady
        playWhenReadyReason = Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        val target = if (mediaItemIndex == C.INDEX_UNSET) index else mediaItemIndex
        val position = if (positionMs == C.TIME_UNSET) 0 else positionMs
        seeks += target to position
        index = target
        basePositionMs = position
        baseAt = SystemClock.elapsedRealtime()
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        freeze()
        state = Player.STATE_IDLE
        return Futures.immediateVoidFuture()
    }

    override fun handleRemoveMediaItems(fromIndex: Int, toIndex: Int): ListenableFuture<*> {
        items = emptyList()
        return Futures.immediateVoidFuture()
    }

    override fun handleSetPlaybackParameters(playbackParameters: androidx.media3.common.PlaybackParameters): ListenableFuture<*> =
        Futures.immediateVoidFuture()

    /** Lock screen, headset or audio focus pausing playback. */
    fun pauseFromOutside(reason: Int) {
        freeze()
        playWhenReady = false
        playWhenReadyReason = reason
        publish()
    }

    /** The lock screen or a headset button pressing play. */
    fun playFromOutside() {
        freeze()
        playWhenReady = true
        playWhenReadyReason = Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST
        publish()
    }

    /** A seek bar on the lock screen or notification. */
    fun seekFromOutside(positionMs: Long) {
        seeks += index to positionMs
        basePositionMs = positionMs
        baseAt = SystemClock.elapsedRealtime()
        discontinuity = Player.DISCONTINUITY_REASON_SEEK to positionMs
        publish()
    }

    /** Playback reaches the end of a track and carries on into the next one. */
    fun finishTrack() {
        index++
        basePositionMs = 0
        baseAt = SystemClock.elapsedRealtime()
        discontinuity = Player.DISCONTINUITY_REASON_AUTO_TRANSITION to 0L
        publish()
    }

    companion object {
        const val TRACK_MS = 600_000L
    }
}

/** A store that remembers every distinct place written, with when it was written. */
private class LoggingStore : org.shelfarr.app.core.ProgressStore {
    val memory = MemoryStore()
    val writes = mutableListOf<Pair<Long, SavedPosition>>()

    override suspend fun get(publicationId: String) = memory.get(publicationId)
    override suspend fun put(record: LocalProgress) {
        val position = record.position
        if (position != null && position != memory.records[record.publicationId]?.position) writes += SystemClock.elapsedRealtime() to position
        memory.put(record)
    }
    override suspend fun unsynced() = memory.unsynced()
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class PlaybackControllerTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val player = FakeAudioPlayer()
    private val store = LoggingStore()
    private val server = ContractServer(now = ::wallClock, assets = setOf("t0", "t1", "t2"))
    private lateinit var sync: ProgressSync
    private lateinit var controller: PlaybackController

    private val address = (ServerAddress.parse("https://books.example") as ServerAddress.ParseResult.Valid).address
    private val book = Publication(
        id = "p",
        title = "Audio",
        bookType = BookType.AUDIOBOOK,
        assets = (0..2).map { Asset("t$it", "$it.mp3", "audio/mpeg", "mp3", 1, "/files/$it", it) },
    )

    private fun wallClock() = TEST_EPOCH + SystemClock.elapsedRealtime()

    @Before
    fun setUp() {
        sync = ProgressSync("p", store, server.remote(), scope, now = ::wallClock)
        controller = PlaybackController(
            ApplicationProvider.getApplicationContext(),
            scope,
            connect = { player },
            wallClock = ::wallClock,
            elapsed = SystemClock::elapsedRealtime,
        )
    }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private fun idle(ms: Long = 0) {
        val looper = shadowOf(Looper.getMainLooper())
        if (ms > 0) looper.idleFor(Duration.ofMillis(ms)) else looper.idle()
    }

    private fun open(start: SavedPosition?, version: Int = 0, observedAt: Long? = null) = runBlocking {
        sync.begin(start, version, observedAt, book.playableAssets.map { it.id })
        controller.load(book, address, sync, start)
        idle()
    }

    private fun saved(): SavedPosition? = store.memory.records["p"]?.position

    private fun seconds(position: SavedPosition?) = position?.positionSeconds ?: -1.0

    @Test
    fun `local checkpoints while playing are never more than five seconds apart or behind`() {
        open(null)
        var worstLag = 0L
        repeat(120) {
            idle(500)
            val heard = player.positionMs
            worstLag = maxOf(worstLag, heard - (seconds(saved()) * 1_000).toLong())
        }
        val times = store.writes.map { it.first }
        val gaps = times.zipWithNext { a, b -> b - a }
        assertTrue("checkpoints: ${store.writes.size}", store.writes.size >= 12)
        assertTrue("largest gap ${gaps.max()}ms", gaps.max() <= 5_000)
        assertTrue("saved place lagged by ${worstLag}ms", worstLag <= 5_000)
        // Each checkpoint carries the time it was heard.
        val record = store.memory.records.getValue("p")
        assertEquals(TEST_EPOCH + store.writes.last().first, record.observedAtEpochMs)
    }

    @Test
    fun `pause, seek, track change, background and stop each checkpoint at once`() {
        open(null)
        idle(2_300)
        controller.togglePlay()
        idle()
        assertEquals(2.3, seconds(saved()), 0.01)

        controller.seekTo(30_000)
        idle()
        assertEquals(SavedPosition("t0", positionSeconds = 30.0), saved())

        controller.togglePlay()
        idle(1_200)
        player.finishTrack()
        idle()
        assertEquals("t1", saved()?.assetId)

        idle(2_000)
        controller.checkpointNow()
        idle()
        assertEquals(2.0, seconds(saved()), 0.01)

        idle(1_500)
        runBlocking { controller.stop() }
        idle()
        assertEquals(3.5, seconds(saved()), 0.01)
    }

    @Test
    fun `opening a saved place rewinds five seconds once and keeps the saved place until passed`() {
        val heardAt = wallClock() - 60_000
        open(SavedPosition("t1", positionSeconds = 100.0), version = 3, observedAt = heardAt)
        assertEquals(1, player.trackIndex)
        assertEquals(95_000, player.positionMs)
        idle(3_000)
        controller.togglePlay()
        idle()
        // The pre-roll was heard again, but the place to come back to is still 100s.
        assertEquals(SavedPosition("t1", positionSeconds = 100.0), saved())
        assertEquals(heardAt, store.memory.records.getValue("p").observedAtEpochMs)
        assertTrue(server.received.isEmpty())

        // Restarting inside the same replay continues from where it stopped.
        controller.togglePlay()
        idle()
        assertEquals(98_000L, player.positionMs)
        assertTrue("no second rewind during pre-roll", player.seeks.isEmpty())
        player.pauseFromOutside(Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        idle()
        player.playFromOutside()
        idle()
        assertEquals(98_000L, player.positionMs)
        assertTrue("a headset resume also continues the replay", player.seeks.isEmpty())
        idle(9_000)
        assertTrue("passed the saved place: ${saved()}", seconds(saved()) > 100.0)
    }

    @Test
    fun `restarting paused playback rewinds within the current track only`() {
        open(SavedPosition("t2", positionSeconds = 1.0))
        assertEquals(0, player.positionMs)
        idle(3_000)
        player.pauseFromOutside(Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY)
        idle()
        player.playFromOutside()
        idle()
        assertEquals("clamped to the start of track three", 2 to 0L, player.seeks.last())
        assertEquals(2, player.trackIndex)
    }

    @Test
    fun `the lock screen's play after a pause rewinds like the app's button`() {
        open(null)
        idle(20_000)
        player.pauseFromOutside(Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
        idle()
        assertEquals(20.0, seconds(saved()), 0.01)
        player.playFromOutside()
        idle()
        assertEquals(0 to 15_000L, player.seeks.last())
        assertEquals(1, player.seeks.size)
    }

    @Test
    fun `deliberate seeks, track choices and natural transitions are not rewound`() {
        open(null)
        idle(20_000)
        controller.togglePlay()
        idle()
        controller.seekTo(50_000)
        controller.togglePlay()
        idle()
        assertEquals(listOf(0 to 50_000L), player.seeks)

        controller.togglePlay()
        idle()
        controller.playTrack(1)
        idle()
        assertEquals(1 to 0L, player.seeks.last())
        assertEquals(2, player.seeks.size)

        controller.togglePlay()
        idle()
        player.seekFromOutside(70_000)
        idle()
        controller.togglePlay()
        idle()
        assertEquals("a lock-screen seek is deliberate too", 3, player.seeks.size)
        assertEquals(SavedPosition("t1", positionSeconds = 70.0), saved())

        idle(5_000)
        player.finishTrack()
        idle()
        assertEquals("a natural transition is never rewound", 3, player.seeks.size)
        assertEquals(SavedPosition("t2", positionSeconds = 0.0), saved())
        assertEquals(0, player.positionMs)
    }

    @Test
    fun `skipping back while paused is real activity and is not rewound again`() {
        open(SavedPosition("t0", positionSeconds = 200.0), version = 1, observedAt = wallClock())
        idle(1_000)
        controller.togglePlay()
        idle()
        controller.skipBack()
        idle()
        val skipped = player.positionMs
        assertEquals(SavedPosition("t0", positionSeconds = skipped / 1_000.0), saved())
        controller.togglePlay()
        idle()
        assertEquals(skipped, player.positionMs)
    }

    @Test
    fun `a later place adopted from another device never moves the playing session`() {
        val started = wallClock()
        open(SavedPosition("t0", positionSeconds = 10.0), version = 1, observedAt = started)
        server.stored = Progress("t0", positionSeconds = 10.0, version = 1, clientMutationId = "seed", observedAt = ActivityTime.format(started))
        idle(20_000)
        // Another device was used a moment after this one's last checkpoint.
        server.stored = Progress(
            "t2", positionSeconds = 400.0, version = server.stored!!.version + 1, clientMutationId = "other",
            observedAt = ActivityTime.format(wallClock() + 1),
        )
        val seeks = player.seeks.size
        runBlocking { sync.flush() }
        idle()
        assertEquals(SavedPosition("t2", positionSeconds = 400.0), saved())
        assertEquals("the player stays where the listener is", seeks, player.seeks.size)
        assertEquals(0, player.trackIndex)

        // Listening on here is the newest activity, so it is what the server ends up with.
        idle(6_000)
        runBlocking { sync.flush() }
        idle()
        assertEquals("t0", server.stored?.assetId)
        assertTrue(seconds(saved()) > 20.0)
    }
}
