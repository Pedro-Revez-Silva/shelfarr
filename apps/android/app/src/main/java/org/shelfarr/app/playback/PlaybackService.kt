package org.shelfarr.app.playback

import android.app.PendingIntent
import android.app.TaskStackBuilder
import android.content.Intent
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.metadata.Chapter
import androidx.media3.session.CacheBitmapLoader
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import org.shelfarr.app.R
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.reader.ReaderActivity
import org.shelfarr.app.ui.MainActivity

/**
 * Hosts the player so audio keeps going with the screen off, with lock-screen and
 * notification controls from Media3. Position reporting lives in [PlaybackController].
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private lateinit var open: PendingIntent
    private var openedBook: String? = null

    /** The reader for [publicationId], above the app's main screen so Back returns there. */
    private fun openBook(publicationId: String): PendingIntent =
        TaskStackBuilder.create(this)
            .addNextIntent(Intent(this, MainActivity::class.java))
            .addNextIntent(ReaderActivity.intent(this, publicationId))
            .getPendingIntent(publicationId.hashCode(), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            ?: open

    override fun onCreate() {
        super.onCreate()
        val container = (application as ShelfarrApplication).container
        val network = OkHttpDataSource.Factory(container.httpClient)
        // file:// for downloaded tracks, the scoped HTTP stack for everything else.
        val dataSource = DefaultDataSource.Factory(this, network)

        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(this).setDataSourceFactory(dataSource))
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setSeekBackIncrementMs(SEEK_BACK_MS)
            .setSeekForwardIncrementMs(SEEK_FORWARD_MS)
            .build()

        player.addListener(object : Player.Listener {
            override fun onTracksChanged(tracks: Tracks) {
                val assetId = player.currentMediaItem?.mediaId ?: return
                container.playback.onChaptersFound(assetId, chapters(tracks))
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // Read-along narration opens its book from the notification and lock screen.
                val book = mediaItem?.mediaMetadata?.extras?.getString(PlaybackController.EXTRA_READ_ALONG_PUBLICATION)
                if (book != openedBook) {
                    openedBook = book
                    session?.setSessionActivity(book?.let(::openBook) ?: open)
                }
            }
        })

        open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        session = MediaSession.Builder(this, player)
            .setSessionActivity(open)
            .setBitmapLoader(CacheBitmapLoader(DataSourceBitmapLoader.Builder(this).setDataSourceFactory(dataSource).build()))
            .setCallback(Callback)
            .build()

        setMediaNotificationProvider(
            DefaultMediaNotificationProvider.Builder(this).build().apply {
                setSmallIcon(R.drawable.ic_notification)
            },
        )
    }

    private fun chapters(tracks: Tracks): List<AudioChapter> {
        val found = LinkedHashMap<Long, AudioChapter>()
        for (group in tracks.groups) {
            for (index in 0 until group.length) {
                val metadata = group.getTrackFormat(index).metadata ?: continue
                for (entry in 0 until metadata.length()) {
                    val chapter = metadata.get(entry) as? Chapter ?: continue
                    found.getOrPut(chapter.startTimeMs) {
                        AudioChapter(chapter.title?.value?.takeIf(String::isNotBlank), chapter.startTimeMs)
                    }
                }
            }
        }
        return found.values.sortedBy { it.startMs }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        pauseAllPlayersAndStopSelf()
    }

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }

    private object Callback : MediaSession.Callback {
        // Controllers do not carry a URI across, so restore it from the request.
        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> {
            val restored = mediaItems.mapTo(ArrayList()) { item ->
                item.buildUpon().setUri(item.requestMetadata.mediaUri).build()
            }
            return Futures.immediateFuture(restored)
        }
    }

    companion object {
        const val SEEK_BACK_MS = 15_000L
        const val SEEK_FORWARD_MS = 30_000L
    }
}
