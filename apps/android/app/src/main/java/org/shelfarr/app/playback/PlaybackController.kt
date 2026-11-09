package org.shelfarr.app.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.SystemClock
import java.io.File
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.datasource.HttpDataSource
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.NarrationPoint
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress

data class AudioChapter(val title: String?, val startMs: Long)

/** Which read-along narration is queued: one ebook publication and manifest generation. */
data class NarrationInfo(val publicationId: String, val generation: String)

/**
 * Where listening checkpoints are saved. Each call happens with the time the place was
 * heard, captured before anything waited, and returns once the place is on this device.
 */
interface ListeningSink {
    suspend fun record(trackIndex: Int, mediaId: String, positionMs: Long, observedAtEpochMs: Long)

    /** Sends whatever is outstanding now. */
    suspend fun flush()
}

/** An audiobook's own place: the file and second heard. */
class AudiobookSink(val sync: ProgressSync) : ListeningSink {
    override suspend fun record(trackIndex: Int, mediaId: String, positionMs: Long, observedAtEpochMs: Long) {
        sync.update(SavedPosition(assetId = mediaId, positionSeconds = positionMs.coerceAtLeast(0) / 1_000.0), observedAtEpochMs)
    }

    override suspend fun flush() = sync.flush()
}

/** One narration file to queue: where it plays from, and how it is announced. */
data class NarrationSource(val mediaId: String, val uri: String, val title: String?)

/** An ebook's read-along narration, queued like an audiobook in the one shared player. */
class NarrationQueue(
    val publication: Publication,
    val info: NarrationInfo,
    val sources: List<NarrationSource>,
    val sink: ListeningSink,
    val fromDevice: Boolean,
    val coverUri: String?,
)

/** Where narration starts. A resume restarts a little earlier and holds the saved place; a choice plays exactly there. */
data class NarrationStart(val track: Int, val positionMs: Long, val resume: Boolean)

enum class PlaybackProblem { CONNECTION, SIGN_IN, UNSUPPORTED, UNAVAILABLE }

/** What the player is genuinely doing, read from Media3. */
data class PlaybackSnapshot(
    val publication: Publication? = null,
    val tracks: List<Asset> = emptyList(),
    val trackIndex: Int = 0,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val ended: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val speed: Float = 1f,
    val chapters: List<AudioChapter> = emptyList(),
    val sleepTimerEndsAtMs: Long? = null,
    val problem: PlaybackProblem? = null,
    /** Every track plays from a verified download on this device. */
    val fromDevice: Boolean = false,
    /** Set while the queue is an ebook's read-along narration rather than an audiobook. */
    val narration: NarrationInfo? = null,
) {
    val isLoaded: Boolean get() = publication != null
    val currentAsset: Asset? get() = tracks.getOrNull(trackIndex)

    val chapterIndex: Int
        get() = chapters.indexOfLast { it.startMs <= positionMs }
}

/**
 * App-lifetime bridge to [PlaybackService]. It holds no UI, so the position keeps
 * being saved while the app is in the background or the screen is locked.
 *
 * While playing, a local checkpoint is written at most every
 * [ListeningCheckpoints.CHECKPOINT_INTERVAL_MS] (under five seconds); pause, stop,
 * seeks, natural track changes, errors and backgrounding write one at once. Each
 * checkpoint carries the wall-clock time it was taken, captured before any waiting.
 */
