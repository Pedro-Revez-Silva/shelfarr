package org.shelfarr.app.ui

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.LibraryCoverage
import org.shelfarr.app.core.OfflineLibraryResult
import org.junit.Before
import org.junit.Test
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.LibraryFilter
import org.shelfarr.app.core.LibraryQuery
import org.shelfarr.app.core.LibrarySort
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.ui.home.LibraryViewModel

@OptIn(ExperimentalCoroutinesApi::class)
class LibraryViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setup() = Dispatchers.setMain(dispatcher)

    @After
    fun teardown() = Dispatchers.resetMain()

    @Test
    fun `refresh cancels old paging and permits paging the new filter`() = runTest(dispatcher) {
        val server = (ServerAddress.parse("https://example.org") as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me("1"), "token")
        val oldPage = CompletableDeferred<LibraryPage>()
        val calls = mutableListOf<Pair<LibraryFilter, String?>>()
        val model = LibraryViewModel({ session }) { _, query, cursor ->
            val filter = query.filter
            calls += filter to cursor
            if (filter == LibraryFilter.ALL && cursor != null) {
                // A network completion can arrive after cancellation.
                withContext(NonCancellable) { oldPage.await() }
            } else LibraryPage(nextCursor = if (cursor == null) "next" else null)
        }
        runCurrent()
        model.loadMore()
        runCurrent()
        model.setFilter(LibraryFilter.AUDIOBOOK)
        runCurrent()
        assertFalse(model.state.value.loadingMore)
        oldPage.complete(LibraryPage(nextCursor = "stale"))
        runCurrent()
        assertEquals("next", model.state.value.nextCursor)
        model.loadMore()
        runCurrent()
        assertEquals(LibraryFilter.AUDIOBOOK to "next", calls.last())
        assertFalse(model.state.value.loadingMore)
    }

    @Test
    fun `status and sort reset paging, bind the cursor and drop stale pages`() = runTest(dispatcher) {
        val server = (ServerAddress.parse("https://example.org") as ServerAddress.ParseResult.Valid).address
        val session = Session(server, Me("1"), "token")
        val stale = CompletableDeferred<LibraryPage>()
        val calls = mutableListOf<Pair<LibraryQuery, String?>>()
        fun book(id: String) = Publication(id, id, bookType = BookType.EBOOK)
        val model = LibraryViewModel({ session }) { _, query, cursor ->
            calls += query to cursor
            when {
                query.status == null && cursor != null -> withContext(NonCancellable) { stale.await() }
                cursor == null -> LibraryPage(listOf(book("${query.status}-1")), nextCursor = "${query.status}-next")
                else -> LibraryPage(listOf(book("${query.status}-2")), nextCursor = null)
            }
        }
        runCurrent()
        model.loadMore()
        runCurrent()
        model.setStatus(ReadingStatus.FINISHED)
        runCurrent()
        assertEquals(LibraryQuery(status = ReadingStatus.FINISHED) to null, calls.last())
        stale.complete(LibraryPage(listOf(book("stale")), nextCursor = "stale-next"))
        runCurrent()
        assertEquals(listOf("FINISHED-1"), model.state.value.items.map { it.id })
        assertEquals("FINISHED-next", model.state.value.nextCursor)

        model.loadMore()
        runCurrent()
        assertEquals(LibraryQuery(status = ReadingStatus.FINISHED) to "FINISHED-next", calls.last())
        assertEquals(listOf("FINISHED-1", "FINISHED-2"), model.state.value.items.map { it.id })

        model.setSort(LibrarySort.TITLE)
        runCurrent()
        assertEquals(LibraryQuery(status = ReadingStatus.FINISHED, sort = LibrarySort.TITLE) to null, calls.last())
        assertEquals(listOf("FINISHED-1"), model.state.value.items.map { it.id })
        assertFalse(model.state.value.loadingMore)
    }

    private val server = (ServerAddress.parse("https://example.org") as ServerAddress.ParseResult.Valid).address
    private val session = Session(server, Me("1"), "token")
    private fun book(id: String, title: String = id, type: BookType = BookType.EBOOK) = Publication(id, title, bookType = type)
    private val coverage = LibraryCoverage(titles = 2, lastOnlineAtEpochMs = 1_000)

    /** Answers like the device cache: filters by type and title text. */
    private val local: suspend (LibraryQuery) -> OfflineLibraryResult = { query ->
        val all = listOf(book("a", "Anathem"), book("b", "Beloved", BookType.AUDIOBOOK))
        OfflineLibraryResult(
            all.filter { (query.filter != LibraryFilter.AUDIOBOOK || it.bookType == BookType.AUDIOBOOK) && it.title.contains(query.text, true) },
            coverage,
        )
    }

    @Test
    fun `a lost connection shows the device's titles with their coverage, and no more pages`() = runTest(dispatcher) {
        val model = LibraryViewModel({ session }, local) { _, _, _ -> throw ApiException.Offline(java.net.ConnectException()) }
        runCurrent()
        val state = model.state.value
        assertEquals(listOf("a", "b"), state.items.map { it.id })
        assertEquals(coverage, state.offline!!.coverage)
        assertNull(state.error)
        assertNull(state.nextCursor)
        assertFalse(state.loading)
    }

    @Test
    fun `certificate, sign-in and server errors are never hidden behind the cache`() = runTest(dispatcher) {
        val failures = listOf(
            ApiException.Offline(javax.net.ssl.SSLHandshakeException("untrusted")),
            ApiException.Unauthorized(),
            ApiException.Server(500),
        )
        for (failure in failures) {
            val model = LibraryViewModel({ session }, local) { _, _, _ -> throw failure }
            runCurrent()
            assertEquals(failure, model.state.value.error)
            assertNull(model.state.value.offline)
            assertTrue(model.state.value.items.isEmpty())
        }
    }

    @Test
    fun `with nothing saved, the plain connection error is shown`() = runTest(dispatcher) {
        val model = LibraryViewModel({ session }, { OfflineLibraryResult(emptyList(), LibraryCoverage()) }) { _, _, _ ->
            throw ApiException.Offline(java.net.ConnectException())
        }
        runCurrent()
        assertTrue(model.state.value.error is ApiException.Offline)
        assertNull(model.state.value.offline)
    }

    @Test
    fun `offline filters answer at once, and a late server page can't overwrite a newer query`() = runTest(dispatcher) {
        var online = false
        val late = CompletableDeferred<LibraryPage>()
        val audio = CompletableDeferred<LibraryPage>()
        val model = LibraryViewModel({ session }, local) { _, query, _ ->
            when {
                !online -> throw ApiException.Offline(java.net.ConnectException())
                query.filter == LibraryFilter.ALL -> withContext(NonCancellable) { late.await() }
                else -> audio.await()
            }
        }
        runCurrent()
        online = true
        model.reload()
        runCurrent()
        model.setFilter(LibraryFilter.AUDIOBOOK)
        runCurrent()
        // Before the server answers, the device's audiobooks are already showing.
        assertEquals(listOf("b"), model.state.value.items.map { it.id })
        assertTrue(model.state.value.loading)
        audio.complete(LibraryPage(listOf(book("server-audio", type = BookType.AUDIOBOOK))))
        runCurrent()
        assertEquals(listOf("server-audio"), model.state.value.items.map { it.id })
        assertNull(model.state.value.offline)
        late.complete(LibraryPage(listOf(book("stale"))))
        runCurrent()
        assertEquals(listOf("server-audio"), model.state.value.items.map { it.id })
    }

    @Test
    fun `coming back online refreshes from the server`() = runTest(dispatcher) {
        val network = MutableStateFlow(false)
        var reachable = false
        val model = LibraryViewModel({ session }, local, network) { _, _, _ ->
            if (!reachable) throw ApiException.Offline(java.net.ConnectException())
            LibraryPage(listOf(book("fresh")), nextCursor = "next")
        }
        runCurrent()
        assertTrue(model.state.value.offline != null)
        model.loadMore()
        runCurrent()
        assertFalse("No paging through the device copy", model.state.value.loadingMore)
        reachable = true
        network.value = true
        runCurrent()
        assertNull(model.state.value.offline)
        assertEquals(listOf("fresh"), model.state.value.items.map { it.id })
        assertEquals("next", model.state.value.nextCursor)
    }
}
