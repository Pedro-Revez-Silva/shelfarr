package org.shelfarr.app.core

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.shelfarr.app.core.ComicFixtures.Entry

class ComicArchiveTest {
    @get:Rule val folder = TemporaryFolder()

    private val pages = listOf(
        Entry("001.png", ComicFixtures.page("one"), method = 8),
        Entry("chapter 2/002.jpg", ComicFixtures.page("two"), method = 0),
        Entry("ComicInfo.xml", "<ComicInfo/>".toByteArray()),
        Entry("café/003.webp", ComicFixtures.page("three")),
    )

    private fun write(built: ComicFixtures.Built): File = folder.newFile().apply { writeBytes(built.bytes) }

    private fun open(built: ComicFixtures.Built, items: List<ReadingOrderItem> = built.items): ComicArchive {
        val asset = ComicFixtures.asset("a1", built)
        return ComicArchive.open(write(built), ComicFixtures.order("a1", items).validate(asset.copy(pageCount = items.size)), built.bytes.size.toLong())
    }

    private fun refused(reason: String, block: () -> Unit) {
        try {
            block()
            fail("Expected refusal: $reason")
        } catch (error: UnreadableFile) {
            assertTrue("${error.message} should mention $reason", error.message.orEmpty().contains(reason))
        }
    }

    @Test
    fun `reads stored and deflated pages in the server's order, with escaped names`() {
        val built = ComicFixtures.zip(pages)
        assertEquals(listOf("001.png", "chapter%202/002.jpg", "caf%C3%A9/003.webp"), built.items.map { it.href })
        open(built).use { archive ->
            assertEquals(3, archive.pageCount)
            assertArrayEquals(ComicFixtures.page("one"), archive.pageBytes(0))
            assertArrayEquals(ComicFixtures.page("two"), archive.pageBytes(1))
            assertArrayEquals(ComicFixtures.page("three"), archive.pageBytes(2))
            assertEquals("café/003.webp", archive.pages[2].name)
        }
    }

