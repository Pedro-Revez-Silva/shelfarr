package org.shelfarr.app.core

import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** PDF and CBZ through the real download engine and reading cache, over real HTTP and files. */
class FixedLayoutFilesTest {
    @get:Rule val folder = TemporaryFolder()
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private val scopes = mutableListOf<CoroutineScope>()
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()
    private val routes = HashMap<String, (RecordedRequest) -> MockResponse>()

    private val epubBytes = ("PK" + "epub-body-".repeat(400)).toByteArray()
    private val pdfBytes = ComicFixtures.pdfBytes()
    private val comic = ComicFixtures.zip(
        listOf(
            ComicFixtures.Entry("01.png", ComicFixtures.page("1")),
            ComicFixtures.Entry("02.jpg", ComicFixtures.page("2"), method = 0),
            ComicFixtures.Entry("ComicInfo.xml", "<ComicInfo/>".toByteArray()),
        ),
    )
    private val epub = Asset("e", "b.epub", "application/epub+zip", "epub", epubBytes.size.toLong(), "/files/e")
    private val pdf = Asset("p", "b.pdf", PDF_MEDIA_TYPE, "pdf", pdfBytes.size.toLong(), "/files/p", position = 1)
    private val cbz = ComicFixtures.asset("z", comic, url = "/files/z", orderUrl = "/api/consumer/v1/library/c/assets/z/reading_order")
    private val epubOnly = Publication("b", "Mixed", bookType = BookType.EBOOK, assets = listOf(epub))
    private val mixed = epubOnly.copy(assets = listOf(epub, pdf))
    private val comicBook = Publication("c", "Comic", bookType = BookType.EBOOK, contentKind = "graphic", assets = listOf(cbz))
    private var publications = mapOf("b" to mixed, "c" to comicBook)

