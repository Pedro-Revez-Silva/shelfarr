package org.shelfarr.app.playback

import android.content.ComponentName
import android.content.Context
import android.net.Uri
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
 */
class PlaybackController(
    private val context: Context,
    private val scope: CoroutineScope,
) {
    private var controller: MediaController? = null
    private var sync: ProgressSync? = null
    private var ticker: Job? = null
    private var sleepTimer: Job? = null
    private val chapters = HashMap<String, List<AudioChapter>>()

    private val state = MutableStateFlow(PlaybackSnapshot())
    val snapshot: StateFlow<PlaybackSnapshot> = state.asStateFlow()

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            refresh(player)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) startTicker() else saveAndFlush()
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            recordPosition()
        }

        override fun onPlayerError(error: PlaybackException) {
            state.update { it.copy(problem = classify(error), isPlaying = false, isBuffering = false) }
            saveAndFlush()
        }
    }

    /** Queues a publication and starts it from [start], or the beginning. */
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
        this.sync = sync
        chapters.clear()
        val index = tracks.indexOfFirst { it.id == start?.assetId }.coerceAtLeast(0)
        val positionMs = ((start?.positionSeconds ?: 0.0) * 1_000).toLong().coerceAtLeast(0)
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

    private suspend fun connected(): MediaController {
        controller?.takeIf { it.isConnected }?.let { return it }
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
        connected.addListener(listener)
        controller = connected
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

    fun seekTo(positionMs: Long) {
        controller?.seekTo(positionMs)
        recordPosition()
    }

    fun skipBack() {
        controller?.seekBack()
    }

    fun skipForward() {
        controller?.seekForward()
    }

    fun playTrack(index: Int) {
        val player = controller ?: return
        player.seekTo(index, 0)
        player.play()
    }

    fun playChapter(chapter: AudioChapter) {
        val player = controller ?: return
        player.seekTo(chapter.startMs)
        player.play()
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
        val player = controller ?: return
        val index = state.value.tracks.indexOfFirst { it.id == position.assetId }
        if (index < 0) return
        player.seekTo(index, ((position.positionSeconds ?: 0.0) * 1_000).toLong())
    }

    /** Saves the final position, then stops and forgets the queue. */
    suspend fun stop() = withContext(Dispatchers.Main.immediate) {
        val position = currentPosition()
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
            position?.let { target.update(it) }
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
                if (++ticks % TICKS_PER_SAVE == 0) recordPosition()
                delay(TICK_MS)
            }
        }
    }

    private var ticks = 0

    private fun recordPosition() {
        val position = currentPosition() ?: return
        val target = sync ?: return
        scope.launch { target.update(position) }
    }

    private fun saveAndFlush() {
        ticker?.cancel()
        val position = currentPosition()
        val target = sync ?: return
        scope.launch {
            position?.let { target.update(it) }
            target.flush()
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
        const val TICKS_PER_SAVE = 10
    }
}

