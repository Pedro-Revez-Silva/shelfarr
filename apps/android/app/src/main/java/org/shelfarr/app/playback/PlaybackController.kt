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
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.ServerAddress

data class AudioChapter(val title: String?, val startMs: Long)

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
    private var sync: ProgressSync? = null
    private var ticker: Job? = null
    private var sleepTimer: Job? = null
    private val chapters = HashMap<String, List<AudioChapter>>()
    private val checkpoints = ListeningCheckpoints()

    /** Our own resume rewind, so its seek isn't mistaken for the listener's. */
    private var rewinding: Rewind? = null

    private data class Rewind(val index: Int, val positionMs: Long, val atElapsedMs: Long)

    private val state = MutableStateFlow(PlaybackSnapshot())
    val snapshot: StateFlow<PlaybackSnapshot> = state.asStateFlow()

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            refresh(player)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) {
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
                    checkpoint(flush = false)
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
        // Switching books: the one being left gets its last place first.
        if (this.sync != null && this.sync !== sync) checkpoint(flush = true)
        this.sync = sync
        chapters.clear()
        val index = tracks.indexOfFirst { it.id == start?.assetId }.coerceAtLeast(0)
        rewinding = null
        val positionMs = checkpoints.open(start?.takeIf { tracks[index].id == it.assetId }, tracks[index].id)
        state.update {
            PlaybackSnapshot(publication = publication, tracks = tracks, trackIndex = index, speed = it.speed, fromDevice = local != null)
        }
        player.setMediaItems(items, index, positionMs)
        player.prepare()
        player.play()
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
        checkpoint(flush = false)
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

    /** Moves to a place chosen after a conflict. */
    fun jumpTo(position: SavedPosition) {
        val index = state.value.tracks.indexOfFirst { it.id == position.assetId }
        if (index < 0) return
        deliberately { seekTo(index, ((position.positionSeconds ?: 0.0) * 1_000).toLong()) }
    }

    /**
     * Writes the current place now, without waiting for the next periodic checkpoint.
     * Call from the main thread, e.g. as the app goes to the background.
     */
    fun checkpointNow(): Job? = checkpoint(flush = false)

    /** Saves the final position, then stops and forgets the queue. */
    suspend fun stop() = withContext(Dispatchers.Main.immediate) {
        val observedAt = wallClock()
        val position = currentPosition()?.takeIf(checkpoints::isActivity)
        val target = sync
        sync = null
        sleepTimer?.cancel()
        ticker?.cancel()
        controller?.run {
            stop()
            clearMediaItems()
        }
        state.value = PlaybackSnapshot()
        if (target != null) {
            position?.let { target.update(it, observedAt) }
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
    private fun checkpoint(flush: Boolean): Job? {
        val observedAt = wallClock()
        val target = sync ?: return null
        val position = currentPosition()?.takeIf(checkpoints::isActivity)
        if (position != null) checkpoints.checkpointed(elapsed())
        if (position == null && !flush) return null
        return scope.launch {
            position?.let { target.update(it, observedAt) }
            if (flush) target.flush()
        }
    }

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

    private companion object {
        const val TICK_MS = 500L

        /** How long our own rewind seek may take to be reported back. */
        const val REWIND_ECHO_MS = 3_000L
    }
}

