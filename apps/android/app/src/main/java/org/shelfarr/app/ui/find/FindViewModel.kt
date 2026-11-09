package org.shelfarr.app.ui.find

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DiscoverItem
import org.shelfarr.app.core.FormatState
import org.shelfarr.app.core.NewRequest
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.RequestAccess
import org.shelfarr.app.core.RequestItem
import org.shelfarr.app.core.RequestOutcome

/** Everything Find needs from the account, so tests can run it against a fixture server. */
interface FindBackend {
    val access: StateFlow<RequestAccess>
    suspend fun refreshAccess()
    /** Starts browser approval; the page to open, or null if nothing should open. */
    suspend fun allowRequesting(): String?
    fun cancelApproval()
    /** Asks the server what this credential may do now, after a 403. */
    suspend fun refreshScopes()
    suspend fun discover(query: String): List<DiscoverItem>
    suspend fun requests(): List<RequestItem>
    suspend fun request(id: String): RequestItem
    suspend fun create(request: NewRequest): RequestOutcome
    suspend fun cancel(id: String): RequestItem
    suspend fun publication(id: String): Publication
}

class ContainerFindBackend(private val container: AppContainer) : FindBackend {
    private fun account() = container.currentAccount() ?: throw ApiException.Unauthorized()

    override val access: StateFlow<RequestAccess> get() = container.requesting.state

    override suspend fun refreshAccess() {
        container.sessions.signedIn?.let { container.requesting.refresh(it) }
    }

    override suspend fun allowRequesting(): String? = container.sessions.signedIn?.let { container.requesting.start(it) }

    override fun cancelApproval() = container.requesting.cancel()

    override suspend fun refreshScopes() {
        val account = account()
        container.sessions.refreshUser(account.api.me(account.session.server), account.session)
        refreshAccess()
    }

    override suspend fun discover(query: String) = account().let { it.api.discover(it.session.server, query) }
    override suspend fun requests() = account().let { it.api.requests(it.session.server) }
    override suspend fun request(id: String) = account().let { it.api.request(it.session.server, id) }
    override suspend fun create(request: NewRequest) = account().let { it.api.createRequest(it.session.server, request) }
    override suspend fun cancel(id: String) = account().let { it.api.cancelRequest(it.session.server, id) }
    override suspend fun publication(id: String) = account().publication(id)
}

data class FindState(
    val query: String = "",
    /** The query the shown results answer; results stay put while a new search runs. */
    val searchedFor: String? = null,
    val searching: Boolean = false,
    val results: List<DiscoverItem> = emptyList(),
    val searchError: Throwable? = null,
    val requests: List<RequestItem> = emptyList(),
    val requestsLoaded: Boolean = false,
    /** Set when the list on screen is from earlier because the server can't be reached now. */
    val requestsError: Throwable? = null,
)

data class TitleState(
    val item: DiscoverItem? = null,
    val format: BookType? = null,
    val submitting: Boolean = false,
    /** What the last attempt said, in plain words. */
    val message: String? = null,
)

data class TrackState(
    val request: RequestItem? = null,
    val loading: Boolean = false,
    val error: Throwable? = null,
    val cancelling: Boolean = false,
    val cancelMessage: String? = null,
    val opening: Boolean = false,
)

/**
 * Find, choose a format, request, follow it, open it. Shared by the Find tab, the title
 * page and the request page, so a result tapped in one is the one shown in the next.
 */
