package org.shelfarr.app.reader

import android.app.Application
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.json.JSONObject
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication as ReadiumPublication
import org.readium.r2.shared.publication.services.locateProgression
import org.readium.r2.shared.publication.services.positions
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.mediatype.MediaType
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.ComicArchive
import org.shelfarr.app.core.ComicPage
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.FormatChoice
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.core.ResumeDecision
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.SyncStatus
import org.shelfarr.app.core.UnreadableFile
import org.shelfarr.app.core.validate
import org.shelfarr.app.reader.pages.ComicPages
import org.shelfarr.app.reader.pages.InvalidPlace
import org.shelfarr.app.reader.pages.PageBitmapCache
import org.shelfarr.app.reader.pages.PageCommand
import org.shelfarr.app.reader.pages.PageDocument
import org.shelfarr.app.reader.pages.PageLocators
import org.shelfarr.app.reader.pages.PageProgress
import org.shelfarr.app.reader.pages.PageRestore
import org.shelfarr.app.reader.pages.PdfPages

/** One entry of the flattened table of contents. */
data class ContentsEntry(val title: String, val link: Link, val depth: Int)

sealed interface ReaderState {
    data class Preparing(val fraction: Float?) : ReaderState

    /** This device and another disagree. The reader picks before anything opens. */
    data class ChooseResume(val local: SavedPosition, val server: Progress) : ReaderState

    /** Several formats and no saved place or download to go by: the reader picks one. */
    data class ChooseFormat(val title: String, val options: List<Asset>) : ReaderState

    data class Ready(
        val title: String,
        val publication: ReadiumPublication,
        val navigatorFactory: EpubNavigatorFactory,
        val initialLocator: Locator?,
        val contents: List<ContentsEntry>,
        val positionCount: Int,
        val notice: String?,
    ) : ReaderState

    /** A PDF or comic, open at [initialPage] (0-based). */
    data class Paged(
        val title: String,
        val format: ReadingFormat,
        val pageCount: Int,
        val initialPage: Int,
        val notice: String?,
        /** Set while a saved place this file can't show waits for the reader's choice. */
        val invalidPlace: InvalidPlace? = null,
    ) : ReaderState

    data class Failed(val error: Throwable) : ReaderState

    /** Readium could not open the file, or it uses DRM we cannot read. */
    data object Unreadable : ReaderState

    /** A PDF or comic that is damaged, protected or unsafe, with the reason. */
    data class Damaged(val message: String) : ReaderState
}

/** Where the open file came from, for tests and diagnostics. */
enum class ReaderSource { DOWNLOAD, CACHE }

data class ReadingPlace(
    val fraction: Float = 0f,
    val position: Int? = null,
    val chapter: String? = null,
)

/** A resume decided before its format was known, held while the reader picks one. */
private data class Start(val position: SavedPosition?, val baseVersion: Int, val observedAtEpochMs: Long?)

@OptIn(ExperimentalReadiumApi::class)
class ReaderViewModel(application: Application, private val publicationId: String) : AndroidViewModel(application) {
    private val container = (application as ShelfarrApplication).container
    private val account = container.currentAccount()

    private val mutableState = MutableStateFlow<ReaderState>(ReaderState.Preparing(null))
    val state: StateFlow<ReaderState> = mutableState.asStateFlow()

    private val mutablePlace = MutableStateFlow(ReadingPlace())
    val place: StateFlow<ReadingPlace> = mutablePlace.asStateFlow()

    /** A PDF or comic's place: the page on screen, kept apart from the last page actually seen. */
    private val pageProgress = PageProgress()

    /** The page a PDF or comic is on (0-based), drawn or not. */
    val page: StateFlow<Int> = pageProgress.page

    val pageCommands: SharedFlow<PageCommand> = pageProgress.commands

    val settings get() = container.readerSettings.settings
    val serverHost: String? get() = account?.session?.server?.host

    private val sync: ProgressSync? = account?.progress?.sync(publicationId)
    val syncStatus: StateFlow<SyncStatus> = sync?.status ?: MutableStateFlow(SyncStatus.Idle)

