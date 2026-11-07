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
import org.junit.Before
import org.junit.Test
import org.shelfarr.app.core.LibraryFilter
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
        val model = LibraryViewModel({ session }) { _, filter, _, cursor ->
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
}
