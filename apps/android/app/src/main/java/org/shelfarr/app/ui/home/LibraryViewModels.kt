package org.shelfarr.app.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.shelfarr.app.AccountServices
import org.shelfarr.app.AppContainer
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.LibraryFilter
import org.shelfarr.app.core.LibraryQuery
import org.shelfarr.app.core.LibrarySort
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.Publication

sealed interface HomeState {
    data object Loading : HomeState
    data class Failed(val error: ApiException) : HomeState
    data class Loaded(
        val inProgress: List<Publication>,
        val books: List<Publication>,
        val audiobooks: List<Publication>,
        /** Finished downloads on this device, newest first. */
        val downloads: List<Publication> = emptyList(),
        /** Any downloads exist, finished or not, so there is something to manage. */
        val hasDownloadRecords: Boolean = false,
        /** Set when the server couldn't be reached and only this device's downloads are shown. */
        val offline: ApiException? = null,
    ) : HomeState {
        val isEmpty: Boolean get() = inProgress.isEmpty() && books.isEmpty() && audiobooks.isEmpty() && downloads.isEmpty()
    }
}

class HomeViewModel(
    private val loadContinue: suspend () -> List<Publication>,
    private val loadShelf: suspend () -> List<Publication>,
    downloads: StateFlow<Map<String, DownloadRecord>>,
) : ViewModel() {
    constructor(container: AppContainer) : this(container, container.currentAccount())

    private constructor(container: AppContainer, account: AccountServices?) : this(
        loadContinue = {
            val services = account ?: throw ApiException.Unauthorized()
            services.api.continueReading(services.session.server, limit = CONTINUE_LIMIT)
        },
        loadShelf = {
            val services = account ?: throw ApiException.Unauthorized()
            services.api.library(services.session.server).items
        },
        downloads = account?.downloads?.records ?: MutableStateFlow(emptyMap()),
    )

    private val base = MutableStateFlow<HomeState>(HomeState.Loading)

    val state: StateFlow<HomeState> = combine(base, downloads) { state, records ->
        if (state !is HomeState.Loaded) return@combine state
        val ready = records.values.filter { it.isReady }.sortedByDescending { it.updatedAtEpochMs }.map { it.publication }
        state.copy(downloads = ready, hasDownloadRecords = records.isNotEmpty())
    }.stateIn(viewModelScope, SharingStarted.Eagerly, HomeState.Loading)

    private var request: Job? = null

    /** Reloads quietly, keeping what's on screen if the refresh fails. */
    fun refresh() {
        request?.cancel()
        request = viewModelScope.launch {
            try {
                val loaded = coroutineScope {
                    val continuing = async {
                        try {
                            loadContinue()
                        } catch (_: ApiException.NotFound) {
                            null // An older server without /continue: derive from the first page below.
                        }
                    }
                    val shelf = async { loadShelf() }
                    val items = shelf.await()
                    val recent = continuing.await() ?: items
                        .filter { it.progress?.isUsable == true }
                        .sortedByDescending { it.progress?.updatedAt.orEmpty() }
                    HomeState.Loaded(
                        // Library-wide recent activity; an explicit "finished" or "unread" leaves Continue.
                        inProgress = recent.filter { it.status == ReadingStatus.IN_PROGRESS },
                        books = items.filter { it.bookType == BookType.EBOOK },
                        audiobooks = items.filter { it.bookType == BookType.AUDIOBOOK },
                    )
                }
                base.value = loaded
            } catch (error: ApiException) {
                val current = base.value
                base.value = when {
                    current is HomeState.Loaded && current.offline == null -> current
                    error.isPlainOffline -> HomeState.Loaded(emptyList(), emptyList(), emptyList(), offline = error)
                    else -> HomeState.Failed(error)
                }
            }
        }
    }

    fun retry() {
        if (base.value !is HomeState.Loaded) base.value = HomeState.Loading
        refresh()
    }

    companion object {
        const val CONTINUE_LIMIT = 10
    }
}

