package org.shelfarr.app.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.LibraryFilter
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
    ) : HomeState {
        val isEmpty: Boolean get() = inProgress.isEmpty() && books.isEmpty() && audiobooks.isEmpty()
    }
}

class HomeViewModel(private val container: AppContainer) : ViewModel() {
    private val mutableState = MutableStateFlow<HomeState>(HomeState.Loading)
    val state: StateFlow<HomeState> = mutableState.asStateFlow()

    /** Reloads quietly, keeping what's on screen if the refresh fails. */
    fun refresh() {
        val server = container.sessions.signedIn?.server ?: return
        viewModelScope.launch {
            try {
                val items = container.api.library(server).items
                mutableState.value = HomeState.Loaded(
                    inProgress = items
                        .filter { it.progress?.isUsable == true }
                        .sortedByDescending { it.progress?.updatedAt.orEmpty() },
                    books = items.filter { it.bookType == BookType.EBOOK },
                    audiobooks = items.filter { it.bookType == BookType.AUDIOBOOK },
                )
            } catch (error: ApiException) {
                if (mutableState.value !is HomeState.Loaded) mutableState.value = HomeState.Failed(error)
            }
        }
    }

    fun retry() {
        mutableState.value = HomeState.Loading
        refresh()
    }
}

data class LibraryState(
    val filter: LibraryFilter = LibraryFilter.ALL,
    val query: String = "",
    val items: List<Publication> = emptyList(),
    val loading: Boolean = true,
    val loadingMore: Boolean = false,
    val nextCursor: String? = null,
    val error: ApiException? = null,
    /** A later page failed: the list stays, with a way to carry on. */
    val pageFailed: Boolean = false,
)

class LibraryViewModel(
    private val signedIn: () -> Session?,
    private val loadPage: suspend (ServerAddress, LibraryFilter, String, String?) -> LibraryPage,
) : ViewModel() {
    constructor(container: AppContainer) : this(
        { container.sessions.signedIn },
        { server, filter, query, cursor -> container.api.library(server, filter, query, cursor) },
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

    fun setQuery(query: String) {
        mutableState.update { it.copy(query = query) }
        reload(debounceMs = SEARCH_DEBOUNCE_MS)
    }

    fun reload(debounceMs: Long = 0) {
        val server = signedIn()?.server ?: return
        request?.cancel()
        val generation = ++this.generation
        val current = mutableState.value
        mutableState.update { it.copy(loading = true, loadingMore = false, nextCursor = null, error = null, pageFailed = false) }
        request = viewModelScope.launch {
            if (debounceMs > 0) delay(debounceMs)
            mutableState.update { it.copy(loading = true, error = null, pageFailed = false) }
            try {
                val page = loadPage(server, current.filter, current.query, null)
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
        mutableState.update { it.copy(loadingMore = true, pageFailed = false) }
        request = viewModelScope.launch {
            try {
                val page = loadPage(server, current.filter, current.query, cursor)
                if (generation != this@LibraryViewModel.generation) return@launch
                mutableState.update {
                    it.copy(items = it.items + page.items, nextCursor = page.nextCursor, loadingMore = false)
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
