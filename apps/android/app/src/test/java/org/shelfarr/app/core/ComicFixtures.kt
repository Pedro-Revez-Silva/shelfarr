package org.shelfarr.app.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32
import java.util.zip.Deflater

/**
 * Builds ZIP archives byte by byte, so tests control every header: valid comics, and
 * the malformed, encrypted, traversing, symlinked and oversized ones a reader must refuse.
 * The reading order is produced the way the server describes it.
 */
object ComicFixtures {
    data class Entry(
        val name: String,
        val data: ByteArray,
        val method: Int = 8,
        val flags: Int = 0,
        val madeBy: Int = 20,
        val external: Long = 0,
        /** A different name in the local header than in the directory. */
        val localName: String? = null,
        /** Overrides the size the directory declares. */
        val declaredSize: Long? = null,
        val crc: Long? = null,
    )

    class Built(val bytes: ByteArray, val items: List<ReadingOrderItem>)

    fun zip(
        entries: List<Entry>,
        prefix: ByteArray = ByteArray(0),
        trailing: ByteArray = ByteArray(0),
        comment: ByteArray = ByteArray(0),
        zip64Locator: Boolean = false,
    ): Built {
        val out = ByteArrayOutputStream()
        out.write(prefix)
        class Written(val entry: Entry, val offset: Long, val crc: Long, val compressed: Int, val size: Long)
        val written = entries.map { entry ->
            val offset = out.size().toLong()
            val payload = if (entry.method == 8) deflate(entry.data) else entry.data
            val crc = entry.crc ?: CRC32().apply { update(entry.data) }.value
            val size = entry.declaredSize ?: entry.data.size.toLong()
            val local = (entry.localName ?: entry.name).toByteArray()
            out.write(le(0x04034b50, 4)); out.write(le(20, 2)); out.write(le(entry.flags.toLong(), 2)); out.write(le(entry.method.toLong(), 2))
            out.write(le(0, 2)); out.write(le(0, 2)); out.write(le(crc, 4)); out.write(le(payload.size.toLong(), 4)); out.write(le(size, 4))
            out.write(le(local.size.toLong(), 2)); out.write(le(0, 2)); out.write(local); out.write(payload)
            Written(entry, offset, crc, payload.size, size)
        }
        val directoryOffset = out.size().toLong()
        written.forEach { item ->
            val name = item.entry.name.toByteArray()
            out.write(le(0x02014b50, 4)); out.write(le(item.entry.madeBy.toLong(), 2)); out.write(le(20, 2))
            out.write(le(item.entry.flags.toLong(), 2)); out.write(le(item.entry.method.toLong(), 2)); out.write(le(0, 2)); out.write(le(0, 2))
            out.write(le(item.crc, 4)); out.write(le(item.compressed.toLong(), 4)); out.write(le(item.size, 4))
            out.write(le(name.size.toLong(), 2)); out.write(le(0, 2)); out.write(le(0, 2)); out.write(le(0, 2)); out.write(le(0, 2))
            out.write(le(item.entry.external, 4)); out.write(le(item.offset, 4)); out.write(name)
        }
        val directorySize = out.size() - directoryOffset
        if (zip64Locator) {
            out.write(le(0x07064b50, 4)); out.write(ByteArray(16))
        }
        out.write(le(0x06054b50, 4)); out.write(le(0, 2)); out.write(le(0, 2))
        out.write(le(entries.size.toLong(), 2)); out.write(le(entries.size.toLong(), 2))
        out.write(le(directorySize, 4)); out.write(le(directoryOffset, 4)); out.write(le(comment.size.toLong(), 2)); out.write(comment)
        out.write(trailing)

        val items = written.filter { item -> ComicLimits.IMAGE_TYPES.containsKey(item.entry.name.substringAfterLast('.', "").lowercase()) && !item.entry.name.endsWith("/") }
            .mapIndexed { index, item ->
                ReadingOrderItem(
                    position = index + 1,
                    href = escape(item.entry.name),
                    mediaType = ComicLimits.IMAGE_TYPES.getValue(item.entry.name.substringAfterLast('.').lowercase()),
                    sizeBytes = item.size,
                    compressedSize = item.compressed.toLong(),
                    compressionMethod = item.entry.method,
                    localHeaderOffset = item.offset,
                    crc32 = "%08x".format(item.crc),
                )
            }
        return Built(out.toByteArray(), items)
    }

    /** The server's escaping: everything but unreserved characters and `/`, as upper-case `%XX`. */
    fun escape(name: String): String = buildString {
        for (byte in name.toByteArray()) {
            val char = (byte.toInt() and 0xff).toChar()
            if (char.isLetterOrDigit() && char.code < 128 || char in "-._~/") append(char) else append("%%%02X".format(byte.toInt() and 0xff))
        }
    }

    fun order(assetId: String, items: List<ReadingOrderItem>) = ReadingOrder(assetId, "cbz", items)

    fun asset(id: String, built: Built, url: String = "/c/$id", orderUrl: String = "/api/consumer/v1/library/p/assets/$id/reading_order") =
        Asset(id, "$id.cbz", CBZ_MEDIA_TYPE, "cbz", built.bytes.size.toLong(), url, pageCount = built.items.size, readingOrderUrl = orderUrl)

    /** Small distinct payloads; the archive layer never decodes images. */
    fun page(label: String, repeat: Int = 200): ByteArray = ("PAGE:$label;").repeat(repeat).toByteArray()

    fun deflate(data: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
        deflater.setInput(data)
        deflater.finish()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (!deflater.finished()) out.write(buffer, 0, deflater.deflate(buffer))
        deflater.end()
        return out.toByteArray()
    }

    private fun le(value: Long, bytes: Int): ByteArray {
        val buffer = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value)
        return buffer.array().copyOf(bytes)
    }

    /** A minimal one-page PDF header and body; enough for format checks, not for rendering. */
    fun pdfBytes(): ByteArray = "%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n".toByteArray()
}
