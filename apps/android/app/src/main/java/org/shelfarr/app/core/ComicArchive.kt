package org.shelfarr.app.core

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.zip.CRC32
import java.util.zip.DataFormatException
import java.util.zip.Inflater
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** A file this app downloaded but cannot safely read. Shown to the reader; never retried silently. */
class UnreadableFile(message: String, cause: Throwable? = null) : Exception(message, cause)

/** The server no longer offers this exact file generation (410). Anything pinned to it is stale. */
class GenerationGone : Exception("This file was replaced on the server")

/** One page of a CBZ generation, exactly as `GET …/assets/:asset_id/reading_order` lists it. */
@Serializable
data class ReadingOrderItem(
    /** One-based place in the reading order. */
    val position: Int,
    /** The ZIP entry name, URL-escaped. Also the locator `href` for this page. */
    val href: String,
    @SerialName("media_type") val mediaType: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    @SerialName("compressed_size") val compressedSize: Long,
    @SerialName("compression_method") val compressionMethod: Int,
    @SerialName("local_header_offset") val localHeaderOffset: Long,
    /** Eight lower-case hex digits. */
    val crc32: String,
)

@Serializable
data class ReadingOrder(
    @SerialName("asset_id") val assetId: String,
    val format: String,
    val items: List<ReadingOrderItem>,
)

/** A validated page: [ReadingOrderItem] with its decoded entry name. */
data class ComicPage(
    val position: Int,
    val href: String,
    val mediaType: String,
    val name: String,
    val nameBytes: ByteArray,
    val sizeBytes: Long,
    val compressedSize: Long,
    val method: Int,
    val localHeaderOffset: Long,
    val crc: Long,
) {
    override fun equals(other: Any?): Boolean = other is ComicPage && other.position == position && other.href == href
    override fun hashCode(): Int = 31 * position + href.hashCode()
}

/**
 * Bounds shared with the server's archive inspection. The client accepts at least
 * what the server can produce, and never more than it can bound in memory.
 */
object ComicLimits {
    const val MAX_ENTRIES = 10_000
    const val MAX_IMAGE_BYTES = 32L shl 20
    const val MAX_TOTAL_IMAGE_BYTES = 2L shl 30
    const val MAX_DIRECTORY_BYTES = 8L shl 20
    const val MAX_ORDER_RESPONSE_BYTES = 8L shl 20
    const val MAX_NAME_BYTES = 2048
    private const val EOCD_SEARCH = 22 + 0xFFFF