    /** Read-along narration for this book, when the server has a real alignment for the open EPUB. */
    private val readAlong: ReadAlongCoordinator? = account?.let { services ->
        sync?.let { ReadAlongCoordinator(viewModelScope, container.playback, services, it, container.readerSettings) }
    }
    val readAlongUi: StateFlow<ReadAlongUi> = readAlong?.ui ?: MutableStateFlow(ReadAlongUi.Off)
    val narrationHighlight: StateFlow<Locator?> = readAlong?.highlight ?: MutableStateFlow(null)
    val narrationShow: SharedFlow<ReadAlongCoordinator.ShowRequest> =
        readAlong?.show ?: kotlinx.coroutines.flow.MutableSharedFlow()

    /** A display-only move the reader is about to make: its reports are not reading. */
    private var displayHref: String? = null
    private var displayAtMs = Long.MIN_VALUE / 2
    private var layoutAtMs = Long.MIN_VALUE / 2

    private var asset: Asset? = null
    private var details: Publication? = null
    private var download: DownloadRecord? = null
    private var offline = false
    private var opened: ReadiumPublication? = null
    private var document: PageDocument? = null
    private var comicPages: List<ComicPage> = emptyList()
    private val bitmaps = PageBitmapCache.forRuntime()
    private var notice: String? = null
    private var pendingStart: Start? = null

    /** Which copy is open: a managed download or the evictable cache. */
    @Volatile
    var fileSource: ReaderSource? = null
        private set

    /** The format that is open, once one is. */
    val openFormat: ReadingFormat? get() = asset?.readingFormat

    init {
        open()
    }

    fun open() {
        val services = account ?: run {
            mutableState.value = ReaderState.Failed(ApiException.Unauthorized())
            return
        }
        mutableState.value = ReaderState.Preparing(null)
        guarded {
            offline = false
            notice = null
            val online = try {
                services.publication(publicationId)
            } catch (error: ApiException.Offline) {
                // Only a lost connection falls back. An untrusted certificate is surfaced.
                if (error.certificate) throw error
                offline = true
                null
            }
            val ready = services.downloads.find(publicationId)?.takeIf { it.isReady }
            // A download pins one edition. Online, it is used only while it is still the server's edition.
            download = ready?.takeIf { online == null || it.matches(online) }
            val publication = when {
                online != null -> online
                ready != null -> ready.publication
                else -> services.recall(publicationId) ?: throw ApiException.Offline()
            }
            details = publication
            if (publication.readingAssets.isEmpty()) {
                mutableState.value = ReaderState.Unreadable
                return@guarded
            }

            // The saved place decides the format, so this is settled before any file is fetched.
            val local = sync?.snapshot()
            when (val decision = ResumeDecision.decide(publication, publication.progress, local, offline = offline)) {
                ResumeDecision.Beginning -> proceed(Start(null, 0, null))
                is ResumeDecision.Continue -> proceed(Start(decision.position, decision.baseVersion, decision.observedAtEpochMs))
                is ResumeDecision.Choose -> mutableState.value = ReaderState.ChooseResume(decision.local, decision.server)
                is ResumeDecision.EditionChanged -> {
                    notice = "This book's file was replaced, so your old place doesn't apply. Starting from the beginning."
                    proceed(Start(null, decision.staleVersion, null))
                }
            }
        }
    }

    fun chooseResume(keepLocal: Boolean) {
        val choice = mutableState.value as? ReaderState.ChooseResume ?: return
        mutableState.value = ReaderState.Preparing(null)
        guarded {
            val position = if (keepLocal) choice.local else SavedPosition.from(choice.server)
            sync?.chooseAtOpen(position, choice.server, keepLocal)
            proceed(Start(position, choice.server.version, null))
        }
    }

    /** The reader's explicit format choice. Nothing is saved until they turn a page. */
    fun chooseFormat(assetId: String) {
        val start = pendingStart ?: return
        val chosen = details?.readingAssets?.firstOrNull { it.id == assetId } ?: return
        pendingStart = null
        mutableState.value = ReaderState.Preparing(null)
        guarded { load(chosen, start) }
    }

    private suspend fun proceed(start: Start) {
        val publication = details ?: return
        when (val choice = FormatChoice.decide(publication, start.position, download?.pinnedAssetIds?.singleOrNull())) {
            FormatChoice.None -> mutableState.value = ReaderState.Unreadable
            is FormatChoice.Ask -> {
                pendingStart = start
                mutableState.value = ReaderState.ChooseFormat(publication.title, choice.options)
            }
            is FormatChoice.Use -> load(choice.asset, start)
        }
    }

