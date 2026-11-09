package org.shelfarr.app.reader

import android.net.Uri
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication as ReadiumPublication
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.mediatype.MediaType
import org.shelfarr.app.AccountServices
import org.shelfarr.app.core.ActivityTime
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.HeardPlaceMapper
import org.shelfarr.app.core.LocalProgress
import org.shelfarr.app.core.NarrationPlace
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadAlong
import org.shelfarr.app.core.ReadAlongFetch
import org.shelfarr.app.core.ReadAlongRefused
import org.shelfarr.app.core.ReadAlongSource
import org.shelfarr.app.core.ReadAlongSummary
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.SyncStatus
import org.shelfarr.app.playback.NarrationInfo
import org.shelfarr.app.playback.NarrationQueue
import org.shelfarr.app.playback.NarrationSource
import org.shelfarr.app.playback.NarrationStart
import org.shelfarr.app.playback.PlaybackController
import org.shelfarr.app.playback.ReadAlongSink

/** What the reading controls say about narration. Text-only books show nothing at all. */
sealed interface ReadAlongUi {
    /** No read-along, and nothing worth saying: the reader stays exactly as it was. */
    data object Off : ReadAlongUi

    /** Narration exists in some form but can't be used here. Shown only inside the reading controls. */
    data class Unavailable(val message: String) : ReadAlongUi

    data object Preparing : ReadAlongUi

    data class Ready(
        /** Where the narration comes from and how much of the text it covers. */
        val note: String,
        val playing: Boolean = false,
        val buffering: Boolean = false,
        /** Narration was used in this session, so the small pill stays while reading. */
        val started: Boolean = false,
        /** The reader moved away while it played: page-follow waits for "Back to the narration". */
        val browsing: Boolean = false,
        val follow: Boolean = true,
        val speed: Float = 1f,
        val offer: AudiobookOffer? = null,
        val problem: String? = null,
        val fromDevice: Boolean = false,
        val finished: Boolean = false,
    ) : ReadAlongUi
}

/** A later place heard in the paired audiobook on its own. Offered, never written into the ebook. */
data class AudiobookOffer(val title: String, val place: NarrationPlace)

/**
 * The parts of read-along that are pure decisions, kept apart so they can be tested
 * without a player or a WebView.
 */
internal object ReadAlongDecisions {
    /**
     * The audiobook's most recent known place: this device's unsynced one, or the server's,
     * by activity time. Equal or unknown times prefer what this device holds.
     */
    fun audiobookPlace(local: LocalProgress?, server: Progress?, now: Long): Pair<SavedPosition, Long?>? {
        val mine = local?.position?.let { it to local.observedAtEpochMs?.takeIf { time -> ActivityTime.isPlausible(time, now) } }
        val theirs = server?.takeIf { it.isUsable }?.let { SavedPosition.from(it) to it.observedAtEpochMs?.takeIf { time -> ActivityTime.isPlausible(time, now) } }
        return when {
            mine == null -> theirs
            theirs == null -> mine
            local.hasUnsyncedChanges && (mine.second ?: Long.MIN_VALUE) >= (theirs.second ?: Long.MIN_VALUE) -> mine
            (theirs.second ?: Long.MIN_VALUE) > (mine.second ?: Long.MIN_VALUE) -> theirs
            else -> mine
        }
    }

    /**
     * Offers the audiobook's place when it maps to a cue of this text and was heard after
     * the ebook's place, or when the ebook has no narration place at all. Never when they
     * already agree.
     */
    fun offer(ebook: NarrationPlace?, ebookObservedAt: Long?, audiobook: NarrationPlace?, audiobookObservedAt: Long?, now: Long): NarrationPlace? {
        audiobook ?: return null
        val ebookTime = ebookObservedAt?.takeIf { ActivityTime.isPlausible(it, now) }
        val audioTime = audiobookObservedAt?.takeIf { ActivityTime.isPlausible(it, now) }
        val later = audioTime != null && (ebookTime == null || audioTime > ebookTime)
        if (ebook != null && !later) return null
        if (ebook != null && ebook.cue == audiobook.cue) return null
        return audiobook
    }