    internal val IMAGE_TYPES = mapOf("jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "webp" to "image/webp")

    internal fun eocdSearch(size: Long): Int = minOf(size, EOCD_SEARCH.toLong()).toInt()
}

/**
 * Checks a reading order against the asset it claims to describe, without touching the
 * archive. Positions must run 1…N in order, every href must be a canonical escape of a
 * safe ZIP-root name, and sizes, methods and CRCs must be ones this reader can verify.
 */
fun ReadingOrder.validate(asset: Asset): List<ComicPage> {
    fun bad(reason: String): Nothing = throw UnreadableFile("The comic's page list is unusable: $reason")
    if (assetId != asset.id) bad("it describes a different file")
    if (format != ReadingFormat.CBZ.wire) bad("it isn't a CBZ page list")
    if (items.isEmpty()) bad("it lists no pages")
    if (items.size > ComicLimits.MAX_ENTRIES) bad("it lists too many pages")
    asset.pageCount?.let { if (it != items.size) bad("it disagrees with the page count") }
    val names = HashSet<String>()
    var total = 0L
    return items.mapIndexed { index, item ->
        if (item.position != index + 1) bad("pages are out of order")
        val bytes = decodeHref(item.href) ?: bad("a page name isn't a canonical escape")
        val name = decodeName(bytes) ?: bad("a page name is unsafe")
        if (!names.add(name)) bad("a page is listed twice")
        val type = ComicLimits.IMAGE_TYPES[name.substringAfterLast('.', "").lowercase()]
        if (type == null || type != item.mediaType) bad("a page isn't a JPEG, PNG or WebP image")
        if (item.sizeBytes !in 1..ComicLimits.MAX_IMAGE_BYTES) bad("a page is larger than 32 MiB")
        total += item.sizeBytes
        if (total > ComicLimits.MAX_TOTAL_IMAGE_BYTES) bad("the pages exceed 2 GiB")
        if (item.compressionMethod != 0 && item.compressionMethod != 8) bad("a page uses unsupported compression")
        if (item.compressedSize < 0 || (item.compressionMethod == 0 && item.compressedSize != item.sizeBytes)) bad("a page size is inconsistent")
        // Deflate never needs much more than its input; anything larger is not a real page.
        if (item.compressedSize > item.sizeBytes + (item.sizeBytes shr 6) + 1024) bad("a page size is inconsistent")
        if (item.localHeaderOffset < 0 || item.localHeaderOffset > 0xFFFF_FFFFL) bad("a page offset is out of range")
        if (asset.sizeBytes > 0 && item.localHeaderOffset + 30 + item.compressedSize > asset.sizeBytes) bad("a page lies outside the file")
        if (!CRC.matches(item.crc32)) bad("a page checksum is malformed")
        ComicPage(
            position = item.position,
            href = item.href,
            mediaType = item.mediaType,
            name = name,
            nameBytes = bytes,
            sizeBytes = item.sizeBytes,
            compressedSize = item.compressedSize,
            method = item.compressionMethod,
            localHeaderOffset = item.localHeaderOffset,
            crc = item.crc32.toLong(16),
        )
    }
}

private val CRC = Regex("[0-9a-f]{8}")
private const val HEX = "0123456789abcdef"
private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"

private fun hexDigit(char: Char): Int = if (char.code < 128) HEX.indexOf(char.lowercaseChar()) else -1

/** Percent-decodes [href], accepting only the server's canonical escaping (everything else escaped). */
internal fun decodeHref(href: String): ByteArray? {
    if (href.isEmpty() || href.length > ComicLimits.MAX_NAME_BYTES * 3) return null
    val out = java.io.ByteArrayOutputStream(href.length)
    var index = 0
    while (index < href.length) {
        val char = href[index]
        when {
            char == '%' -> {
                if (index + 2 >= href.length) return null
                val high = hexDigit(href[index + 1])
                val low = hexDigit(href[index + 2])
                if (high < 0 || low < 0) return null
                val value = high * 16 + low
                // An escaped unreserved character is a second spelling of the same name.
                if (value.toChar() in UNRESERVED) return null
                out.write(value)
                index += 3
            }
            char in UNRESERVED -> {
                out.write(char.code)
                index++
            }
            else -> return null
        }
    }
    return out.toByteArray()
}

/** Strict UTF-8 and the same unsafe-name rules the server applies. Null when unsafe. */
internal fun decodeName(bytes: ByteArray): String? {
    if (bytes.isEmpty() || bytes.size > ComicLimits.MAX_NAME_BYTES) return null
    val name = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        return null
    }
    if (name.startsWith("/")) return null
    if (name.any { it == '\\' || it == ':' || it.code < 0x20 || it.code == 0x7f }) return null
    if (name.split('/').any { it == "." || it == ".." }) return null
    return name
}

private class CentralEntry(
    val name: String,
    val flags: Int,
    val method: Int,
    val crc: Long,
    val compressedSize: Long,
    val size: Long,
    val localHeaderOffset: Long,
)

/**
 * A downloaded CBZ, read one page at a time. Opening checks the archive's own ZIP32
 * central directory against the server's reading order: exactly the same image entries,
 * sizes, methods, offsets and CRCs, with no encrypted, split, ZIP64, symlinked or
 * traversing entries. Nothing is ever extracted to disk. Pages are inflated into memory
 * only up to their declared size and must match their CRC.
 *
 * Reads are positional, so several pages may be read at once from different threads.
 */