    private suspend fun load(chosen: Asset, start: Start) {
        val services = account ?: return
        val session = services.session
        val format = chosen.readingFormat ?: run {
            mutableState.value = ReaderState.Unreadable
            return
        }
        asset = chosen
        val record = download
        val downloaded = record?.let { services.downloads.fileFor(it, chosen.id) }
        val file: java.io.File
        var order = if (downloaded != null && format == ReadingFormat.CBZ) {
            record?.let { services.downloads.readingOrderFor(it, chosen.id) }
                ?: throw UnreadableFile("The downloaded comic is missing its page list. Remove the download and download it again.")
        } else {
            null
        }
        if (downloaded != null) {
            mutableState.value = ReaderState.Preparing(1f)
            if (offline) notice = "Reading the download on this device. Your place will sync when you're back online."
            file = downloaded
        } else {
            val cached = container.epubCache.obtain(session.accountKey, session.server, chosen) { fraction ->
                mutableState.value = ReaderState.Preparing(fraction)
            }
            if (cached.unverified) notice = "Reading the copy on this device. Your place will sync when you're back online."
            file = cached.file
            order = cached.order
        }
        fileSource = if (downloaded != null) ReaderSource.DOWNLOAD else ReaderSource.CACHE

        when (format) {
            ReadingFormat.EPUB -> {
                // Only an EPUB ever reaches Readium's EPUB parser and navigator.
                val readium = openWithReadium(file) ?: run {
                    mutableState.value = ReaderState.Unreadable
                    return
                }
                opened = readium
                ready(start.position, start.baseVersion, start.observedAtEpochMs)
            }
            ReadingFormat.PDF -> {
                val pdf = withContext(Dispatchers.IO) { PdfPages.open(file) }
                document = pdf
                paged(format, pdf, start)
            }
            ReadingFormat.CBZ -> {
                val pages = (order ?: throw UnreadableFile("This comic's page list is missing")).validate(chosen)
                val archive = withContext(Dispatchers.IO) { ComicArchive.open(file, pages, chosen.sizeBytes) }
                comicPages = pages
                val comic = ComicPages(archive)
                document = comic
                paged(format, comic, start)
            }
        }
    }

    private suspend fun openWithReadium(file: java.io.File): ReadiumPublication? {
        val http = DefaultHttpClient()
        val context = getApplication<Application>()
        val retriever = AssetRetriever(context.contentResolver, http)
        val opener = PublicationOpener(DefaultPublicationParser(context, http, retriever, pdfFactory = null))
        val readiumAsset = retriever.retrieve(file, MediaType.EPUB).getOrElse { return null }
        // No content protections are registered, so DRM-protected files fail here.
        return opener.open(readiumAsset, allowUserInteraction = false).getOrElse { return null }
    }

    private suspend fun ready(start: SavedPosition?, baseVersion: Int, observedAtEpochMs: Long? = null) {
        val publication = opened ?: return
        sync?.begin(start, baseVersion, observedAtEpochMs, details?.playableAssets?.map { it.id })
        restoration = ReadingRestoration(start?.locator)
        val locator = start?.locator?.let { json ->
            Locator.fromJSON(JSONObject(json.toString()))
        }
        val positions = publication.positions()
        val openAsset = asset
        val book = details
        if (readAlong != null && openAsset != null && book != null) {
            // Never in the way of reading: the text is shown whatever narration turns out to be.
            viewModelScope.launch {
                readAlong.open(book, openAsset, publication, download, offline, start?.locator)
            }
        }
        mutableState.value = ReaderState.Ready(
            title = details?.title ?: publication.metadata.title.orEmpty(),
            publication = publication,
            navigatorFactory = EpubNavigatorFactory(publication),
            initialLocator = locator,
            contents = flatten(publication.tableOfContents, 0),
            positionCount = positions.size,
            notice = notice,
        )
    }

    /**
     * Shows a PDF or comic at its saved page. Restoring is not reading: the session is
     * anchored on the saved place, and only a later, different page is written. A place
     * this file can't show stays saved and waits for the reader's choice.
     */
    private suspend fun paged(format: ReadingFormat, document: PageDocument, start: Start) {
        sync?.begin(start.position, start.baseVersion, start.observedAtEpochMs, details?.playableAssets?.map { it.id })
        val restore = when (format) {
            ReadingFormat.PDF -> PageLocators.restorePdf(start.position?.locator, document.pageCount)
            else -> PageLocators.restoreComic(start.position?.locator, comicPages)
        }
        val (index, invalid) = when (restore) {
            PageRestore.Beginning -> 0 to null
            is PageRestore.At -> restore.index to null
            is PageRestore.Invalid -> 0 to InvalidPlace(restore.saved, document.pageCount)
        }
        pageProgress.open(document.pageCount, index, ::recordPage)
        mutableState.value = ReaderState.Paged(
            title = details?.title.orEmpty(),
            format = format,
            pageCount = document.pageCount,
            initialPage = index,
            notice = notice,
            invalidPlace = invalid,
        )
    }

