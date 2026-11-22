package org.shelfarr.app.ui

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DiscoverItem
import org.shelfarr.app.core.FormatOption
import org.shelfarr.app.core.FormatState
import org.shelfarr.app.core.NewRequest
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.RequestAccess
import org.shelfarr.app.core.RequestItem
import org.shelfarr.app.core.RequestOutcome
import org.shelfarr.app.core.RequestStage
import org.shelfarr.app.ui.find.FindBackend
import org.shelfarr.app.ui.find.FindViewModel

@OptIn(ExperimentalCoroutinesApi::class)
class FindViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setup() = Dispatchers.setMain(dispatcher)

    @After
    fun teardown() = Dispatchers.resetMain()

    private class Backend : FindBackend {
        override val access = MutableStateFlow<RequestAccess>(RequestAccess.Allowed)
        var discoverAnswer = CompletableDeferred<List<DiscoverItem>>()
        var requestList: List<RequestItem> = emptyList()
        var createAnswer = CompletableDeferred<RequestOutcome>()
        val publications = mutableMapOf<String, CompletableDeferred<Publication>>()

        override suspend fun refreshAccess() = Unit
        override suspend fun allowRequesting(): String? = null
        override fun cancelApproval() = Unit
        override suspend fun refreshScopes() = Unit
        override suspend fun discover(query: String) = discoverAnswer.await()
        override suspend fun requests() = requestList
        override suspend fun request(id: String) = requestList.first { it.id == id }
        override suspend fun create(request: NewRequest) = createAnswer.await()
        override suspend fun cancel(id: String) = requestList.first { it.id == id }
        override suspend fun publication(id: String) = publications.getOrPut(id) { CompletableDeferred() }.await()
    }

    private val backend = Backend()
    private val model = FindViewModel(backend, pollIntervalMs = 1_000)

    private fun request(stage: RequestStage, updatedAt: String? = null, publicationId: String? = null, type: BookType = BookType.EBOOK, id: String = "r1") =
        RequestItem(id = id, stage = stage, title = "Lighthouse", bookType = type, publicationId = publicationId, updatedAt = updatedAt)

    private fun title(ebook: FormatOption, audiobook: FormatOption = FormatOption(BookType.AUDIOBOOK, FormatState.REQUESTABLE)) =
        DiscoverItem(id = "w1", workId = "w1", title = "Lighthouse", formats = listOf(ebook, audiobook))

    private fun requested(request: RequestItem) = FormatOption(request.bookType, FormatState.REQUESTED, request = request)

    private fun shownEbook() = model.find.value.results.single().format(BookType.EBOOK)!!

    private fun searchAnswering(item: DiscoverItem) {
        model.setQuery("lighthouse")
        model.search()
        backend.discoverAnswer.complete(listOf(item))
        dispatcher.scheduler.runCurrent()
    }

    private fun listShowing(vararg requests: RequestItem) {
        backend.requestList = requests.toList()
        model.loadRequests()
        dispatcher.scheduler.runCurrent()
    }

    @Test
    fun `a format follows its request while the server would list it as requested, then becomes owned or requestable`() = runTest(dispatcher) {
        searchAnswering(title(requested(request(RequestStage.SEARCHING))))

        listShowing(request(RequestStage.AWAITING_PURCHASE))
        assertEquals(requested(request(RequestStage.AWAITING_PURCHASE)), shownEbook())

        listShowing(request(RequestStage.AVAILABLE, publicationId = "pub-1"))
        assertEquals(FormatOption(BookType.EBOOK, FormatState.IN_LIBRARY, publicationId = "pub-1"), shownEbook())
    }

    @Test
    fun `a request that ends without a copy leaves its format requestable, as a new search would show it`() = runTest(dispatcher) {
        for (ending in listOf(RequestStage.NOT_FOUND, RequestStage.FAILED, RequestStage.COMPLETED)) {
            searchAnswering(title(requested(request(RequestStage.SEARCHING))))
            backend.discoverAnswer = CompletableDeferred()

            listShowing(request(ending))
            assertEquals(FormatOption(BookType.EBOOK, FormatState.REQUESTABLE), shownEbook())

            listShowing(request(RequestStage.QUEUED))
            assertEquals(FormatOption(BookType.EBOOK, FormatState.REQUESTABLE), shownEbook())
        }
    }

    @Test
    fun `the server's answer to a new request after a failure outlasts the failed request in the list`() = runTest(dispatcher) {
        searchAnswering(title(requested(request(RequestStage.SEARCHING))))
        listShowing(request(RequestStage.FAILED))
        model.choose(model.find.value.results.single())
        backend.createAnswer.complete(RequestOutcome.InLibrary("pub-9", "Already in the library."))
        model.submit()
        runCurrent()

        listShowing(request(RequestStage.FAILED))

        assertEquals(FormatOption(BookType.EBOOK, FormatState.IN_LIBRARY, publicationId = "pub-9"), model.title.value.item?.format(BookType.EBOOK))
        assertEquals(FormatState.IN_LIBRARY, shownEbook().state)
    }

    @Test
    fun `a fresh search answer wins over a list entry from the same second`() = runTest(dispatcher) {
        listShowing(request(RequestStage.FAILED, "2026-11-22T10:00:00Z"))

        searchAnswering(title(requested(request(RequestStage.QUEUED, "2026-11-22T10:00:00Z"))))

        assertEquals(requested(request(RequestStage.QUEUED, "2026-11-22T10:00:00Z")), shownEbook())
    }

    @Test
    fun `a search answer that arrives after a newer request update keeps the newer state`() = runTest(dispatcher) {
        listShowing(request(RequestStage.PROCESSING, "2026-11-22T10:00:00Z"))
        model.setQuery("lighthouse")
        model.search()
        runCurrent()
        listShowing(request(RequestStage.AVAILABLE, "2026-11-22T10:01:00Z", publicationId = "pub-1"))

        backend.discoverAnswer.complete(listOf(title(requested(request(RequestStage.PROCESSING, "2026-11-22T10:00:00Z")))))
        runCurrent()

        assertEquals(FormatOption(BookType.EBOOK, FormatState.IN_LIBRARY, publicationId = "pub-1"), shownEbook())
    }

    @Test
    fun `an older request list never moves a format back`() = runTest(dispatcher) {
        searchAnswering(title(requested(request(RequestStage.DOWNLOADING, "2026-11-22T10:05:00Z"))))

        listShowing(request(RequestStage.SEARCHING, "2026-11-22T10:00:00Z"))

        assertEquals(RequestStage.DOWNLOADING, shownEbook().request?.stage)
    }

    @Test
    fun `requesting the other format keeps what the first format became meanwhile`() = runTest(dispatcher) {
        searchAnswering(title(requested(request(RequestStage.PROCESSING))))
        model.choose(model.find.value.results.single())
        model.submit()
        runCurrent()

        listShowing(request(RequestStage.AVAILABLE, publicationId = "pub-1"))
        backend.createAnswer.complete(RequestOutcome.Created(request(RequestStage.QUEUED, type = BookType.AUDIOBOOK, id = "r2")))
        runCurrent()

        val item = model.title.value.item!!
        assertEquals(FormatState.IN_LIBRARY, item.format(BookType.EBOOK)?.state)
        assertEquals(FormatState.REQUESTED, item.format(BookType.AUDIOBOOK)?.state)
        assertEquals(item, model.find.value.results.single())
    }

    @Test
    fun `leaving the page before the publication arrives opens nothing`() = runTest(dispatcher) {
        val opened = mutableListOf<Publication>()
        model.openOwned("pub-1") { opened += it }
        runCurrent()
        assertTrue(model.title.value.opening)

        model.stopOpening()
        backend.publications.getValue("pub-1").complete(Publication(id = "pub-1", title = "Lighthouse", bookType = BookType.EBOOK))
        runCurrent()

        assertTrue(opened.isEmpty())
        assertFalse(model.title.value.opening)

        model.openOwned("pub-2") { opened += it }
        runCurrent()
        backend.publications.getValue("pub-2").complete(Publication(id = "pub-2", title = "Lighthouse", bookType = BookType.EBOOK))
        runCurrent()
        assertEquals(listOf("pub-2"), opened.map { it.id })
        assertFalse(model.title.value.opening)
    }

    @Test
    fun `a ready request's Read now is cancelled the same way when its page goes away`() = runTest(dispatcher) {
        val opened = mutableListOf<Publication>()
        model.openPublication("pub-1") { opened += it }
        runCurrent()
        assertTrue(model.track.value.opening)

        model.stopOpening()
        backend.publications.getValue("pub-1").complete(Publication(id = "pub-1", title = "Lighthouse", bookType = BookType.EBOOK))
        runCurrent()

        assertTrue(opened.isEmpty())
        assertFalse(model.track.value.opening)
    }
}