data class LibraryState(
    val filter: LibraryFilter = LibraryFilter.ALL,
    val query: String = "",
    /** Null shows every status. */
    val status: ReadingStatus? = null,
    val sort: LibrarySort = LibrarySort.RECENT,
    val items: List<Publication> = emptyList(),
    val loading: Boolean = true,
    val loadingMore: Boolean = false,
    val nextCursor: String? = null,
    val error: ApiException? = null,
    /** A later page failed: the list stays, with a way to carry on. */
    val pageFailed: Boolean = false,
) {
    val libraryQuery: LibraryQuery get() = LibraryQuery(filter, query, status, sort)
    val isFiltered: Boolean get() = query.isNotBlank() || status != null
}

class LibraryViewModel(
    private val signedIn: () -> Session?,
    private val loadPage: suspend (ServerAddress, LibraryQuery, String?) -> LibraryPage,
) : ViewModel() {
    constructor(container: AppContainer) : this(
        { container.sessions.signedIn },
        { server, query, cursor ->
            val api = container.currentAccount()?.api ?: throw ApiException.Unauthorized()
            api.library(server, query, cursor)
        },
    )
    private val mutableState = MutableStateFlow(LibraryState())
    val state: StateFlow<LibraryState> = mutableState.asStateFlow()

    private var request: Job? = null
    private var generation = 0

    init {
        reload()
    }

    fun setFilter(filter: LibraryFilter) {
        if (filter == mutableState.value.filter) return
        mutableState.update { it.copy(filter = filter) }
        reload()
    }

    fun setStatus(status: ReadingStatus?) {
        if (status == mutableState.value.status) return
        mutableState.update { it.copy(status = status) }
        reload()
    }

    fun setSort(sort: LibrarySort) {
        if (sort == mutableState.value.sort) return
        mutableState.update { it.copy(sort = sort) }
        reload()
    }

    fun setQuery(query: String) {
        mutableState.update { it.copy(query = query) }
        reload(debounceMs = SEARCH_DEBOUNCE_MS)
    }

    /** Starts again from the first page. Any page still loading for the old query is ignored. */
    fun reload(debounceMs: Long = 0) {
        val server = signedIn()?.server ?: return
        request?.cancel()
        val generation = ++this.generation
        val query = mutableState.value.libraryQuery
        mutableState.update { it.copy(loading = true, loadingMore = false, nextCursor = null, error = null, pageFailed = false) }
        request = viewModelScope.launch {
            if (debounceMs > 0) delay(debounceMs)
            mutableState.update { it.copy(loading = true, error = null, pageFailed = false) }
            try {
                val page = loadPage(server, query, null)
                if (generation != this@LibraryViewModel.generation) return@launch
                mutableState.update {
                    it.copy(items = page.items, nextCursor = page.nextCursor, loading = false)
                }
            } catch (error: ApiException) {
                if (generation != this@LibraryViewModel.generation) return@launch
                mutableState.update { it.copy(loading = false, error = error, items = emptyList(), nextCursor = null) }
            }
        }
    }

    fun loadMore() {
        val server = signedIn()?.server ?: return
        val current = mutableState.value
        val cursor = current.nextCursor ?: return
        if (current.loading || current.loadingMore) return
        val generation = this.generation
        // The cursor is bound to the query that produced it.
        val query = current.libraryQuery
        mutableState.update { it.copy(loadingMore = true, pageFailed = false) }
        request = viewModelScope.launch {
            try {
                val page = loadPage(server, query, cursor)
                if (generation != this@LibraryViewModel.generation) return@launch
                mutableState.update {
                    it.copy(items = it.items + page.items.filter { new -> it.items.none { old -> old.id == new.id } }, nextCursor = page.nextCursor, loadingMore = false)
                }
            } catch (_: ApiException) {
                if (generation != this@LibraryViewModel.generation) return@launch
                mutableState.update { it.copy(loadingMore = false, pageFailed = true) }
            }
        }
    }

    private companion object {
        const val SEARCH_DEBOUNCE_MS = 350L
    }
}