    /** Draws a page, reusing recent bitmaps. Runs on the document's own worker. */
    suspend fun renderPage(index: Int, width: Int, height: Int): Bitmap {
        val pages = document ?: throw UnreadableFile("This book was closed")
        val key = "$index@${width}x$height"
        bitmaps.get(key)?.let { return it }
        return pages.render(index, width, height).also { bitmaps.put(key, it) }
    }

    /** The pager came to rest on [index], drawn or not. Turning continues from there; nothing is saved. */
    fun onPageSettled(index: Int) {
        if (mutableState.value !is ReaderState.Paged) return
        pageProgress.onSettled(index)
    }

    /**
     * The settled page [index] was drawn, first seen at [observedAtEpochMs]. A page other
     * than the last one seen is the reader turning pages and is written with that time.
     * The same page again (opening, rotation, zoom, re-layout) is not.
     */
    fun onPageShown(index: Int, observedAtEpochMs: Long) {
        if (mutableState.value !is ReaderState.Paged) return
        pageProgress.onShown(index, observedAtEpochMs)
    }

    private fun recordPage(index: Int, observedAtEpochMs: Long) {
        val paged = mutableState.value as? ReaderState.Paged ?: return
        if (paged.invalidPlace != null) mutableState.value = paged.copy(invalidPlace = null)
        val opened = asset ?: return
        val locator = if (paged.format == ReadingFormat.PDF) {
            PageLocators.pdf(index, paged.pageCount)
        } else {
            PageLocators.comic(comicPages[index], paged.pageCount)
        }
        viewModelScope.launch { sync?.update(SavedPosition(opened.id, locator), observedAtEpochMs) }
    }

    /** A page turn from the keyboard or chrome, from the page on screen. It is saved once seen there. */
    fun turnPage(delta: Int) {
        if (mutableState.value !is ReaderState.Paged) return
        pageProgress.turn(delta)
    }

    /** The reader's answer to a saved place this file can't show. Looking is not reading. */
    fun resolveInvalidPlace(index: Int) {
        val paged = mutableState.value as? ReaderState.Paged ?: return
        val target = index.coerceIn(0, paged.pageCount - 1)
        mutableState.value = paged.copy(invalidPlace = null, initialPage = target)
        pageProgress.goToSaved(target)
    }

    private fun flatten(links: List<Link>, depth: Int): List<ContentsEntry> = links.flatMap { link ->
        listOf(ContentsEntry(link.title?.takeIf(String::isNotBlank) ?: "Untitled", link, depth)) +
            flatten(link.children, depth + 1)
    }

    /**
     * The place this session opened at, until the reader moves away from it. Readium
     * reports the restored locator after opening; that is not new reading.
     */
    private var restoration = ReadingRestoration(null)

    fun onLocatorChanged(locator: Locator) {
        // Captured before anything waits: this is when the page was reached.
        val observedAt = System.currentTimeMillis()
        val atMs = SystemClock.elapsedRealtime()
        val total = locator.locations.totalProgression ?: locator.locations.progression ?: 0.0
        mutablePlace.update {
            ReadingPlace(
                fraction = total.toFloat(),
                position = locator.locations.position,
                chapter = locator.title ?: it.chapter,
            )
        }
        val id = asset?.id ?: return
        val json = Json.parseToJsonElement(locator.toJSON().toString()) as JsonObject
        val echo = isDisplayEcho(json, atMs)
        when {
            // While narration plays, the place heard is the activity: turning pages is browsing.
            readAlong?.isPlayingHere == true -> {
                // The opened page laid out only after Play: restoring it is not browsing either.
                val opening = restoration.isOpening(json)
                restoration.adopt(json)
                if (!echo && !opening) readAlong.onUserMoved()
                return
            }
            // Following narration, showing a chosen place, or a re-layout: on screen, not read.
            echo || atMs - layoutAtMs < LAYOUT_SETTLE_MS -> {
                restoration.adopt(json)
                return
            }
        }
        if (!restoration.isReading(json)) return
        readAlong?.onRead()
        viewModelScope.launch { sync?.update(SavedPosition(id, json), observedAt) }
    }

