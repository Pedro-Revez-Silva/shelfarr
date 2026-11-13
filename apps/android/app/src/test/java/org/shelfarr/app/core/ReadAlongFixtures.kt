package org.shelfarr.app.core

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Genuine read-along fixtures, as the server builds them (docs/read-along.md): an EPUB 3
 * whose chapters name SMIL Media Overlays over one narration file inside the book, and the
 * manifests for it and for an imported alignment to a separate audiobook. Cue N is
 * `c<N>`: chapter one holds c0–c4, chapter two c5–c7, and cue N runs from 2N s to 2N+1.8 s.
 */
object ReadAlongFixtures {
    const val GENERATION = "1f7d5b1a0e9c4d3b2a19087f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3"
    const val OTHER_GENERATION = "2e8c6a4b2c0e1f3d5b7a9c8e6f4d2b0a1c3e5f7d9b8a6c4e2f0d1b3a5c7e9f8d"
    const val EPUB_ID = "epub-garden"
    val CUES = (0 until 8).map { cue -> listOf(if (cue < 5) 0 else 1, cue, cue * 2_000, cue * 2_000 + 1_800) }

    /** 16 seconds of 8 kHz mono PCM: the audio entry's bytes. */
    val narration: ByteArray by lazy { wav(16_000) }

    fun wav(durationMs: Int, rate: Int = 8_000): ByteArray {
        val samples = rate * durationMs / 1_000
        val data = ByteArray(samples * 2) { index -> if (index % 2 == 0) ((index / 2) % 64).toByte() else 0 }
        val out = ByteArrayOutputStream()
        fun int(value: Int) = out.write(byteArrayOf(value.toByte(), (value shr 8).toByte(), (value shr 16).toByte(), (value shr 24).toByte()))
        fun short(value: Int) = out.write(byteArrayOf(value.toByte(), (value shr 8).toByte()))
        out.write("RIFF".toByteArray()); int(36 + data.size); out.write("WAVEfmt ".toByteArray())
        int(16); short(1); short(1); int(rate); int(rate * 2); short(2); short(16)
        out.write("data".toByteArray()); int(data.size); out.write(data)
        return out.toByteArray()
    }

    fun sentence(cue: Int): String = "Cue ${cue + 1} sounds. " + "word ".repeat(70).trim() + "."