class FindViewModel(
    private val backend: FindBackend,
    private val pollIntervalMs: Long = 5_000,
) : ViewModel() {
    constructor(container: AppContainer) : this(ContainerFindBackend(container))

    val access: StateFlow<RequestAccess> get() = backend.access

    private val findState = MutableStateFlow(FindState())
    val find: StateFlow<FindState> = findState.asStateFlow()

    private val titleState = MutableStateFlow(TitleState())
    val title: StateFlow<TitleState> = titleState.asStateFlow()

    private val trackState = MutableStateFlow(TrackState())
    val track: StateFlow<TrackState> = trackState.asStateFlow()

    private val browser = Channel<String>(Channel.CONFLATED)
    /** Approval pages to open in the system browser. */
    val openBrowser: Flow<String> = browser.receiveAsFlow()

    private val navigation = Channel<FindDestination>(Channel.BUFFERED)
    val destinations: Flow<FindDestination> = navigation.receiveAsFlow()

    private var searchJob: Job? = null
    private var trackJob: Job? = null
    private var listJob: Job? = null

    fun onShown() {
        viewModelScope.launch {
            backend.refreshAccess()
            if (backend.access.value == RequestAccess.Allowed) loadRequests()
        }
    }

    fun allowRequesting() {
        viewModelScope.launch {
            backend.allowRequesting()?.let { browser.trySend(it) }
        }
    }

    fun reopenApproval() {
        (backend.access.value as? RequestAccess.Approving)?.let { browser.trySend(it.browserUri) }
    }

    fun cancelApproval() = backend.cancelApproval()

    fun setQuery(value: String) = findState.update { it.copy(query = value.take(200)) }

    fun search() {
        val query = findState.value.query.trim()
        if (query.isEmpty()) {
            searchJob?.cancel()
            findState.update { it.copy(searchedFor = null, results = emptyList(), searchError = null, searching = false) }
            return
        }
        if (findState.value.searching && findState.value.searchedFor == query) return
        searchJob?.cancel()
        findState.update { it.copy(searching = true, searchError = null) }
        searchJob = viewModelScope.launch {
            try {
                val items = backend.discover(query)
                findState.update { it.copy(searching = false, searchedFor = query, results = items) }
            } catch (error: ApiException) {
                if (error is ApiException.Forbidden) lostPermission()
                findState.update { it.copy(searching = false, searchedFor = query, results = emptyList(), searchError = error) }
            }
        }
    }

    fun loadRequests() {
        if (listJob?.isActive == true) return
        listJob = viewModelScope.launch {
            try {
                val items = backend.requests()
                findState.update { it.copy(requests = items, requestsLoaded = true, requestsError = null) }
            } catch (error: ApiException) {
                if (error is ApiException.Forbidden) lostPermission()
                findState.update { it.copy(requestsLoaded = true, requestsError = error) }
            }
        }
    }

    /** While Find is visible, keeps open requests current at a gentle pace. */
    suspend fun followRequests() {
        while (true) {
            delay(pollIntervalMs * 3)
            if (findState.value.requests.any { it.stage.isOpen }) loadRequests()
        }
    }

    fun choose(item: DiscoverItem) {
        val requestable = listOf(BookType.EBOOK, BookType.AUDIOBOOK).firstOrNull { item.format(it)?.state == FormatState.REQUESTABLE }
        titleState.value = TitleState(item = item, format = requestable)
        navigation.trySend(FindDestination.Title)
    }

    fun selectFormat(type: BookType) {
        val item = titleState.value.item ?: return
        if (item.format(type)?.state != FormatState.REQUESTABLE) return
        titleState.update { it.copy(format = type, message = null) }
    }

    /** Requests the chosen format once. Further taps while it is in flight do nothing. */
    fun submit() {
        val current = titleState.value
        val item = current.item ?: return
        val format = current.format ?: return
        if (current.submitting) return
        titleState.update { it.copy(submitting = true, message = null) }
        viewModelScope.launch {
            try {
                when (val outcome = backend.create(NewRequest.from(item, format))) {
                    is RequestOutcome.Created, is RequestOutcome.Existing -> {
                        val request = requireNotNull(outcome.request)
                        markRequested(item, format, request)
                        titleState.update { it.copy(submitting = false) }
                        follow(request)
                        navigation.trySend(FindDestination.Request(request.id))
                    }
                    is RequestOutcome.InLibrary -> {
                        updateFormat(item, format) { it.copy(state = FormatState.IN_LIBRARY, publicationId = outcome.publicationId) }
                        titleState.update { it.copy(submitting = false, format = null, message = "This ${format.word} is already in the library.") }
                    }
                    is RequestOutcome.RequestedBySomeone -> {
                        updateFormat(item, format) { it.copy(state = FormatState.REQUESTED_BY_SOMEONE) }
                        titleState.update {
                            it.copy(submitting = false, format = null, message = outcome.message ?: "Someone on this server already asked for this ${format.word}. It will appear in the library when it arrives.")
                        }
                    }
                    is RequestOutcome.Refused -> titleState.update {
                        it.copy(submitting = false, message = outcome.message ?: "The server didn't accept this request.")
                    }
                }
            } catch (error: ApiException) {
                if (error is ApiException.Forbidden) lostPermission()
                titleState.update { it.copy(submitting = false, message = requestFailure(error)) }
            }
        }
    }

    fun openRequest(request: RequestItem) {
        follow(request)
        navigation.trySend(FindDestination.Request(request.id))
    }

    /** Shows [request] at once, then keeps it current until it finishes or the page closes. */
    fun follow(request: RequestItem) {
        trackState.value = TrackState(request = request)
    }

    fun followId(id: String) {
        if (trackState.value.request?.id != id) trackState.value = TrackState(loading = true)
    }

    /** Polls the shown request while the page is visible. Cancel the returned job when it isn't. */
    fun startTracking(id: String) {
        trackJob?.cancel()
        trackJob = viewModelScope.launch {
            while (isActive) {
                try {
                    val fresh = backend.request(id)
                    trackState.update { it.copy(request = fresh, loading = false, error = null) }
                    replaceInList(fresh)
                    if (!fresh.stage.isOpen) break
                } catch (error: ApiException) {
                    if (error is ApiException.Forbidden) lostPermission()
                    trackState.update { it.copy(loading = false, error = error) }
                    if (!error.isRetryable) break
                }
                delay(pollIntervalMs)
            }
        }
    }

    fun stopTracking() {
        trackJob?.cancel()
        trackJob = null
    }

    fun cancelRequest() {
        val request = trackState.value.request ?: return
        if (trackState.value.cancelling) return
        trackState.update { it.copy(cancelling = true, cancelMessage = null) }
        viewModelScope.launch {
            try {
                val updated = backend.cancel(request.id)
                trackState.update { it.copy(request = updated, cancelling = false) }
                replaceInList(updated)
            } catch (error: ApiException) {
                val message = when (error) {
                    is ApiException.Rejected -> error.detail ?: "This request can't be cancelled now."
                    else -> requestFailure(error)
                }
                trackState.update { it.copy(cancelling = false, cancelMessage = message) }
            }
        }
    }

    /** Fetches the acquired publication so it can open straight into the reader or player. */
    fun openPublication(id: String, onReady: (Publication) -> Unit) {
        if (trackState.value.opening) return
        trackState.update { it.copy(opening = true, cancelMessage = null) }
        viewModelScope.launch {
            try {
                onReady(backend.publication(id))
                trackState.update { it.copy(opening = false) }
            } catch (error: ApiException) {
                trackState.update { it.copy(opening = false, cancelMessage = requestFailure(error)) }
            }
        }
    }

    private fun lostPermission() {
        viewModelScope.launch {
            try {
                backend.refreshScopes()
            } catch (_: ApiException) {
                // The next visit asks again.
            }
        }
    }

    private fun markRequested(item: DiscoverItem, format: BookType, request: RequestItem) {
        updateFormat(item, format) { it.copy(state = FormatState.REQUESTED, request = request) }
        findState.update { state -> state.copy(requests = listOf(request) + state.requests.filterNot { it.id == request.id }) }
    }

    private fun updateFormat(item: DiscoverItem, format: BookType, change: (org.shelfarr.app.core.FormatOption) -> org.shelfarr.app.core.FormatOption) {
        val updated = item.copy(formats = item.formats.map { if (it.bookType == format) change(it) else it })
        titleState.update { if (it.item?.id == item.id) it.copy(item = updated) else it }
        findState.update { state -> state.copy(results = state.results.map { if (it.id == item.id) updated else it }) }
    }

    private fun replaceInList(request: RequestItem) {
        findState.update { state -> state.copy(requests = state.requests.map { if (it.id == request.id) request else it }) }
    }
}

sealed interface FindDestination {
    data object Title : FindDestination
    data class Request(val id: String) : FindDestination
}

internal val BookType.word: String get() = if (this == BookType.EBOOK) "ebook" else "audiobook"

internal fun requestFailure(error: ApiException): String = when {
    error.isPlainOffline -> "You're offline. Requesting needs a connection to your server."
    error is ApiException.Offline -> "The server's security certificate couldn't be trusted."
    error is ApiException.Forbidden -> "This connection isn't allowed to request books any more. Allow requesting again from Find."
    error is ApiException.Server -> "The server had a problem (error ${error.status}). Try again in a moment."
    error is ApiException.NotFound -> "That isn't on the server any more."
    error is ApiException.Rejected -> error.detail ?: "The server didn't accept that."
    else -> "Something went wrong. Try again."
}
