package org.shelfarr.app.reader

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
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
import org.shelfarr.app.core.AccountPublications
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.ProgressSync
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ResumeDecision
import org.shelfarr.app.core.SavedPosition
import org.shelfarr.app.core.SyncStatus

/** One entry of the flattened table of contents. */
data class ContentsEntry(val title: String, val link: Link, val depth: Int)

sealed interface ReaderState {
    data class Preparing(val fraction: Float?) : ReaderState

    /** This device and another disagree. The reader picks before anything opens. */
    data class ChooseResume(val local: SavedPosition, val server: Progress) : ReaderState

    data class Ready(
        val title: String,
        val publication: ReadiumPublication,
        val navigatorFactory: EpubNavigatorFactory,
        val initialLocator: Locator?,
        val contents: List<ContentsEntry>,
        val positionCount: Int,
        val notice: String?,
    ) : ReaderState

    data class Failed(val error: Throwable) : ReaderState

    /** Readium could not open the file, or it uses DRM we cannot read. */
    data object Unreadable : ReaderState
}

data class ReadingPlace(
    val fraction: Float = 0f,
    val position: Int? = null,
    val chapter: String? = null,
)

@OptIn(ExperimentalReadiumApi::class)
class ReaderViewModel(application: Application, private val publicationId: String) : AndroidViewModel(application) {
    private val container = (application as ShelfarrApplication).container
    private val account = container.currentAccount()

    private val mutableState = MutableStateFlow<ReaderState>(ReaderState.Preparing(null))
    val state: StateFlow<ReaderState> = mutableState.asStateFlow()

    private val mutablePlace = MutableStateFlow(ReadingPlace())
    val place: StateFlow<ReadingPlace> = mutablePlace.asStateFlow()

    val settings get() = container.readerSettings.settings
    val serverHost: String? get() = account?.session?.server?.host

    private val sync: ProgressSync? = account?.progress?.sync(publicationId)
    val syncStatus: StateFlow<SyncStatus> = sync?.status ?: MutableStateFlow(SyncStatus.Idle)

    private var asset: Asset? = null
    private var details: Publication? = null
    private var opened: ReadiumPublication? = null
    private var notice: String? = null

    init {
        open()
    }

    fun open() {
        val services = account ?: run {
            mutableState.value = ReaderState.Failed(ApiException.Unauthorized())
            return
        }
        mutableState.value = ReaderState.Preparing(null)
        viewModelScope.launch {
            try {
                val session = services.session
                val books = AccountPublications(services.directory)
                val publication = try {
                    container.api.publication(session.server, publicationId).also { books.remember(it) }
                } catch (error: ApiException.Offline) {
                    // A working copy may still be on disk from an earlier read.
                    books.recall(publicationId) ?: throw error
                }
                val epub = publication.epubAsset ?: run {
                    mutableState.value = ReaderState.Unreadable
                    return@launch
                }
                asset = epub
                details = publication

                val cached = container.epubCache.obtain(session.accountKey, session.server, epub) { fraction ->
                    mutableState.value = ReaderState.Preparing(fraction)
                }
                if (cached.unverified) notice = "Reading the copy on this device. Your place will sync when you're back online."

                val readium = openWithReadium(cached.file) ?: run {
                    mutableState.value = ReaderState.Unreadable
                    return@launch
                }
                opened = readium

                val local = sync?.snapshot()
                when (val decision = ResumeDecision.decide(publication, publication.progress, local)) {
                    ResumeDecision.Beginning -> ready(null, baseVersion = 0)
                    is ResumeDecision.Continue -> ready(decision.position, decision.baseVersion)
                    is ResumeDecision.Choose -> mutableState.value = ReaderState.ChooseResume(decision.local, decision.server)
                    is ResumeDecision.EditionChanged -> {
                        notice = "This book's file was replaced, so your old place doesn't apply. Starting from the beginning."
                        ready(null, decision.staleVersion)
                    }
                }
            } catch (error: ApiException) {
                mutableState.value = ReaderState.Failed(error)
            }
        }
    }

    fun chooseResume(keepLocal: Boolean) {
        val choice = mutableState.value as? ReaderState.ChooseResume ?: return
        viewModelScope.launch {
            val position = if (keepLocal) choice.local else SavedPosition.from(choice.server)
            sync?.chooseAtOpen(position, choice.server.version, keepLocal)
            ready(position, choice.server.version)
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

    private suspend fun ready(start: SavedPosition?, baseVersion: Int) {
        val publication = opened ?: return
        sync?.begin(start, baseVersion)
        val locator = start?.locator?.let { json ->
            Locator.fromJSON(JSONObject(json.toString()))
        }
        val positions = publication.positions()
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

    private fun flatten(links: List<Link>, depth: Int): List<ContentsEntry> = links.flatMap { link ->
        listOf(ContentsEntry(link.title?.takeIf(String::isNotBlank) ?: "Untitled", link, depth)) +
            flatten(link.children, depth + 1)
    }

    fun onLocatorChanged(locator: Locator) {
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
        viewModelScope.launch { sync?.update(SavedPosition(id, json)) }
    }

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
        val position = sync?.useServer() ?: return null
        return position.locator?.let { Locator.fromJSON(JSONObject(it.toString())) }
    }

    fun updateSettings(transform: (ReaderSettings) -> ReaderSettings) = container.readerSettings.update(transform)

    override fun onCleared() {
        opened?.close()
        flush()
    }
}