class PlaybackController(
    private val context: Context,
    private val scope: CoroutineScope,
    /** Supplies the player; by default a controller connected to [PlaybackService]. Tests pass their own. */
    private val connect: (suspend () -> Player)? = null,
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val elapsed: () -> Long = SystemClock::elapsedRealtime,
) {
    private var controller: Player? = null
    private var sink: ListeningSink? = null
    private var ticker: Job? = null
    private var sleepTimer: Job? = null
    private val chapters = HashMap<String, List<AudioChapter>>()
    private val checkpoints = ListeningCheckpoints()

    /** Our own resume rewind or restoring seek, so it isn't mistaken for the listener's. */
    private var rewinding: Rewind? = null

    /**
     * The last point written as heard. A checkpoint of the same point again (paused, then
     * backgrounded, stopped or switched away) is not new listening: it must not stamp that
     * old audio with a fresh time over whatever was read meanwhile.
     */
    private var lastRecorded: Pair<String, Long>? = null

    /**
     * Playback has stopped and its place is written; nothing has been heard since. A paused
     * controller's position can still settle by some milliseconds once the service reports
     * where it really stopped. That is not listening: until playback resumes or the listener
     * moves, later checkpoints (backgrounding, stopping, switching away) record nothing.
     */
    private var stillSinceStopped = false

    private data class Rewind(val index: Int, val positionMs: Long, val atElapsedMs: Long)

    private val state = MutableStateFlow(PlaybackSnapshot())
    val snapshot: StateFlow<PlaybackSnapshot> = state.asStateFlow()

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            refresh(player)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) {
                stillSinceStopped = false
                startTicker()
            } else {
                ticker?.cancel()
                checkpoint(flush = true)
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (!playWhenReady) {
                checkpoints.paused()
                return
            }
            // Only someone pressing play resumes: not audio focus coming back, nor a new queue.
            if (reason != Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) return
            val player = controller ?: return
            val here = currentPosition() ?: return
            val target = checkpoints.resumed(here) ?: return
            rewinding = Rewind(player.currentMediaItemIndex, target, elapsed())
            player.seekTo(player.currentMediaItemIndex, target)
        }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            when (reason) {
                Player.DISCONTINUITY_REASON_SEEK -> {
                    if (isOwnRewind(newPosition)) return
                    // Lock screen, headset, notification or in-app: the listener chose this place.
                    checkpoints.movedDeliberately()
                    checkpoint(flush = false, chosen = true)
                }
                // A natural move into the next track.
                Player.DISCONTINUITY_REASON_AUTO_TRANSITION -> checkpoint(flush = false)
                // Queue changes, seek adjustments and skipped items are not the listener moving.
                else -> Unit
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            state.update { it.copy(problem = classify(error), isPlaying = false, isBuffering = false) }
            ticker?.cancel()
            checkpoint(flush = true)
        }
    }

    private fun isOwnRewind(position: Player.PositionInfo): Boolean {
        val rewind = rewinding ?: return false
        if (elapsed() - rewind.atElapsedMs > REWIND_ECHO_MS) {
            rewinding = null
            return false
        }
        val matches = position.mediaItemIndex == rewind.index && kotlin.math.abs(position.positionMs - rewind.positionMs) < 1_000
        if (!matches) rewinding = null
        return matches
    }

    /**
     * Queues a publication and starts it a little before [start] (see [ListeningCheckpoints]),
     * or at the beginning. The saved place itself is left as it was.
     */
    suspend fun load(
        publication: Publication,
        server: ServerAddress,
        sync: ProgressSync,
        start: SavedPosition?,
        localFiles: Map<String, File>? = null,
    ) {
        val tracks = publication.audioAssets
        // Downloaded files are used only when every track is on the device.
        val local = localFiles?.takeIf { files -> tracks.all { files[it.id] != null } }
        val items = tracks.mapNotNull { asset -> mediaItem(publication, asset, server, local?.get(asset.id)) }
        check(items.size == tracks.size && items.isNotEmpty()) { "Audio asset outside the configured server" }

        val player = connected()
        val target = (sink as? AudiobookSink)?.takeIf { it.sync === sync } ?: AudiobookSink(sync)
        // Switching books: the one being left gets its last place first.
        if (sink != null && sink !== target) checkpoint(flush = true)
        this.sink = target
        chapters.clear()
        val index = tracks.indexOfFirst { it.id == start?.assetId }.coerceAtLeast(0)
        rewinding = null
        lastRecorded = null
        stillSinceStopped = false
        val positionMs = checkpoints.open(start?.takeIf { tracks[index].id == it.assetId }, tracks[index].id)
        state.update {
            PlaybackSnapshot(publication = publication, tracks = tracks, trackIndex = index, speed = it.speed, fromDevice = local != null)
        }
        player.setMediaItems(items, index, positionMs)
        player.prepare()
        player.play()
    }

    /**
     * Queues an ebook's read-along narration in the same player, session and notification
     * as audiobooks, and plays it from [start]. Whatever was playing gets its last place first.
     */
    suspend fun loadNarration(queue: NarrationQueue, start: NarrationStart, speed: Float? = null) {
        require(queue.sources.isNotEmpty() && start.track in queue.sources.indices)
        val player = connected()
        if (sink != null && sink !== queue.sink) checkpoint(flush = true)
        this.sink = queue.sink
        chapters.clear()
        rewinding = null
        lastRecorded = null
        stillSinceStopped = false
        val first = queue.sources[start.track]
        val positionMs = if (start.resume) {
            checkpoints.open(SavedPosition(first.mediaId, positionSeconds = start.positionMs / 1_000.0), first.mediaId)
        } else {
            // A place the reader chose: no rewind, and real listening from the first moment.
            checkpoints.open(null, first.mediaId)
            checkpoints.movedDeliberately()
            start.positionMs.coerceAtLeast(0)
        }
        val tracks = queue.sources.mapIndexed { index, source ->
            Asset(id = source.mediaId, filename = source.title.orEmpty(), mediaType = "audio/*", contentUrl = source.uri, position = index)
        }
        state.update {
            PlaybackSnapshot(
                publication = queue.publication,
                tracks = tracks,
                trackIndex = start.track,
                speed = speed ?: it.speed,
                fromDevice = queue.fromDevice,
                narration = queue.info,
            )
        }
        val items = queue.sources.map { source -> narrationItem(queue, source) }
        player.setMediaItems(items, start.track, positionMs)
        speed?.let { player.playbackParameters = PlaybackParameters(it) }
        player.prepare()
        player.play()
    }

    private fun narrationItem(queue: NarrationQueue, source: NarrationSource): MediaItem {
        val uri = Uri.parse(source.uri)
        val extras = android.os.Bundle().apply { putString(EXTRA_READ_ALONG_PUBLICATION, queue.publication.id) }
        return MediaItem.Builder()
            .setMediaId(source.mediaId)
            .setUri(uri)
            .setRequestMetadata(MediaItem.RequestMetadata.Builder().setMediaUri(uri).build())
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(queue.publication.title)
                    .setArtist(queue.publication.author)
                    .setSubtitle(if (queue.sources.size > 1) "Read along · ${source.title.orEmpty()}".trimEnd(' ', '·') else "Read along")
                    .setArtworkUri(queue.coverUri?.let(Uri::parse))
                    .setExtras(extras)
                    .build(),
            )
            .build()
    }

    /** True while [info]'s narration is the queue, playing or not. */
    fun isNarrating(info: NarrationInfo): Boolean = state.value.narration == info

    /** The narration point being heard now: file index and offset. Main thread only. */
    fun heardNow(): NarrationPoint? {
        val player = controller ?: return null
        if (state.value.narration == null) return null
        val index = player.currentMediaItemIndex.takeIf { it >= 0 } ?: return null
        return NarrationPoint(index, player.currentPosition.coerceAtLeast(0))
    }

    /** Plays the queued narration from a place the reader chose: never rewound, saved at once. */
    fun playNarrationAt(track: Int, positionMs: Long) = deliberately {
        seekTo(track, positionMs.coerceAtLeast(0))
        play()
    }

    private fun mediaItem(publication: Publication, asset: Asset, server: ServerAddress, file: File?): MediaItem? {
        val uri = if (file != null) {
            Uri.fromFile(file)
        } else {
            val url = server.resolve(asset.contentUrl)?.takeIf(server::contains) ?: return null
            Uri.parse(url.toString())
        }
        val cover = publication.coverUrl?.let(server::resolve)?.takeIf(server::contains)
        return MediaItem.Builder()
            .setMediaId(asset.id)
            .setUri(uri)
            .setRequestMetadata(MediaItem.RequestMetadata.Builder().setMediaUri(uri).build())
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(publication.title)
                    .setArtist(publication.author)
                    .setSubtitle(asset.filename.takeIf { publication.audioAssets.size > 1 })
                    .setArtworkUri(cover?.let { Uri.parse(it.toString()) })
                    .build(),
            )
            .build()
    }

    private suspend fun connected(): Player {
        controller?.takeIf { (it as? MediaController)?.isConnected ?: true }?.let { return it }
        val player = connect?.invoke() ?: connectToService()
        player.addListener(listener)
        controller = player
        return player
    }

    private suspend fun connectToService(): MediaController {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        val connected = suspendCancellableCoroutine { continuation ->
            future.addListener(
                {
                    try {
                        continuation.resume(future.get())
                    } catch (error: java.util.concurrent.ExecutionException) {
                        continuation.resumeWithException(error.cause ?: error)
                    }
                },
                ContextCompat.getMainExecutor(context),
            )
            continuation.invokeOnCancellation { future.cancel(true) }
        }
        return connected
    }

    fun togglePlay() {
        val player = controller ?: return
        when {
            state.value.problem != null -> {
                state.update { it.copy(problem = null) }
                player.prepare()
                player.play()
            }
            player.playbackState == Player.STATE_ENDED -> {
                player.seekTo(0, 0)
                player.play()
            }
            player.isPlaying -> player.pause()
            else -> player.play()
        }
    }

    /** Playing, or about to once buffered. Main thread only. */
    val isListening: Boolean
        get() = controller?.let { player ->
            player.isPlaying ||
                (player.playWhenReady && player.playbackState != Player.STATE_IDLE && player.playbackState != Player.STATE_ENDED)
        } == true

    /** Pauses without toggling; the place is saved as playback stops. Main thread only. */
    fun pause() {
        if (isListening) controller?.pause()
    }

    fun seekTo(positionMs: Long) = deliberately { seekTo(positionMs) }

    fun skipBack() = deliberately { seekBack() }

    fun skipForward() = deliberately { seekForward() }

    fun playTrack(index: Int) = deliberately {
        seekTo(index, 0)
        play()
    }

    fun playChapter(chapter: AudioChapter) = deliberately {
        seekTo(chapter.startMs)
        play()
    }

    /** A place the listener picked: never rewound, and saved at once. */
    private inline fun deliberately(action: Player.() -> Unit) {
        val player = controller ?: return
        checkpoints.movedDeliberately()
        player.action()
        checkpoint(flush = false, chosen = true)
    }

    fun setSpeed(speed: Float) {
        controller?.playbackParameters = PlaybackParameters(speed)
    }

    /** Pauses after [minutes]; zero or null cancels. */
    fun setSleepTimer(minutes: Int?) {
        sleepTimer?.cancel()
        sleepTimer = null
        if (minutes == null || minutes <= 0) {
            state.update { it.copy(sleepTimerEndsAtMs = null) }
            return
        }
        val delayMs = minutes * 60_000L
        state.update { it.copy(sleepTimerEndsAtMs = System.currentTimeMillis() + delayMs) }
        sleepTimer = scope.launch {
            delay(delayMs)
            controller?.pause()
            state.update { it.copy(sleepTimerEndsAtMs = null) }
        }
    }

    /**
     * Moves to a place adopted from another device or the reader (a conflict choice, a later
     * audiobook place). Like opening it, that is not listening: the player waits a little
     * before it (the one resume rewind) and the place itself stays the saved one, with its own
     * activity time, until playback passes it. Any later play, in the app or from the lock
     * screen or a headset, starts there.
     */
    fun restore(trackIndex: Int, positionMs: Long) {
        val player = controller ?: return
        val track = state.value.tracks.getOrNull(trackIndex) ?: return
        val target = checkpoints.open(SavedPosition(track.id, positionSeconds = positionMs.coerceAtLeast(0) / 1_000.0), track.id)
        rewinding = Rewind(trackIndex, target, elapsed())
        player.seekTo(trackIndex, target)
        controller?.let(::refresh)
    }

    /** Moves to a place chosen after a conflict: restored, not listened to. */
    fun jumpTo(position: SavedPosition) {
        val index = state.value.tracks.indexOfFirst { it.id == position.assetId }
        if (index < 0) return
        restore(index, ((position.positionSeconds ?: 0.0) * 1_000).toLong())
    }

    /**
     * Writes the current place now, without waiting for the next periodic checkpoint.
     * Call from the main thread, e.g. as the app goes to the background.
     */
    fun checkpointNow(): Job? = checkpoint(flush = false)

    /** Saves the final position, then stops and forgets the queue. */
    suspend fun stop() = withContext(Dispatchers.Main.immediate) {
        val observedAt = wallClock()
        val position = currentPosition()?.takeIf { heardSinceStopped() }?.takeIf(checkpoints::isActivity)
        val index = controller?.currentMediaItemIndex ?: 0
        val heard = position?.takeIf { it.assetId to it.millis() != lastRecorded }
        val target = sink
        sink = null
        lastRecorded = null
        stillSinceStopped = false
        sleepTimer?.cancel()
        ticker?.cancel()
        controller?.run {
            stop()
            clearMediaItems()
        }
        state.value = PlaybackSnapshot()
        if (target != null) {
            heard?.let { target.record(index, it.assetId, it.millis(), observedAt) }
            target.flush()
        }
    }

    fun onChaptersFound(assetId: String, found: List<AudioChapter>) {
        if (found.isEmpty()) return
        chapters[assetId] = found
        controller?.let(::refresh)
    }

    private fun refresh(player: Player) {
        state.update { current ->
            if (current.publication == null) return@update current
            val assetId = player.currentMediaItem?.mediaId
            val index = current.tracks.indexOfFirst { it.id == assetId }.takeIf { it >= 0 } ?: current.trackIndex
            current.copy(
                trackIndex = index,
                isPlaying = player.isPlaying,
                isBuffering = player.playbackState == Player.STATE_BUFFERING,
                ended = player.playbackState == Player.STATE_ENDED,
                positionMs = player.currentPosition.coerceAtLeast(0),
                durationMs = player.duration.takeIf { it > 0 } ?: 0,
                speed = player.playbackParameters.speed,
                chapters = chapters[assetId].orEmpty(),
                problem = if (player.playerError == null) null else current.problem,
            )
        }
    }

    private fun startTicker() {
        ticker?.cancel()
        ticker = scope.launch {
            while (isActive) {
                controller?.let(::refresh)
                if (checkpoints.due(elapsed())) checkpoint(flush = false)
                delay(TICK_MS)
            }
        }
    }

    /**
     * Records the place reached now, unless it is only the replayed pre-roll, and
     * optionally sends what is outstanding. The time is taken before anything waits.
     */
    private fun checkpoint(flush: Boolean, chosen: Boolean = false): Job? {
        val observedAt = wallClock()
        val target = sink ?: return null
        val index = controller?.currentMediaItemIndex ?: 0
        val position = currentPosition()?.takeIf { chosen || heardSinceStopped() }?.takeIf(checkpoints::isActivity)
            ?.takeIf { it.assetId to it.millis() != lastRecorded }
        if (position != null) {
            checkpoints.checkpointed(elapsed())
            lastRecorded = position.assetId to position.millis()
        }
        // Stopped now: this was the last place heard until playback resumes.
        if (controller?.isPlaying != true) stillSinceStopped = true
        if (position == null && !flush) return null
        return scope.launch {
            position?.let { target.record(index, it.assetId, it.millis(), observedAt) }
            if (flush) target.flush()
        }
    }

    /** False once a stopped place is written, until playback resumes. */
    private fun heardSinceStopped(): Boolean = controller?.isPlaying == true || !stillSinceStopped

    private fun SavedPosition.millis(): Long = Math.round((positionSeconds ?: 0.0) * 1_000).coerceAtLeast(0)

    private fun currentPosition(): SavedPosition? {
        val player = controller ?: return null
        val assetId = player.currentMediaItem?.mediaId ?: return null
        return SavedPosition(assetId = assetId, positionSeconds = player.currentPosition.coerceAtLeast(0) / 1_000.0)
    }

    private fun classify(error: PlaybackException): PlaybackProblem {
        val http = generateSequence(error.cause) { it.cause }
            .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
            .firstOrNull()
        return when {
            http?.responseCode == 401 -> PlaybackProblem.SIGN_IN
            http != null -> PlaybackProblem.UNAVAILABLE
            error.errorCode in PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED..PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT ->
                PlaybackProblem.CONNECTION
            error.errorCode in PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED..PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ->
                PlaybackProblem.UNSUPPORTED
            else -> PlaybackProblem.CONNECTION
        }
    }

    companion object {
        /** On a narration item's metadata: the ebook it reads along, so the notification can reopen it. */
        const val EXTRA_READ_ALONG_PUBLICATION = "org.shelfarr.readAlongPublication"

        private const val TICK_MS = 500L

        /** How long our own rewind seek may take to be reported back. */
        private const val REWIND_ECHO_MS = 3_000L
    }
}