class ComicArchive private constructor(
    private val file: RandomAccessFile,
    val pages: List<ComicPage>,
    private val dataStarts: LongArray,
) : Closeable {
    private val channel: FileChannel = file.channel

    val pageCount: Int get() = pages.size

    /** The page's image bytes. Throws [UnreadableFile] for anything that doesn't verify. */
    fun pageBytes(index: Int): ByteArray {
        val page = pages[index]
        val start = dataStarts[index]
        val output = ByteArray(page.sizeBytes.toInt())
        try {
            if (page.method == 0) {
                readFully(start, output, 0, output.size)
            } else {
                inflate(start, page, output)
            }
        } catch (error: IOException) {
            throw UnreadableFile("Page ${page.position} couldn't be read from this file", error)
        }
        val crc = CRC32().apply { update(output) }.value
        if (crc != page.crc) throw UnreadableFile("Page ${page.position} is damaged (its checksum doesn't match)")
        return output
    }

    private fun inflate(start: Long, page: ComicPage, output: ByteArray) {
        val inflater = Inflater(true)
        try {
            val input = ByteArray(64 * 1024)
            val scratch = ByteArray(1)
            var position = start
            var remaining = page.compressedSize
            var produced = 0
            var padded = false
            while (!inflater.finished()) {
                if (inflater.needsDictionary()) throw UnreadableFile("Page ${page.position} uses an unsupported compression feature")
                if (inflater.needsInput()) {
                    when {
                        remaining > 0 -> {
                            val count = minOf(remaining, input.size.toLong()).toInt()
                            readFully(position, input, 0, count)
                            position += count
                            remaining -= count
                            inflater.setInput(input, 0, count)
                        }
                        // Raw inflate may need one byte past the stream to see its end.
                        !padded -> {
                            padded = true
                            inflater.setInput(scratch, 0, 1)
                        }
                        else -> throw UnreadableFile("Page ${page.position} is truncated")
                    }
                    continue
                }
                val count = if (produced < output.size) {
                    inflater.inflate(output, produced, output.size - produced)
                } else {
                    inflater.inflate(scratch, 0, 1)
                }
                if (produced >= output.size && count > 0) throw UnreadableFile("Page ${page.position} is larger than its declared size")
                produced += count
            }
            if (produced != output.size || remaining != 0L) throw UnreadableFile("Page ${page.position} doesn't match its declared size")
        } catch (error: DataFormatException) {
            throw UnreadableFile("Page ${page.position} is damaged", error)
        } finally {
            inflater.end()
        }
    }

    private fun readFully(position: Long, target: ByteArray, offset: Int, length: Int) = readFully(channel, position, target, offset, length)

    override fun close() = file.close()

    companion object {
        /**
         * Opens [archive] for reading in [pages]' order, or throws [UnreadableFile]. Bounded:
         * at most 64 KiB of tail, an 8 MiB directory and 10,000 entries are read.
         */
        fun open(archive: File, pages: List<ComicPage>, expectedSize: Long = 0): ComicArchive {
            val file = try {
                RandomAccessFile(archive, "r")
            } catch (error: IOException) {
                throw UnreadableFile("The comic file is missing", error)
            }
            try {
                val starts = verify(file.channel, pages, expectedSize)
                return ComicArchive(file, pages, starts)
            } catch (error: Throwable) {
                file.close()
                if (error is IOException) throw UnreadableFile("The comic file couldn't be read", error)
                throw error
            }
        }

        private fun bad(reason: String): Nothing = throw UnreadableFile("This comic archive isn't supported: $reason")

        private fun verify(channel: FileChannel, pages: List<ComicPage>, expectedSize: Long): LongArray {
            val size = channel.size()
            if (expectedSize > 0 && size != expectedSize) bad("its size doesn't match the server's")
            if (size < 22) bad("it isn't a ZIP file")
            if (size > ReadingFormat.CBZ.maxBytes) bad("it is larger than 2 GiB")
            val tailLength = ComicLimits.eocdSearch(size)
            val tailStart = size - tailLength
            val tail = ByteArray(tailLength).also { readFully(channel, tailStart, it, 0, tailLength) }
            val end = (tailLength - 22 downTo 0).firstOrNull { tail.u32(it) == 0x06054b50L } ?: bad("it has no ZIP directory")
            val disk = tail.u16(end + 4)
            val directoryDisk = tail.u16(end + 6)
            val diskEntries = tail.u16(end + 8)
            val entries = tail.u16(end + 10)
            val directorySize = tail.u32(end + 12)
            val directoryOffset = tail.u32(end + 16)
            val comment = tail.u16(end + 20)
            val endOffset = tailStart + end
            if (disk != 0 || directoryDisk != 0 || diskEntries != entries) bad("it is split across several files")
            if (entries !in 1..ComicLimits.MAX_ENTRIES) bad("it has too many entries")
            if (directorySize !in (46L * entries)..ComicLimits.MAX_DIRECTORY_BYTES) bad("its directory is oversized")
            if (endOffset >= 20) {
                val locator = ByteArray(4).also { readFully(channel, endOffset - 20, it, 0, 4) }
                if (locator.u32(0) == 0x07064b50L) bad("it is a ZIP64 archive")
            }
            // The directory ends exactly at its end record, and the record ends the file: no
            // self-extracting prefix with shifted offsets and no trailing data.
            if (directoryOffset + directorySize != endOffset || end + 22 + comment != tailLength) bad("its layout is unsupported")

            val directory = ByteArray(directorySize.toInt()).also { readFully(channel, directoryOffset, it, 0, it.size) }
            val central = HashMap<String, CentralEntry>(entries * 2)
            var at = 0
            repeat(entries) {
                if (at + 46 > directory.size || directory.u32(at) != 0x02014b50L) bad("its directory is damaged")
                val madeBy = directory.u16(at + 4)
                val flags = directory.u16(at + 8)
                val method = directory.u16(at + 10)
                val crc = directory.u32(at + 16)
                val compressed = directory.u32(at + 20)
                val uncompressed = directory.u32(at + 24)
                val nameLength = directory.u16(at + 28)
                val extraLength = directory.u16(at + 30)
                val commentLength = directory.u16(at + 32)
                val startDisk = directory.u16(at + 34)
                val external = directory.u32(at + 38)
                val local = directory.u32(at + 42)
                val next = at + 46 + nameLength + extraLength + commentLength
                if (next > directory.size) bad("its directory is damaged")
                val name = decodeName(directory.copyOfRange(at + 46, at + 46 + nameLength)) ?: bad("an entry name is unsafe")
                if (flags and 0x2041 != 0) bad("it is encrypted")
                if (method != 0 && method != 8) bad("an entry uses unsupported compression")
                if (startDisk != 0) bad("it is split across several files")
                if (compressed == 0xFFFF_FFFFL || uncompressed == 0xFFFF_FFFFL || local == 0xFFFF_FFFFL) bad("it is a ZIP64 archive")
                if (madeBy shr 8 == 3 && (external shr 16) and 0xF000 == 0xA000L) bad("it contains a symbolic link")
                if (local + 30 + compressed > directoryOffset) bad("an entry lies outside the archive")
                if (central.put(name, CentralEntry(name, flags, method, crc, compressed, uncompressed, local)) != null) bad("an entry appears twice")
                at = next
            }
            if (at != directory.size) bad("its directory is damaged")

            val images = central.values.filter { entry ->
                !entry.name.endsWith("/") &&
                    entry.name.split('/').none { it.startsWith(".") || it == "__MACOSX" } &&
                    ComicLimits.IMAGE_TYPES.containsKey(entry.name.substringAfterLast('.', "").lowercase())
            }
            if (images.size != pages.size) bad("its pages don't match the server's page list")
            return LongArray(pages.size) { index ->
                val page = pages[index]
                val entry = central[page.name] ?: bad("its pages don't match the server's page list")
                if (entry.crc != page.crc || entry.compressedSize != page.compressedSize || entry.size != page.sizeBytes ||
                    entry.method != page.method || entry.localHeaderOffset != page.localHeaderOffset
                ) bad("page ${page.position} doesn't match the server's page list")
                val header = ByteArray(30).also { readFully(channel, entry.localHeaderOffset, it, 0, 30) }
                val nameLength = header.u16(26)
                val extraLength = header.u16(28)
                if (header.u32(0) != 0x04034b50L || header.u16(6) != entry.flags || header.u16(8) != entry.method ||
                    nameLength != page.nameBytes.size
                ) bad("page ${page.position}'s headers disagree")
                val localName = ByteArray(nameLength).also { readFully(channel, entry.localHeaderOffset + 30, it, 0, nameLength) }
                if (!localName.contentEquals(page.nameBytes)) bad("page ${page.position}'s headers disagree")
                val dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
                if (dataStart + entry.compressedSize > directoryOffset) bad("page ${page.position} lies outside the archive")
                dataStart
            }
        }
    }
}

private fun readFully(channel: FileChannel, position: Long, target: ByteArray, offset: Int, length: Int) {
    val buffer = ByteBuffer.wrap(target, offset, length)
    var at = position
    while (buffer.hasRemaining()) {
        val count = channel.read(buffer, at)
        if (count < 0) throw IOException("Unexpected end of file")
        at += count
    }
}

private fun ByteArray.u16(at: Int): Int = (this[at].toInt() and 0xff) or ((this[at + 1].toInt() and 0xff) shl 8)

private fun ByteArray.u32(at: Int): Long =
    ByteBuffer.wrap(this, at, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFF_FFFFL