    /** The cue to play for a page: the one the page shows, the next one in its document, or the next narrated document's first. */
    fun cueForPage(readAlong: ReadAlong, text: Int?, visible: String?, after: String?): Int {
        if (text != null) {
            visible?.let { readAlong.cueFor(text, it) }?.takeIf { it >= 0 }?.let { return it }
            after?.let { readAlong.cueFor(text, it) }?.takeIf { it >= 0 }?.let { return it }
            readAlong.firstCueAfter(text).takeIf { it >= 0 }?.let { return it }
        }
        return 0
    }
}

/** What the page on screen shows of the narration, from the WebView. */
data class PageCues(val href: String, val visible: String?, val after: String?)

/**
 * Read-along for one open EPUB (docs/read-along.md).
 *
 * It loads the manifest (this account's download when it is complete for the same
 * generation, otherwise the server's, streamed), maps its documents to the reader's own
 * links, and drives the highlight and page-follow from the narration actually playing in
 * the shared [PlaybackController]. Places are written only by [ReadAlongSink] from real
 * listening; nothing here moves the saved place.
 */
class ReadAlongCoordinator(
    private val scope: CoroutineScope,
    private val playback: PlaybackController,
    private val services: AccountServices,
    private val ebookSync: ProgressSync,
    private val settings: ReaderSettingsStore,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val mutableUi = MutableStateFlow<ReadAlongUi>(ReadAlongUi.Off)
    val ui: StateFlow<ReadAlongUi> = mutableUi.asStateFlow()

    private val mutableHighlight = MutableStateFlow<Locator?>(null)

    /** The element being heard (or where narration paused), for the reader to decorate. */
    val highlight: StateFlow<Locator?> = mutableHighlight.asStateFlow()

    private val mutableShow = MutableSharedFlow<ShowRequest>(extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Display-only moves: following the narration, or a place the reader asked to see. Never reading. */
    val show: SharedFlow<ShowRequest> = mutableShow.asSharedFlow()

    data class ShowRequest(val locator: Locator, val onlyIfHidden: Boolean)

    private class Session(
        val readAlong: ReadAlong,
        val mapper: HeardPlaceMapper,
        val links: List<org.readium.r2.shared.publication.Link>,
        val queue: NarrationQueue,
        val pairedTitle: String?,
        val paired: ProgressSync?,
    )

    private var session: Session? = null
    private var watcher: Job? = null

    /** The narration place restored with the page; exact only when it names this generation's offset. */
    private var start: NarrationPlace? = null

    /** The reader turned pages while narration was paused: the next Play starts from the page. */
    private var readSinceHeard = true
    private var shownCue = -2

    val isAvailable: Boolean get() = session != null

    /**
     * Prepares read-along for [asset] once the book is open at [opening]. Says nothing for a
     * plain EPUB, and never blocks reading.
     */
    suspend fun open(
        publication: Publication,
        asset: Asset,
        readium: ReadiumPublication,
        download: DownloadRecord?,
        offline: Boolean,
        opening: JsonObject?,
    ) {
        val summary = asset.readAlong ?: return
        if (!summary.isAvailable) {
            mutableUi.value = unavailableCopy(summary)?.let(ReadAlongUi::Unavailable) ?: ReadAlongUi.Off
            return
        }
        mutableUi.value = ReadAlongUi.Preparing
        val local = download?.let(services.downloads::narrationFor)
        val server = services.session.server
        val readAlong = try {
            when {
                local != null && (offline || local.generation == summary.generation) -> readLocal(local.manifest, asset.id, local.generation)
                offline -> return unavailable(
                    "Narration plays with a connection. Download this book with its narration to read along offline.",
                )
                else -> when (val fetched = services.api.readAlong(server, requireNotNull(summary.manifestUrl), asset.id, summary.generation)) {
                    is ReadAlongFetch.Available -> fetched.readAlong
                    is ReadAlongFetch.Unavailable -> return unavailable(
                        fetched.message ?: "This book's narration isn't available right now. Reading works as usual.",
                    )
                    is ReadAlongFetch.Refused -> return unavailable("${fetched.message} Reading works as usual.")
                }
            }
        } catch (error: ReadAlongRefused) {
            return unavailable("${error.message} Reading works as usual.")
        } catch (error: ApiException) {
            return unavailable(
                when (error) {
                    is ApiException.Unauthorized -> "Sign in again to play this book's narration. Reading works as usual."
                    is ApiException.Offline -> "The narration couldn't be loaded. Check the connection and open the book again."
                    else -> "The narration couldn't be loaded from your server. Reading works as usual."
                },
            )
        }
        val usesLocal = local != null && local.generation == readAlong.generation

        // Every narrated document must be one the reader actually has.
        val readingOrder = readium.readingOrder
        val paths = readingOrder.map { HeardPlaceMapper.decodePath(it.url().toString()) }
        val links = readAlong.texts.map { href ->
            paths.indexOf(href).takeIf { it >= 0 }?.let(readingOrder::get)
                ?: return unavailable("This book's narration names text the reader can't find in this edition. Reading works as usual.")
        }
        val hrefs = links.map { it.url().toString() }
        val progressions = links.map { link -> readingOrder.indexOf(link).toDouble() / readingOrder.size.coerceAtLeast(1) }
        val mapper = HeardPlaceMapper(readAlong, hrefs, progressions)

        val pairedId = readAlong.pairedPublicationId
        // Nothing is written for the audiobook until narration is actually played.
        val paired = pairedId?.let(services.progress::sync)
        val info = NarrationInfo(publication.id, readAlong.generation)
        val key = readAlong.generation.take(12)
        val sources = readAlong.tracks.map { track ->
            val uri = if (usesLocal) {
                Uri.fromFile(requireNotNull(local).tracks[track.index]).toString()
            } else {
                server.resolve(track.url)?.takeIf(server::contains)?.toString() ?: return unavailable(
                    "This book's narration names files on another server. Reading works as usual.",
                )
            }
            NarrationSource("narration:$key:${track.index}", uri, track.label)
        }
        val cover = publication.coverUrl?.let(server::resolve)?.takeIf(server::contains)?.toString()
        val queue = NarrationQueue(
            publication = publication,
            info = info,
            sources = sources,
            sink = ReadAlongSink(mapper, ebookSync, paired),
            fromDevice = usesLocal,
            coverUri = cover,
        )
        val pairedTitle = summary.audiobook?.title
        session = Session(readAlong, mapper, links, queue, pairedTitle, paired)

        start = readAlong.placeFromLocator(opening, mapper::textIndexOf)
        val attached = playback.isNarrating(info)
        // An exact narration place resumes; a reading place starts from the page shown.
        readSinceHeard = !attached && start?.exact != true

        val source = when (readAlong.source) {
            ReadAlongSource.MEDIA_OVERLAY -> "Narration from this book."
            ReadAlongSource.IMPORTED -> "Narrated by “${pairedTitle ?: "the audiobook"}”, aligned to this edition."
        }
        val note = listOfNotNull(
            source,
            readAlong.coverage.describe(),
            "Playing from this device.".takeIf { usesLocal },
        ).joinToString(" ")
        val current = settings.settings.value
        mutableUi.value = ReadAlongUi.Ready(
            note = note,
            started = attached,
            follow = current.followNarration,
            speed = current.narrationSpeed,
            fromDevice = usesLocal,
        )
        watch()
        // Paused narration of this book may still be loaded: a later audiobook place is offered then too.
        if (readAlong.source == ReadAlongSource.IMPORTED && !(attached && playback.isListening) && pairedId != null && paired != null) {
            offerAudiobookPlace(readAlong, pairedId, paired, offline)
        }
    }

    private suspend fun readLocal(manifest: File, assetId: String, generation: String): ReadAlong = withContext(Dispatchers.IO) {
        try {
            manifest.inputStream().use { ReadAlong.read(it, assetId, generation, services.session.server) }
        } catch (error: IOException) {
            throw ReadAlongRefused(ReadAlongRefused.Kind.INVALID, "The narration on this device couldn't be read.")
        }
    }

    private fun unavailable(message: String) {
        mutableUi.value = ReadAlongUi.Unavailable(message)
    }

    private fun unavailableCopy(summary: ReadAlongSummary): String? = when (summary.status) {
        ReadAlongSummary.UNALIGNED -> summary.audiobook?.title?.let {
            "“$it” isn't aligned with this text, so read-along isn't available. You can listen to it on its own."
        }
        ReadAlongSummary.STALE, ReadAlongSummary.INVALID ->
            "${summary.reason ?: "This book's narration data can't be used."} Reading works as usual."
        else -> null
    }

    private suspend fun offerAudiobookPlace(readAlong: ReadAlong, pairedId: String, paired: ProgressSync, offline: Boolean) {
        val local = paired.snapshot()
        val remote = if (offline) {
            null
        } else {
            try {
                services.api.progress(services.session.server, pairedId)
            } catch (_: ApiException) {
                null
            }
        }
        val clock = now()
        val (position, observedAt) = ReadAlongDecisions.audiobookPlace(local, remote, clock) ?: return
        val heard = readAlong.placeFromAudio(position.assetId, position.positionSeconds) ?: return
        val offered = ReadAlongDecisions.offer(start, ebookSync.snapshot().observedAtEpochMs, heard, observedAt, clock) ?: return
        val title = session?.pairedTitle ?: "the audiobook"
        updateReady { if (it.playing) it else it.copy(offer = AudiobookOffer(title, offered)) }
    }

    /** True when the next Play has to know which narration the page on screen shows. */
    val needsPageCues: Boolean
        get() {
            val info = session?.queue?.info ?: return false
            if (playback.isNarrating(info) && playback.isListening) return false
            return readSinceHeard || start == null || playback.snapshot.value.let { it.narration == info && it.ended }
        }

    /** The narrated fragments of [href], in document order, for finding what the page shows. */
    fun fragmentsOf(href: String): List<String> {
        val current = session ?: return emptyList()
        val text = current.mapper.textIndexOf(href) ?: return emptyList()
        return current.readAlong.cuesOf(text).map(current.readAlong::fragmentOf).distinct()
    }

    /**
     * Play or pause. A paused narration resumes where it was (rewinding once), unless the
     * reader has turned pages since, or never heard any: then it plays from the cue on the
     * page on screen, exactly there.
     */
    fun toggle(page: PageCues?) {
        // A place being adopted is put in place first; Play never races it.
        restoring?.let { pending ->
            scope.launch {
                pending.await()
                toggleNow(page)
            }
            return
        }
        toggleNow(page)
    }

    private var restoring: CompletableDeferred<Unit>? = null

    /** A place is about to be adopted (for example "Use other device"): Play waits for [restoredTo] or [restoreAbandoned]. */
    fun restoreStarting() {
        if (restoring == null) restoring = CompletableDeferred()
    }

    /** Nothing was adopted after all. */
    fun restoreAbandoned() {
        restoring?.complete(Unit)
        restoring = null
    }

    private fun toggleNow(page: PageCues?) {
        val current = session ?: return
        val info = current.queue.info
        val narrating = playback.isNarrating(info)
        if (narrating && playback.isListening) {
            playback.pause()
            return
        }
        val ended = narrating && playback.snapshot.value.ended
        val fromPage = readSinceHeard || ended || (start == null && !narrating)
        val cue = if (fromPage) {
            val text = page?.let { current.mapper.textIndexOf(it.href) }
            ReadAlongDecisions.cueForPage(current.readAlong, text, page?.visible, page?.after)
        } else {
            -1
        }
        val place = start
        when {
            narrating && cue >= 0 -> playback.playNarrationAt(current.readAlong.trackOf(cue), current.readAlong.beginOf(cue))
            narrating -> playback.togglePlay()
            else -> scope.launch {
                current.paired?.knowAssets(current.readAlong.tracks.mapNotNull { it.assetId })
                val begin = if (cue >= 0 || place == null) {
                    val chosen = cue.coerceAtLeast(0)
                    NarrationStart(current.readAlong.trackOf(chosen), current.readAlong.beginOf(chosen), resume = false)
                } else {
                    NarrationStart(place.track, place.offsetMs, resume = place.exact)
                }
                playback.loadNarration(current.queue, begin, settings.settings.value.narrationSpeed)
            }
        }
        readSinceHeard = false
        updateReady { it.copy(started = true, browsing = false, offer = null, finished = false) }
    }

    fun skip(back: Boolean) {
        val info = session?.queue?.info ?: return
        if (!playback.isNarrating(info)) return
        if (back) playback.skipBack() else playback.skipForward()
        readSinceHeard = false
    }

    fun setSpeed(speed: Float) {
        settings.update { it.copy(narrationSpeed = speed) }
        val info = session?.queue?.info
        if (info != null && playback.isNarrating(info)) playback.setSpeed(speed)
        updateReady { it.copy(speed = speed) }
    }

    fun setFollow(follow: Boolean) {
        settings.update { it.copy(followNarration = follow) }
        updateReady { it.copy(follow = follow, browsing = false) }
        if (follow) backToNarration()
    }

    /** Shows the narration being heard again after browsing, and resumes page-follow. */
    fun backToNarration() {
        val current = session ?: return
        updateReady { it.copy(browsing = false) }
        val point = playback.heardNow() ?: return
        val cue = current.readAlong.cueReached(point.track, point.offsetMs).takeIf { it >= 0 } ?: return
        mutableShow.tryEmit(ShowRequest(locatorFor(current, cue), onlyIfHidden = true))
    }

    /** Goes to the audiobook's later place: shown and ready to resume, still not activity. */
    fun useOffer() {
        val current = session ?: return
        val offer = (mutableUi.value as? ReadAlongUi.Ready)?.offer ?: return
        adopt(current, offer.place)
        updateReady { it.copy(offer = null) }
        mutableShow.tryEmit(ShowRequest(locatorFor(current, offer.place.cue), onlyIfHidden = false))
    }

    /**
     * Makes [place] where the narration goes on from. When this book's narration is already
     * loaded, the player itself is moved there as a restoration (not listening), so the next
     * Play, in the app or from the lock screen or a headset, resumes there with the one rewind,
     * and the place keeps its own activity time until playback passes it.
     */
    private fun adopt(current: Session, place: NarrationPlace?) {
        start = place
        readSinceHeard = place?.exact != true
        if (place != null && playback.isNarrating(current.queue.info)) {
            playback.restore(place.track, place.offsetMs)
            // The player now holds the adopted place; Play resumes it rather than the page.
            readSinceHeard = false
            shownCue = -2
        }
    }

    fun dismissOffer() = updateReady { it.copy(offer = null) }

    /**
     * The reader's view moved without us moving it. While narration plays that is browsing
     * (nothing is written); while paused, [onRead] records it as reading by the caller.
     */
    fun onUserMoved() {
        val info = session?.queue?.info ?: return
        if (playback.isNarrating(info) && playback.isListening) {
            updateReady { if (it.follow) it.copy(browsing = true) else it }
        }
    }

    /** A normal reading place was written while narration was paused or never started. */
    fun onRead() {
        if (session != null) readSinceHeard = true
    }

    /** True while this book's narration is playing: page turns are browsing, never reading. */
    val isPlayingHere: Boolean
        get() = session?.queue?.info?.let { playback.isNarrating(it) && playback.isListening } == true

    /** A remote or chosen place was adopted for the text: narration goes on from there, loaded or not. */
    fun restoredTo(locator: JsonObject?) {
        session?.let { current -> adopt(current, current.readAlong.placeFromLocator(locator, current.mapper::textIndexOf)) }
        restoreAbandoned()
    }

    private fun watch() {
        watcher?.cancel()
        watcher = scope.launch {
            while (isActive) {
                delay(tick())
            }
        }
    }

    /** Follows the narration once; returns how long until it can next change. */
    private fun tick(): Long {
        val current = session ?: return IDLE_MS
        val info = current.queue.info
        val snapshot = playback.snapshot.value
        if (snapshot.narration != info) {
            if (shownCue != -1) {
                shownCue = -1
                mutableHighlight.value = null
            }
            updateReady { it.copy(playing = false, buffering = false) }
            return IDLE_MS
        }
        val point = playback.heardNow()
        val playing = playback.isListening
        val readAlong = current.readAlong
        val cue = point?.let { readAlong.cueAt(it.track, it.offsetMs) } ?: -1
        // Between cues nothing is highlighted while playing; paused, the place it stopped stays marked.
        val shown = when {
            cue >= 0 -> cue
            !playing && point != null -> readAlong.cueReached(point.track, point.offsetMs)
            else -> -1
        }
        if (shown != shownCue) {
            shownCue = shown
            mutableHighlight.value = if (shown >= 0) locatorFor(current, shown) else null
            val ready = mutableUi.value as? ReadAlongUi.Ready
            if (playing && cue >= 0 && ready != null && ready.follow && !ready.browsing) {
                mutableShow.tryEmit(ShowRequest(locatorFor(current, cue), onlyIfHidden = true))
            }
        }
        val problem = snapshot.problem?.let { "The narration couldn't be played. Check the connection or sign in again, then press Play." }
        val pairedConflict = (current.paired?.status?.value as? SyncStatus.Conflict)?.let {
            "“${current.pairedTitle ?: "The audiobook"}” has a different place on another device. Open the audiobook to choose which to keep."
        }
        updateReady {
            it.copy(
                playing = snapshot.isPlaying || (playing && !snapshot.isBuffering),
                buffering = snapshot.isBuffering && playing,
                started = true,
                problem = problem ?: pairedConflict,
                finished = snapshot.ended,
                speed = snapshot.speed,
            )
        }
        // Only narration actually heard makes it the newest activity again.
        if (snapshot.isPlaying && point != null) readSinceHeard = false
        if (!playing || point == null) return IDLE_MS
        val boundary = readAlong.nextBoundary(point.track, point.offsetMs) ?: return FRAME_MAX_MS
        val speed = snapshot.speed.coerceAtLeast(0.25f)
        return ((boundary - point.offsetMs) / speed).toLong().coerceIn(FRAME_MIN_MS, FRAME_MAX_MS)
    }

    /** A Readium locator for a cue's element, which its navigator scrolls to and decorates by ID. */
    private fun locatorFor(current: Session, cue: Int): Locator {
        val link = current.links[current.readAlong.textOf(cue)]
        val href = Url(link.url().toString()) ?: link.url()
        return Locator(
            href = href,
            mediaType = link.mediaType ?: MediaType.XHTML,
            locations = Locator.Locations(fragments = listOf(current.readAlong.fragmentOf(cue))),
        )
    }

    private inline fun updateReady(transform: (ReadAlongUi.Ready) -> ReadAlongUi.Ready) {
        val ready = mutableUi.value as? ReadAlongUi.Ready ?: return
        val updated = transform(ready)
        if (updated != ready) mutableUi.value = updated
    }

    /** Stops following. Narration itself carries on in the background service. */
    fun close() {
        watcher?.cancel()
        watcher = null
    }

    private companion object {
        const val IDLE_MS = 400L
        const val FRAME_MIN_MS = 30L
        const val FRAME_MAX_MS = 200L
    }
}
