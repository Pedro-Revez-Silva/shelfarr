package org.shelfarr.app.find

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.PI
import kotlin.math.sin

/**
 * Media written here, byte by byte, for the requesting fixture: an original spoken-length
 * tone as a real PCM WAV file and an original two-chapter EPUB 3. Nothing is copied from
 * any book or recording.
 */
object FixtureMedia {
    const val AUDIO_SECONDS = 30
    private const val RATE = 16_000

    const val OPENING_HEADING = "The lamp is lit at dusk"
    const val SECOND_HEADING = "Morning on the rocks"
    const val OPENING_PARAGRAPHS = 48

    private val LOG_WORDS = (
        "lamp wick oil glass brass bell gull tide swell fog squall rain hail mist calm gale wind " +
        "westerly easterly northerly ketch schooner lugger trawler buoy reef shoal skerry harbour " +
        "pier rope tar salt cod herring kettle bread candle ledger ink quill stair window shutter " +
        "lantern beacon signal flare dusk dawn noon midnight starboard port keel mast spar sail"
    ).split(" ")

    /** 16-bit mono PCM at 16 kHz, a slowly gliding tone so every second sounds different. */
    val wav: ByteArray by lazy {
        val samples = RATE * AUDIO_SECONDS
        val data = ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN)
        data.put("RIFF".toByteArray()).putInt(36 + samples * 2).put("WAVE".toByteArray())
        data.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2).putShort(2).putShort(16)
        data.put("data".toByteArray()).putInt(samples * 2)
        var phase = 0.0
        for (n in 0 until samples) {
            val hertz = 220.0 + 110.0 * (n.toDouble() / samples)
            phase += 2 * PI * hertz / RATE
            data.putShort((5_000 * sin(phase)).toInt().toShort())
        }
        data.array()
    }

    /** Opening chapter long enough for several pages, each paragraph with its own id. */
    val epub: ByteArray by lazy {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            fun entry(name: String, value: String, stored: Boolean = false) {
                val bytes = value.toByteArray()
                val item = ZipEntry(name)
                if (stored) {
                    item.method = ZipEntry.STORED
                    item.size = bytes.size.toLong()
                    item.compressedSize = bytes.size.toLong()
                    item.crc = CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(item)
                zip.write(bytes)
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip", stored = true)
            entry("META-INF/container.xml", """<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            entry("OEBPS/content.opf", """<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:shelfarr:request-fixture</dc:identifier><dc:title>The Lighthouse Keeper</dc:title><dc:creator>Fixture Author</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-09T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>""")
            entry("OEBPS/nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="c1.xhtml">$OPENING_HEADING</a></li><li><a href="c2.xhtml">$SECOND_HEADING</a></li></ol></nav></body></html>""")
            // Varied prose, so the chapter is several Readium positions long: positions are
            // measured from the compressed entry, and repeated sentences compress to one.
            val words = java.util.Random(1858)
            val opening = (0 until OPENING_PARAGRAPHS).joinToString("") { night ->
                val log = (0 until 36).joinToString(" ") { LOG_WORDS[words.nextInt(LOG_WORDS.size)] }
                "<p id=\"keeper-$night\">Night $night. The keeper climbed the ninety steps and wrote: $log.</p>"
            }
            entry("OEBPS/c1.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$OPENING_HEADING</title></head><body><h1>$OPENING_HEADING</h1>$opening</body></html>""")
            entry("OEBPS/c2.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$SECOND_HEADING</title></head><body><h1>$SECOND_HEADING</h1><p id="rocks-0">At first light the keeper walked the rocks and counted the gulls.</p></body></html>""")
        }
        output.toByteArray()
    }
}
