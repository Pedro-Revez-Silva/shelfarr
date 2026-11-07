package org.shelfarr.app.core

import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Real files: the offline library must be honest about what it covers and never mix stale data in. */
class LibraryCacheTest {
    @get:Rule val folder = TemporaryFolder()
    private val scopes = mutableListOf<CoroutineScope>()

    @After
    fun tearDown() = scopes.forEach { it.cancel() }

    private fun cache(
        file: File = File(folder.root, "acct/library.json"),
        protected: () -> Set<String> = { emptySet() },
        max: Int = 100,
        legacy: AccountPublications? = null,
    ): LibraryCache {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scopes += it }
        return LibraryCache(file, scope, protected, legacy, maxTitles = max, writeDelayMs = 10)
    }

    private fun title(
        id: String,
        name: String = id,
        author: String? = null,
        type: BookType = BookType.EBOOK,
        status: ReadingStatus? = null,
    ) = Publication(id, name, author, bookType = type, readingStatus = status)

    @Test
    fun `an older reply never replaces newer details`() = runBlocking {
        val library = cache()
        library.remember(title("a", "New title", status = ReadingStatus.FINISHED), observedAt = 200)
        library.recordPage(LibraryQuery(), null, LibraryPage(listOf(title("a", "Old title"))), observedAt = 100)
        val a = library.recall("a")!!
        assertEquals("New title", a.title)
        assertEquals(ReadingStatus.FINISHED, a.status)
        library.remember(title("a", "Newest"), observedAt = 300)
        assertEquals("Newest", library.recall("a")!!.title)
    }

    @Test
    fun `filters by type, status and accent-insensitive title or author words`() = runBlocking {
        val library = cache()
        library.recordPage(
            LibraryQuery(),
            null,
            LibraryPage(
                listOf(
                    title("1", "Gösta Berling's Saga", "Selma Lagerlöf", status = ReadingStatus.FINISHED),
                    title("2", "Nils Holgersson", "Selma Lagerlöf", type = BookType.AUDIOBOOK),
                    title("3", "Middlemarch", "George Eliot", status = ReadingStatus.IN_PROGRESS),
                ),
                nextCursor = "more",
            ),
            observedAt = 10,
        )
        assertEquals(listOf("1", "2"), library.query(LibraryQuery(text = "lagerlof")).items.map { it.id })
        assertEquals(listOf("1"), library.query(LibraryQuery(text = "SELMA gosta")).items.map { it.id })
        assertEquals(listOf("2"), library.query(LibraryQuery(filter = LibraryFilter.AUDIOBOOK)).items.map { it.id })
        assertEquals(listOf("3"), library.query(LibraryQuery(status = ReadingStatus.IN_PROGRESS)).items.map { it.id })
        assertEquals(listOf("2"), library.query(LibraryQuery(status = ReadingStatus.UNREAD)).items.map { it.id })
        assertTrue(library.query(LibraryQuery(text = "dune")).items.isEmpty())
    }

    @Test
    fun `orders by title, or by the server's recent order across pages and passes`() = runBlocking {
        val library = cache()
        val recent = LibraryQuery()
        library.recordPage(recent, null, LibraryPage(listOf(title("c", "Circe"), title("a", "Anathem")), nextCursor = "p2"), observedAt = 100)
        library.recordPage(recent, "p2", LibraryPage(listOf(title("b", "beloved"))), observedAt = 101)
        // Seen only through a filtered search: it has no server rank, so it comes after ranked titles.
        library.recordPage(LibraryQuery(text = "z"), null, LibraryPage(listOf(title("z", "Zami"))), observedAt = 150)
        assertEquals(listOf("c", "a", "b", "z"), library.query(recent).items.map { it.id })
        assertEquals(listOf("a", "b", "c", "z"), library.query(LibraryQuery(sort = LibrarySort.TITLE)).items.map { it.id })

        // A newer first page outranks the older pass.
        library.recordPage(recent, null, LibraryPage(listOf(title("n", "New")), nextCursor = "q2"), observedAt = 200)
        assertEquals(listOf("n", "c", "a", "b", "z"), library.query(recent).items.map { it.id })
    }

    @Test
    fun `coverage is complete only after one whole unfiltered pass, which also drops removed titles`() = runBlocking {
        val library = cache(protected = { setOf("kept-download") })
        library.remember(title("gone"), observedAt = 50)
        library.remember(title("kept-download"), observedAt = 50)
        library.recordPage(LibraryQuery(), null, LibraryPage(listOf(title("a")), nextCursor = "p2"), observedAt = 100)
        assertFalse(library.coverage.value.isComplete)
        // A filtered listing that ends says nothing about the whole library.
        library.recordPage(LibraryQuery(filter = LibraryFilter.EBOOK), null, LibraryPage(listOf(title("a"))), observedAt = 110)
        assertFalse(library.coverage.value.isComplete)

        library.recordPage(LibraryQuery(), "p2", LibraryPage(listOf(title("b"))), observedAt = 120)
        val coverage = library.coverage.value
        assertEquals(100L, coverage.completeAsOfEpochMs)
        assertEquals(120L, coverage.lastOnlineAtEpochMs)
        val ids = library.query(LibraryQuery()).items.map { it.id }.toSet()
        assertEquals(setOf("a", "b", "kept-download"), ids)
        assertNull(library.recall("gone"))
    }

    @Test
    fun `a cursor from another pass or process doesn't count toward completeness`() = runBlocking {
        val library = cache()
        library.recordPage(LibraryQuery(), "unknown-cursor", LibraryPage(listOf(title("x"))), observedAt = 10)
        assertFalse(library.coverage.value.isComplete)
        assertEquals(listOf("x"), library.query(LibraryQuery()).items.map { it.id })
    }

    @Test
    fun `the bound evicts least recently seen titles but never downloads`() = runBlocking {
        val library = cache(protected = { setOf("d") }, max = 3)
        library.recordPage(LibraryQuery(), null, LibraryPage(listOf(title("d"), title("a"))), observedAt = 1)
        assertTrue(library.coverage.value.isComplete)
        library.remember(title("b"), observedAt = 2)
        library.remember(title("c"), observedAt = 3)
        library.remember(title("e"), observedAt = 4)
        val ids = library.query(LibraryQuery()).items.map { it.id }.toSet()
        assertEquals(setOf("d", "c", "e"), ids)
        assertFalse("Evicting means it no longer covers everything", library.coverage.value.isComplete)
    }

    @Test
    fun `downloads appear offline even when the cache never saw them`() = runBlocking {
        val library = cache()
        library.remember(title("a", "Alpha"), observedAt = 5)
        val download = title("dl", "Downloaded", type = BookType.AUDIOBOOK)
        val result = library.query(LibraryQuery(filter = LibraryFilter.AUDIOBOOK), extra = listOf(download, title("a", "Stale copy")))
        assertEquals(listOf("dl"), result.items.map { it.id })
        assertEquals("Alpha", library.query(LibraryQuery(), extra = listOf(title("a", "Stale copy"))).items.single { it.id == "a" }.title)
    }

    @Test
    fun `persists across instances, and nothing is written after close`() = runBlocking {
        val file = File(folder.root, "acct/library.json")
        val first = cache(file)
        first.recordPage(LibraryQuery(), null, LibraryPage(listOf(title("a"), title("b"))), observedAt = 100)
        first.close()
        val second = cache(file)
        assertEquals(listOf("a", "b"), second.query(LibraryQuery()).items.map { it.id })
        assertEquals(100L, second.coverage.value.completeAsOfEpochMs)

        // Sign-out: close, wipe, and a late write must not recreate the account folder.
        second.close()
        file.parentFile!!.deleteRecursively()
        second.remember(title("late"), observedAt = 200)
        delay(100)
        assertFalse(file.parentFile!!.exists())
    }

    @Test
    fun `an unreadable cache is set aside and starts empty`() = runBlocking {
        val file = File(folder.root, "acct/library.json").apply { parentFile!!.mkdirs(); writeText("{ broken") }
        val library = cache(file)
        assertTrue(library.query(LibraryQuery()).items.isEmpty())
        assertTrue(File(file.path + ".unreadable").isFile)
        library.remember(title("a"), observedAt = 1)
        library.flush()
        assertTrue(file.readText().contains("\"a\""))
    }

    @Test
    fun `details remembered by older versions are still recalled`() = runBlocking {
        val account = File(folder.root, "acct")
        val legacy = AccountPublications(account)
        legacy.remember(title("old", "Remembered before"))
        val library = cache(File(account, "library.json"), legacy = legacy)
        assertEquals("Remembered before", library.recall("old")!!.title)
        assertNull(library.recall("never"))
    }

    @Test
    fun `abandoned first pages don't pile up, and the latest pass can still finish`() = runBlocking {
        val library = cache()
        repeat(50) { library.recordPage(LibraryQuery(), null, LibraryPage(listOf(title("a")), nextCursor = "c$it"), observedAt = it.toLong()) }
        library.recordPage(LibraryQuery(), "c0", LibraryPage(listOf(title("b"))), observedAt = 60)
        assertFalse("A long-abandoned pass was dropped", library.coverage.value.isComplete)
        library.recordPage(LibraryQuery(), "c49", LibraryPage(listOf(title("b"))), observedAt = 61)
        assertEquals(49L, library.coverage.value.completeAsOfEpochMs)
    }

    @Test
    fun `normalizes punctuation and case for search`() {
        assertEquals("o brien s cafe", LibraryCache.normalize("O’Brien's Café"))
    }
}