    /** A real EPUB 3. With [overlay], chapters name SMIL overlays and the WAV narration is a stored entry. */
    fun epub(overlay: Boolean = true, audio: ByteArray = narration): ByteArray {
        val docs = listOf("chapter1.xhtml" to (0..4), "chapter2.xhtml" to (5..7))
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            fun put(name: String, bytes: ByteArray, stored: Boolean = false) {
                val entry = ZipEntry(name)
                if (stored) {
                    entry.method = ZipEntry.STORED
                    entry.size = bytes.size.toLong()
                    entry.compressedSize = bytes.size.toLong()
                    entry.crc = CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
            put("mimetype", "application/epub+zip".toByteArray(), stored = true)
            put(
                "META-INF/container.xml",
                """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""".toByteArray(),
            )
            val items = StringBuilder("""<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>""")
            val spine = StringBuilder()
            docs.forEachIndexed { index, (doc, cues) ->
                val mo = if (overlay) """ media-overlay="mo$index"""" else ""
                items.append("""<item id="doc$index" href="$doc" media-type="application/xhtml+xml"$mo/>""")
                spine.append("""<itemref idref="doc$index"/>""")
                val paragraphs = cues.joinToString("") { """<p id="c$it">${sentence(it)}</p>""" }
                put("OEBPS/$doc", """<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter ${index + 1}</title></head><body><h1>Chapter ${index + 1}</h1>$paragraphs</body></html>""".toByteArray())
                if (overlay) {
                    val smil = doc.replace(".xhtml", ".smil")
                    items.append("""<item id="mo$index" href="$smil" media-type="application/smil+xml"/>""")
                    val pars = cues.joinToString("") { cue ->
                        """<par id="par-c$cue"><text src="$doc#c$cue"/><audio src="audio/narration.wav" clipBegin="${cue * 2}s" clipEnd="${cue * 2 + 1.8}s"/></par>"""
                    }
                    put("OEBPS/$smil", """<?xml version="1.0" encoding="UTF-8"?><smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0"><body><seq epub:textref="$doc">$pars</seq></body></smil>""".toByteArray())
                }
            }
            if (overlay) items.append("""<item id="narration" href="audio/narration.wav" media-type="audio/wav"/>""")
            put(
                "OEBPS/content.opf",
                """<?xml version="1.0" encoding="UTF-8"?><package version="3.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:test:garden</dc:identifier><dc:title>The Narrated Garden</dc:title><dc:language>en</dc:language>${if (overlay) """<meta property="media:duration">0:00:16.000</meta>""" else ""}</metadata><manifest>$items</manifest><spine>$spine</spine></package>""".toByteArray(),
            )
            put("OEBPS/nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">Chapter 1</a></li><li><a href="chapter2.xhtml">Chapter 2</a></li></ol></nav></body></html>""".toByteArray())
            if (overlay) put("OEBPS/audio/narration.wav", audio, stored = true)
        }
        return out.toByteArray()
    }

    private fun cue(values: List<Int>): JsonArray = cueJson(values[0], "c${values[1]}", 0, values[2], values[3])

    /** The media overlay manifest for [epub], as the server sends it. */
    fun overlayManifest(
        generation: String = GENERATION,
        assetId: String = EPUB_ID,
        audioSize: Int = narration.size,
        cues: List<JsonArray> = CUES.map(::cue),
        transform: (JsonObject) -> JsonObject = { it },
    ): String = transform(
        buildJsonObject {
            put("version", 1)
            put("generation", generation)
            put("source", "media_overlay")
            put("publication_id", "garden-1")
            put("ebook_asset_id", assetId)
            put("package_path", "OEBPS/content.opf")
            putJsonArray("text") {
                add(buildJsonObject { put("href", "OEBPS/chapter1.xhtml"); put("media_type", "application/xhtml+xml") })
                add(buildJsonObject { put("href", "OEBPS/chapter2.xhtml"); put("media_type", "application/xhtml+xml") })
            }
            putJsonArray("audio") {
                add(
                    buildJsonObject {
                        put("kind", "epub_resource")
                        put("href", "OEBPS/audio/narration.wav")
                        put("media_type", "audio/wav")
                        put("size_bytes", audioSize)
                        put("url", "/api/consumer/v1/library/garden-1/assets/$assetId/read_along/resources/OEBPS/audio/narration.wav")
                    },
                )
            }
            putJsonArray("cue_fields") { listOf("text", "fragment", "audio", "begin_ms", "end_ms").forEach { add(JsonPrimitive(it)) } }
            put("cues", JsonArray(cues))
            putJsonObject("coverage") { put("complete", true); put("text_sections", 2); put("aligned_sections", 2); put("cues", cues.size); put("audio_ms", 14_400) }
            put("resources_bytes", 4_000)
        },
    ).toString()

    /** An imported alignment over a two-file audiobook: c0–c3 in its first file, c4–c7 in its second. */
    fun importedManifest(
        generation: String = OTHER_GENERATION,
        assetId: String = "epub-lighthouse",
        trackSizes: List<Int> = listOf(4_000, 4_000),
    ): String = buildJsonObject {
        put("version", 1)
        put("generation", generation)
        put("source", "imported")
        put("publication_id", "lighthouse-1")
        put("ebook_asset_id", assetId)
        putJsonArray("text") {
            add(buildJsonObject { put("href", "OEBPS/chapter1.xhtml"); put("media_type", "application/xhtml+xml") })
            add(buildJsonObject { put("href", "OEBPS/chapter2.xhtml"); put("media_type", "application/xhtml+xml") })
        }
        putJsonArray("audio") {
            trackSizes.forEachIndexed { index, size ->
                add(
                    buildJsonObject {
                        put("kind", "publication_asset")
                        put("publication_id", "lighthouse-audio-1")
                        put("asset_id", "lh-${index + 1}")
                        put("filename", "Lighthouse ${index + 1}.wav")
                        put("media_type", "audio/wav")
                        put("size_bytes", size)
                        put("url", "/api/consumer/v1/library/lighthouse-1/assets/$assetId/read_along/audio/lh-${index + 1}")
                        put("content_url", "/files/lh-${index + 1}")
                    },
                )
            }
        }
        putJsonArray("cue_fields") { listOf("text", "fragment", "audio", "begin_ms", "end_ms").forEach { add(JsonPrimitive(it)) } }
        put(
            "cues",
            buildJsonArray { (0 until 8).forEach { cue -> add(cueJson(if (cue < 5) 0 else 1, "c$cue", cue / 4, (cue % 4) * 2_000, (cue % 4) * 2_000 + 1_800)) } },
        )
        putJsonObject("coverage") { put("complete", true); put("text_sections", 2); put("aligned_sections", 2); put("cues", 8) }
    }.toString()
}