    @Before
    fun setUp() {
        web.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val route = routes[request.target.substringBefore('?')] ?: return MockResponse.Builder().code(404).build()
                return route(request)
            }
        }
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        routes["/files/e"] = { file(epubBytes, "\"e\"") }
        routes["/files/p"] = { file(pdfBytes, "\"p\"") }
        routes["/files/z"] = { file(comic.bytes, "\"z\"") }
        routes[cbz.readingOrderUrl!!] = { json(ApiJson.encodeToString(ComicFixtures.order("z", comic.items))) }
    }

    @After
    fun tearDown() {
        scopes.forEach { it.cancel() }
        web.close()
    }

    private fun file(bytes: ByteArray, etag: String) =
        MockResponse.Builder().code(200).addHeader("ETag", etag).body(Buffer().write(bytes)).build()

    private fun json(body: String) = MockResponse.Builder().code(200).addHeader("Content-Type", "application/json").body(body).build()

    private val root get() = File(folder.root, "acct/downloads")

    private fun manager(): DownloadManager {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO).also { scopes += it }
        return DownloadManager(
            root = root,
            client = buildHttpClient({ Credential(server, "secret") }),
            server = server,
            fetchPublication = { id -> publications[id] ?: throw ApiException.NotFound() },
            scope = scope,
            usableSpace = { Long.MAX_VALUE },
        )
    }

    private fun DownloadManager.await(id: String, vararg states: DownloadState): DownloadRecord = runBlocking {
        withTimeout(15_000) { records.first { it[id]?.state in states } }[id]!!
    }

    private fun paths() = requests.map { it.target.substringBefore('?') }

    @Test
    fun `an EPUB download from before PDF support is kept when the server adds a PDF`() = runBlocking {
        // Download as the previous version did, then strip the field it didn't write.
        publications = mapOf("b" to epubOnly)
        val first = manager()
        first.start()
        first.enqueue(epubOnly)
        val ready = first.await("b", DownloadState.READY)
        val before = first.filesFor(ready)!!.values.single().readBytes()
        first.close()
        val manifest = File(root, "manifest.json")
        val legacy = ApiJson.parseToJsonElement(manifest.readText()).jsonObject.mapValues { (_, record) ->
            JsonObject(record.jsonObject - "format")
        }
        manifest.writeText(ApiJson.encodeToString(JsonObject(legacy)))
        assertFalse(ApiJson.parseToJsonElement(manifest.readText()).jsonObject.getValue("b").jsonObject.containsKey("format"))

        publications = mapOf("b" to mixed)
        requests.clear()
        val next = manager()
        next.start()
        val kept = assertNotNull(next.ready("b")).let { next.ready("b")!! }
        assertEquals(ReadingFormat.EPUB, kept.pinnedFormat)
        assertTrue(kept.matches(mixed))
        // Downloading again (e.g. from an Update tap) changes nothing and fetches no file.
        next.enqueue(mixed)
        val again = next.await("b", DownloadState.READY)
        assertEquals(listOf("e"), again.pinnedAssetIds)
        assertArrayEquals(before, next.filesFor(again)!!.values.single().readBytes())
        assertTrue(paths().toString(), paths().none { it.startsWith("/files/") })
        next.close()
    }

    @Test
    fun `an explicit PDF choice pins the PDF and verifies its header`() = runBlocking {
        val downloads = manager()
        downloads.start()
        downloads.enqueue(mixed, ReadingFormat.PDF)
        val ready = downloads.await("b", DownloadState.READY, DownloadState.FAILED)
        assertEquals(DownloadState.READY, ready.state)
        assertEquals("pdf", ready.format)
        assertEquals(listOf("p"), ready.pinnedAssetIds)
        assertArrayEquals(pdfBytes, downloads.fileFor(ready, "p")!!.readBytes())
        assertFalse(paths().contains("/files/e"))
        // A later plain Download keeps the PDF.
        downloads.enqueue(mixed)
        assertEquals(listOf("p"), downloads.await("b", DownloadState.READY).pinnedAssetIds)
        downloads.close()
    }

    @Test
    fun `a PDF that isn't one, or runs past its size, is never ready`() = runBlocking {
        routes["/files/p"] = { file("PK not a pdf at all".toByteArray().copyOf(pdfBytes.size), "\"p\"") }
        val downloads = manager()
        downloads.start()
        downloads.enqueue(mixed, ReadingFormat.PDF)
        assertEquals(DownloadProblem.INVALID, downloads.await("b", DownloadState.FAILED).problem)
        assertNull(downloads.ready("b"))

        routes["/files/p"] = { file(pdfBytes + ByteArray(4096), "\"p2\"") }
        downloads.retry("b")
        assertEquals(DownloadProblem.INVALID, downloads.await("b", DownloadState.FAILED).problem)
        assertFalse("No oversized part is kept", root.walkTopDown().any { it.name.endsWith(".part") && it.length() > pdfBytes.size })
        downloads.close()
    }

    @Test
    fun `a CBZ is ready only with its verified reading order, which survives a restart`() = runBlocking {
        val downloads = manager()
        downloads.start()
        downloads.enqueue(comicBook)
        val ready = downloads.await("c", DownloadState.READY, DownloadState.FAILED)
        assertEquals(DownloadState.READY, ready.state)
        val order = assertNotNull(downloads.readingOrderFor(ready, "z")).let { downloads.readingOrderFor(ready, "z")!! }
        assertEquals(comic.items, order.items)
        val orderRequest = requests.first { it.target == cbz.readingOrderUrl }
        assertEquals("Bearer secret", orderRequest.headers["Authorization"])
        downloads.close()

        // Offline, from disk: archive and order still open together.
        web.close()
        val reopened = manager()
        reopened.start()
        val record = reopened.ready("c")!!
        val pages = reopened.readingOrderFor(record, "z")!!.validate(cbz)
        ComicArchive.open(reopened.fileFor(record, "z")!!, pages, cbz.sizeBytes).use { archive ->
            assertArrayEquals(ComicFixtures.page("2"), archive.pageBytes(1))
        }
        reopened.close()

        // Without its order, the archive is not a usable download.
        root.walkTopDown().first { it.name.endsWith(".cbz.order.json") }.delete()
        val missing = manager()
        missing.start()
        assertNull(missing.ready("c"))
        assertEquals(DownloadProblem.MISSING, missing.record("c")!!.problem)
        missing.close()
    }

    @Test
    fun `a replaced generation or an order that disagrees with the archive never becomes ready`() = runBlocking {
        routes[cbz.readingOrderUrl!!] = { MockResponse.Builder().code(410).build() }
        val downloads = manager()
        downloads.start()
        downloads.enqueue(comicBook)
        assertEquals(DownloadProblem.CHANGED, downloads.await("c", DownloadState.FAILED).problem)

        val wrong = comic.items.mapIndexed { i, item -> if (i == 0) item.copy(crc32 = "00000000") else item }
        routes[cbz.readingOrderUrl!!] = { json(ApiJson.encodeToString(ComicFixtures.order("z", wrong))) }
        downloads.retry("c")
        assertEquals(DownloadProblem.INVALID, downloads.await("c", DownloadState.FAILED).problem)

        publications = mapOf("c" to comicBook.copy(assets = listOf(cbz.copy(readingOrderUrl = "https://elsewhere.example/ro"))))
        downloads.enqueue(publications.getValue("c"))
        assertEquals(DownloadProblem.INVALID, downloads.await("c", DownloadState.FAILED).problem)
        assertNull(downloads.ready("c"))
        downloads.close()
    }

    @Test
    fun `the reading cache keeps PDFs and comics apart from EPUBs, and comics open offline with their order`() = runBlocking {
        val cache = EpubCache(File(folder.root, "cache"), buildHttpClient({ Credential(server, "secret") }))
        val book = cache.obtain("acct", server, pdf)
        assertEquals("book.pdf", book.file.name)
        assertNull(book.order)

        val online = cache.obtain("acct", server, cbz)
        assertEquals("book.cbz", online.file.name)
        assertEquals(comic.items, online.order!!.items)
        assertFalse(online.unverified)

        web.close()
        val offline = cache.obtain("acct", server, cbz)
        assertTrue(offline.unverified)
        assertEquals(comic.items, offline.order!!.items)

        File(online.file.parentFile, "order.json").delete()
        val failure = runCatching { cache.obtain("acct", server, cbz) }.exceptionOrNull()
        assertTrue("$failure", failure is ApiException.Offline)
    }

    @Test
    fun `the reading cache refuses a file in the wrong format`() = runBlocking {
        routes["/files/p"] = { file(epubBytes.copyOf(pdfBytes.size), "\"p\"") }
        val cache = EpubCache(File(folder.root, "cache"), buildHttpClient({ Credential(server, "secret") }))
        val failure = runCatching { cache.obtain("acct", server, pdf) }.exceptionOrNull()
        assertTrue("$failure", failure is ApiException.Protocol)
        val oversized = runCatching { cache.obtain("acct", server, pdf.copy(sizeBytes = ReadingFormat.PDF.maxBytes + 1)) }.exceptionOrNull()
        assertTrue("$oversized", oversized is UnreadableFile)
    }
}