    @Test
    fun `the reading order must describe exactly this asset and be well formed`() {
        val built = ComicFixtures.zip(pages)
        val asset = ComicFixtures.asset("a1", built)
        fun bad(reason: String, transform: (List<ReadingOrderItem>) -> List<ReadingOrderItem>) =
            refused(reason) { ComicFixtures.order("a1", transform(built.items)).validate(asset.copy(pageCount = null)) }

        refused("different file") { ComicFixtures.order("other", built.items).validate(asset) }
        refused("isn't a CBZ") { ReadingOrder("a1", "pdf", built.items).validate(asset) }
        refused("page count") { ComicFixtures.order("a1", built.items).validate(asset.copy(pageCount = 2)) }
        bad("no pages") { emptyList() }
        bad("out of order") { it.reversed() }
        bad("out of order") { it.mapIndexed { i, item -> item.copy(position = i) } }
        bad("listed twice") { items -> items.mapIndexed { i, item -> if (i == 1) items[0].copy(position = 2) else item } }
        bad("canonical") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "%30%30%31.png") else item } }
        bad("canonical") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "chapter 2/002.jpg") else item } }
        bad("canonical") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "%G1.png") else item } }
        bad("unsafe") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "../001.png") else item } }
        bad("unsafe") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "/001.png") else item } }
        bad("unsafe") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "a%5C001.png") else item } }
        bad("unsafe") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "a%00.png") else item } }
        bad("unsafe") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "%FF.png") else item } }
        bad("JPEG, PNG or WebP") { it.mapIndexed { i, item -> if (i == 0) item.copy(mediaType = "image/jpeg") else item } }
        bad("JPEG, PNG or WebP") { it.mapIndexed { i, item -> if (i == 0) item.copy(href = "001.gif", mediaType = "image/gif") else item } }
        bad("32 MiB") { it.mapIndexed { i, item -> if (i == 0) item.copy(sizeBytes = (32L shl 20) + 1) else item } }
        bad("unsupported compression") { it.mapIndexed { i, item -> if (i == 0) item.copy(compressionMethod = 12) else item } }
        bad("inconsistent") { it.mapIndexed { i, item -> if (i == 1) item.copy(compressedSize = item.sizeBytes - 1) else item } }
        bad("checksum") { it.mapIndexed { i, item -> if (i == 0) item.copy(crc32 = item.crc32.uppercase().replace('A', 'Z')) else item } }
        bad("outside the file") { it.mapIndexed { i, item -> if (i == 0) item.copy(localHeaderOffset = built.bytes.size.toLong()) else item } }
        bad("too many pages") { item -> List(ComicLimits.MAX_ENTRIES + 1) { i -> item[0].copy(position = i + 1, href = "p$i.png") } }
    }

    @Test
    fun `canonical escapes decode once, and an escaped unreserved character is a second spelling`() {
        assertArrayEquals("a b/ü.png".toByteArray(), decodeHref("a%20b/%C3%BC.png"))
        assertArrayEquals("a b".toByteArray(), decodeHref("a%20b"))
        assertNull(decodeHref("%41.png"))
        assertNull(decodeHref("a%2"))
        assertNull(decodeHref("a?b"))
        assertNull(decodeHref("a%٣٣b"))
        assertNull(decodeName("../x".toByteArray()))
        assertNull(decodeName("a/./x".toByteArray()))
        assertNull(decodeName("c:x".toByteArray()))
    }

    @Test
    fun `refuses encrypted, symlinked, duplicate, ZIP64, prefixed and trailing archives`() {
        refused("encrypted") { open(ComicFixtures.zip(pages.mapIndexed { i, e -> if (i == 0) e.copy(flags = 1) else e })) }
        refused("encrypted") { open(ComicFixtures.zip(pages.mapIndexed { i, e -> if (i == 2) e.copy(flags = 0x40) else e })) }
        refused("symbolic link") {
            open(ComicFixtures.zip(pages + Entry("link.xml", "001.png".toByteArray(), method = 0, madeBy = 3 shl 8, external = 0xA1FFL shl 16)))
        }
        refused("appears twice") {
            val built = ComicFixtures.zip(pages + Entry("ComicInfo.xml", "dup".toByteArray()))
            open(built)
        }
        refused("ZIP64") { open(ComicFixtures.zip(pages, zip64Locator = true)) }
        refused("layout") { open(ComicFixtures.zip(pages, trailing = "junk".toByteArray())) }
        refused("unsupported compression") { open(ComicFixtures.zip(pages.mapIndexed { i, e -> if (i == 2) e.copy(method = 14) else e })) }
        refused("unsafe") { open(ComicFixtures.zip(pages + Entry("../escape.xml", "x".toByteArray()))) }
    }

    @Test
    fun `a stub prepended without moving the offsets is refused`() {
        val plain = ComicFixtures.zip(pages)
        val stubbed = ComicFixtures.Built(ByteArray(64) { 0x4d } + plain.bytes, plain.items)
        refused("layout") { open(stubbed) }
        // A prefix whose offsets were moved with it is a consistent archive and reads normally.
        val moved = ComicFixtures.zip(pages, prefix = ByteArray(64) { 0x4d })
        open(moved).use { assertArrayEquals(ComicFixtures.page("one"), it.pageBytes(0)) }
    }

    @Test
    fun `the archive's own directory must agree with the server's page list`() {
        val built = ComicFixtures.zip(pages)
        refused("don't match") { open(built, built.items.take(2)) }
        refused("doesn't match") { open(built, built.items.mapIndexed { i, item -> if (i == 0) item.copy(crc32 = "00000000") else item }) }
        refused("doesn't match") { open(built, built.items.mapIndexed { i, item -> if (i == 1) item.copy(localHeaderOffset = 0) else item }) }
        refused("don't match") {
            val other = ComicFixtures.zip(pages.map { if (it.name == "001.png") it.copy(name = "000.png") else it })
            open(built, other.items)
        }
        // The local header names a different file than the directory.
        refused("headers disagree") { open(ComicFixtures.zip(pages.mapIndexed { i, e -> if (i == 0) e.copy(localName = "002.png") else e })) }
        refused("its size doesn't match") {
            ComicArchive.open(write(built), ComicFixtures.order("a1", built.items).validate(ComicFixtures.asset("a1", built)), built.bytes.size + 1L)
        }
        refused("no ZIP directory") {
            val cut = ComicFixtures.Built(built.bytes.copyOf(built.bytes.size - 10), built.items)
            open(cut)
        }
    }

    @Test
    fun `damaged or oversized page data fails visibly, page by page`() {
        val original = ComicFixtures.zip(pages)
        // Flip one byte inside the stored page: it opens, but that page fails its CRC.
        val stored = original.items[1]
        val damaged = original.bytes.copyOf().also { bytes ->
            val at = (stored.localHeaderOffset + 30 + "chapter 2/002.jpg".toByteArray().size + 5).toInt()
            bytes[at] = (bytes[at] + 1).toByte()
        }
        ComicArchive.open(write(ComicFixtures.Built(damaged, original.items)), ComicFixtures.order("a1", original.items).validate(ComicFixtures.asset("a1", original)), damaged.size.toLong()).use { archive ->
            assertArrayEquals(ComicFixtures.page("one"), archive.pageBytes(0))
            refused("checksum") { archive.pageBytes(1) }
        }

        // A page that inflates beyond its declared size is cut off, not trusted.
        val bomb = ComicFixtures.zip(listOf(Entry("001.png", ByteArray(1 shl 20), declaredSize = 1000)))
        open(bomb).use { archive -> refused("larger than its declared size") { archive.pageBytes(0) } }

        // A declared size larger than the data is a truncated page.
        val short = ComicFixtures.zip(listOf(Entry("001.png", ComicFixtures.page("x"), declaredSize = 5_000)))
        open(short).use { archive -> refused("doesn't match its declared size") { archive.pageBytes(0) } }
    }
}