    private fun isDisplayEcho(json: JsonObject, atMs: Long): Boolean {
        val target = displayHref ?: return false
        if (atMs - displayAtMs > DISPLAY_SETTLE_MS) {
            displayHref = null
            return false
        }
        val href = (json["href"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.trimStart('/')
        return href == target
    }

    /** The reader is about to show [href] for narration or on request; what it reports next isn't reading. */
    fun onDisplayMove(href: String) {
        displayHref = href.trimStart('/')
        displayAtMs = SystemClock.elapsedRealtime()
    }

    /** Rotation, resizing or new text settings: the page re-lays out, which is never reading. */
    fun onLayoutChanged() {
        layoutAtMs = SystemClock.elapsedRealtime()
    }

    /** Whether Play first needs to know which narration the page on screen shows. */
    val narrationNeedsPage: Boolean get() = readAlong?.needsPageCues == true

    fun narrationFragments(href: String): List<String> = readAlong?.fragmentsOf(href).orEmpty()

    fun toggleNarration(page: PageCues?) = readAlong?.toggle(page)
    fun skipNarration(back: Boolean) = readAlong?.skip(back)
    fun setNarrationSpeed(speed: Float) = readAlong?.setSpeed(speed)
    fun setFollowNarration(follow: Boolean) = readAlong?.setFollow(follow)
    fun backToNarration() = readAlong?.backToNarration()
    fun useAudiobookPlace() = readAlong?.useOffer()
    fun dismissAudiobookPlace() = readAlong?.dismissOffer()

    suspend fun locatorFor(fraction: Float): Locator? = opened?.locateProgression(fraction.toDouble())

    fun flush() {
        val target = sync ?: return
        container.scope.launch { target.flush() }
    }

    fun keepThisPlace() {
        val target = sync ?: return
        container.scope.launch { target.keepLocal() }
    }

    /** Adopts the other device's place and hands back where to go. */
    suspend fun useOtherPlace(): Locator? {
        readAlong?.restoreStarting()
        try {
            return adoptOtherPlace()
        } finally {
            // Whatever was adopted (or nothing) is in place before any Play goes on.
            readAlong?.restoreAbandoned()
        }
    }

    private suspend fun adoptOtherPlace(): Locator? {
        val position = sync?.useServer() ?: return null
        val paged = mutableState.value as? ReaderState.Paged
        if (paged != null) {
            // Another format's place applies on the next open; this file stays where it is.
            if (position.assetId != asset?.id) return null
            val restore = if (paged.format == ReadingFormat.PDF) {
                PageLocators.restorePdf(position.locator, paged.pageCount)
            } else {
                PageLocators.restoreComic(position.locator, comicPages)
            }
            // Going there is the reader's choice of a saved place, not new reading.
            if (restore is PageRestore.At) pageProgress.goToSaved(restore.index)
            return null
        }
        if (position.assetId != asset?.id) return null
        // Going there is the reader's choice of a saved place, not new reading.
        restoration = ReadingRestoration(position.locator)
        readAlong?.restoredTo(position.locator)
        return position.locator?.let { Locator.fromJSON(JSONObject(it.toString())) }
    }

    fun updateSettings(transform: (ReaderSettings) -> ReaderSettings) = container.readerSettings.update(transform)

    /** Runs [block], showing what went wrong instead of crashing: server errors and unreadable files alike. */
    private fun guarded(block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block()
            } catch (error: ApiException) {
                mutableState.value = ReaderState.Failed(error)
            } catch (error: UnreadableFile) {
                mutableState.value = ReaderState.Damaged(error.message.orEmpty())
            } catch (error: java.io.IOException) {
                mutableState.value = ReaderState.Damaged("This file couldn't be read from this device's storage.")
            }
        }
    }

    override fun onCleared() {
        readAlong?.close()
        opened?.close()
        document?.close()
        bitmaps.clear()
        flush()
    }

    private companion object {
        /** How long a display-only move may take to be reported back by Readium. */
        const val DISPLAY_SETTLE_MS = 2_500L

        /** How long Readium may keep reporting a re-laid-out page. */
        const val LAYOUT_SETTLE_MS = 1_500L
    }
}
