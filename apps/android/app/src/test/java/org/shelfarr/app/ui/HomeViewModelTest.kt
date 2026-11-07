package org.shelfarr.app.ui

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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.ui.home.HomeState
import org.shelfarr.app.ui.home.HomeViewModel

@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setup() = Dispatchers.setMain(dispatcher)

    @After
    fun teardown() = Dispatchers.resetMain()

    private fun book(id: String, status: ReadingStatus? = null, progress: Boolean = false, updated: String = "") = Publication(
        id = id,
        title = id,
        bookType = BookType.EBOOK,
        progress = if (progress) Progress("a", positionSeconds = 1.0, version = 1, updatedAt = updated) else null,
        readingStatus = status,
    )

    @Test
    fun `continue comes from the library-wide endpoint, not the first page`() = runTest(dispatcher) {
        val firstPage = listOf(book("page-1"), book("page-2", progress = true))
        val recent = listOf(
            book("from-page-nine", ReadingStatus.IN_PROGRESS, progress = true),
            book("finished-recently", ReadingStatus.FINISHED, progress = true),
            book("marked-unread", ReadingStatus.UNREAD, progress = true),
        )
        val model = HomeViewModel({ recent }, { firstPage }, MutableStateFlow(emptyMap()))
        model.refresh()
        runCurrent()

        val loaded = model.state.value as HomeState.Loaded
        assertEquals(listOf("from-page-nine"), loaded.inProgress.map { it.id })
        assertEquals(listOf("page-1", "page-2"), loaded.books.map { it.id })
        assertNull(loaded.offline)
    }

    @Test
    fun `an older server without continue falls back to the first page`() = runTest(dispatcher) {
        val firstPage = listOf(book("old", progress = true, updated = "2026-01-01"), book("new", progress = true, updated = "2026-02-01"), book("none"))
        val model = HomeViewModel({ throw ApiException.NotFound() }, { firstPage }, MutableStateFlow(emptyMap()))
        model.refresh()
        runCurrent()
        assertEquals(listOf("new", "old"), (model.state.value as HomeState.Loaded).inProgress.map { it.id })
    }

    @Test
    fun `offline shows this device's downloads, while sign-in and certificate errors stay errors`() = runTest(dispatcher) {
        val downloaded = book("on-device")
        val downloads = MutableStateFlow(
            mapOf(
                "on-device" to DownloadRecord("on-device", downloaded, emptyList(), DownloadState.READY),
                "partial" to DownloadRecord("partial", book("partial"), emptyList(), DownloadState.DOWNLOADING),
            ),
        )
        val offline = HomeViewModel({ throw ApiException.Offline() }, { throw ApiException.Offline() }, downloads)
        offline.refresh()
        runCurrent()
        val shown = offline.state.value as HomeState.Loaded
        assertNotNull(shown.offline)
        assertEquals("Only finished downloads are offered", listOf("on-device"), shown.downloads.map { it.id })
        assertTrue(shown.hasDownloadRecords)

        val certificate = ApiException.Offline(javax.net.ssl.SSLHandshakeException("untrusted"))
        val untrusted = HomeViewModel({ throw certificate }, { throw certificate }, downloads)
        untrusted.refresh()
        runCurrent()
        assertTrue(untrusted.state.value is HomeState.Failed)

        val signedOut = HomeViewModel({ throw ApiException.Unauthorized() }, { throw ApiException.Unauthorized() }, downloads)
        signedOut.refresh()
        runCurrent()
        assertTrue((signedOut.state.value as HomeState.Failed).error is ApiException.Unauthorized)
    }
}
