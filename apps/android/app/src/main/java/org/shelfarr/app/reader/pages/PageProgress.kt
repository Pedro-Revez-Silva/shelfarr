package org.shelfarr.app.reader.pages

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Where a PDF or comic is, kept as two different things.
 *
 * [page] is where the pager is: the page on screen, drawn or not. Turning from the
 * keyboard or the controls starts from it, so a page that couldn't be drawn never traps
 * the reader on it; they can turn past it or back.
 *
 * The reading place is the last page the reader actually saw. It moves only when the
 * pager has settled on a different page and that page has been drawn. That is reading,
 * and [onRead] records it with the time it was seen. Opening, restoring or choosing a
 * saved place, rotating, zooming, re-laying out, prefetching a neighbour and a page that
 * fails to draw never move it.
 */
class PageProgress {
    private val position = MutableStateFlow(0)

    /** The page the pager is on (0-based), whether or not it could be drawn. */
    val page: StateFlow<Int> = position.asStateFlow()

    private val mutableCommands = MutableSharedFlow<PageCommand>(extraBufferCapacity = 8)

    /** Requests for the pager to show a page. */
    val commands: SharedFlow<PageCommand> = mutableCommands.asSharedFlow()

    private var pageCount = 0
    private var place = 0
    private var onRead: (index: Int, observedAtEpochMs: Long) -> Unit = { _, _ -> }

    /** The last page the reader saw, or the page this session opened at. */
    val readingPlace: Int get() = place

    /**
     * Starts a file at [index], the restored place. Restoring is not reading: the page
     * already saved is shown without being written again.
     */
    fun open(pageCount: Int, index: Int, onRead: (index: Int, observedAtEpochMs: Long) -> Unit) {
        this.pageCount = pageCount
        this.onRead = onRead
        place = index.coerceIn(0, (pageCount - 1).coerceAtLeast(0))
        position.value = place
    }

    /** The pager came to rest on [index]. Nothing is saved until that page is drawn. */
    fun onSettled(index: Int) {
        if (index in 0 until pageCount) position.value = index
    }

    /**
     * The settled page [index] was drawn, first seen at [observedAtEpochMs]. A page other
     * than the reading place is new reading and is recorded with that time.
     */
    fun onShown(index: Int, observedAtEpochMs: Long) {
        if (index !in 0 until pageCount || index == place) return
        place = index
        onRead(index, observedAtEpochMs)
    }

    /** A turn from the keyboard or controls, from the page on screen. It is saved once seen there. */
    fun turn(delta: Int) {
        if (pageCount <= 0) return
        val target = (position.value + delta).coerceIn(0, pageCount - 1)
        if (target != position.value) mutableCommands.tryEmit(PageCommand(target, animate = true))
    }

    /** Goes to a saved place the reader chose. Looking is not reading, so nothing is written. */
    fun goToSaved(index: Int) {
        if (pageCount <= 0) return
        val target = index.coerceIn(0, pageCount - 1)
        place = target
        position.value = target
        mutableCommands.tryEmit(PageCommand(target, animate = false))
    }
}
