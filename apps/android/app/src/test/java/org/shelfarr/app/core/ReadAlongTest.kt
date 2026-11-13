package org.shelfarr.app.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The manifest is checked before anything uses it, and every place comes from a real cue. */
class ReadAlongTest {
    private val server = (ServerAddress.parse("https://books.example/shelfarr") as ServerAddress.ParseResult.Valid).address
    private val hrefs = listOf("OEBPS/chapter1.xhtml", "OEBPS/chapter2.xhtml")

    private fun read(body: String, assetId: String = ReadAlongFixtures.EPUB_ID, generation: String? = ReadAlongFixtures.GENERATION) =
        ReadAlong.read(body.byteInputStream(), assetId, generation, server)

    private fun refused(
        body: String,
        kind: ReadAlongRefused.Kind = ReadAlongRefused.Kind.INVALID,
        assetId: String = ReadAlongFixtures.EPUB_ID,
        generation: String? = ReadAlongFixtures.GENERATION,
    ): String {
        try {
            read(body, assetId, generation)
        } catch (error: ReadAlongRefused) {
            assertEquals(error.message, kind, error.kind)
            return error.message.orEmpty()
        }
        fail("accepted: ${body.take(200)}")
        error("unreachable")
    }

    private fun withCue(index: Int, cue: JsonArray) =
        ReadAlongFixtures.overlayManifest(cues = ReadAlongFixtures.CUES.mapIndexed { n, it -> if (n == index) cue else cueJson(it[0], "c${it[1]}", 0, it[2], it[3]) })

    private fun edit(key: String, value: kotlinx.serialization.json.JsonElement) =
        ReadAlongFixtures.overlayManifest { JsonObject(it + (key to value)) }

    @Test
    fun `a genuine media overlay manifest indexes its cues by reading order and by audio time`() {
        val readAlong = read(ReadAlongFixtures.overlayManifest())
        assertEquals(ReadAlongSource.MEDIA_OVERLAY, readAlong.source)
        assertEquals(8, readAlong.cueCount)
        assertEquals(hrefs, readAlong.texts)
        assertEquals(0..4, readAlong.cuesOf(0))
        assertEquals(5..7, readAlong.cuesOf(1))
        // Inside a cue, between cues (nothing highlighted), and the cue reached.
        assertEquals(1, readAlong.cueAt(0, 2_500))
        assertEquals(-1, readAlong.cueAt(0, 3_900))
        assertEquals(1, readAlong.cueReached(0, 3_900))
        assertEquals(-1, readAlong.cueReached(0, -1))
        assertEquals(3_800L, readAlong.nextBoundary(0, 2_500))
        assertEquals(4_000L, readAlong.nextBoundary(0, 3_900))
        assertEquals(15_800L, readAlong.nextBoundary(0, 15_000))
        assertNull(readAlong.nextBoundary(0, 16_000))
        assertEquals(6, readAlong.cueFor(1, "c6"))
        assertEquals(-1, readAlong.cueFor(0, "c6"))
        assertEquals(5, readAlong.firstCueAfter(0))
        assertEquals("Narration covers all 2 sections.", readAlong.coverage.describe())
        // Kept as the server gave it; resolved against this server (and its subpath) when played.
        val url = readAlong.tracks.single().url
        assertEquals("/api/consumer/v1/library/garden-1/assets/epub-garden/read_along/resources/OEBPS/audio/narration.wav", url)
        assertEquals("/shelfarr$url", server.resolve(url)!!.encodedPath)
    }

    @Test
    fun `a heard place is the reached cue's element with its exact offset, and nothing before the first cue`() {
        val readAlong = read(ReadAlongFixtures.overlayManifest())
        val mapper = HeardPlaceMapper(readAlong, hrefs, listOf(0.0, 0.5))
        val places = mapper.placesAt(0, 13_743)
        val locator = requireNotNull(places.ebook).locator!!
        assertEquals("OEBPS/chapter2.xhtml", locator["href"]!!.jsonPrimitive.content)
        val locations = locator["locations"]!!.jsonObject
        assertEquals("c6", locations["fragments"]!!.jsonArray.single().jsonPrimitive.content)
        assertEquals(0.5, locations["totalProgression"]!!.jsonPrimitive.content.toDouble(), 0.0)
        val point = locations["readAlong"]!!.jsonObject
        assertEquals(setOf("generation", "audio", "offset_ms"), point.keys)
        assertEquals(ReadAlongFixtures.GENERATION, point["generation"]!!.jsonPrimitive.content)
        assertEquals(0, point["audio"]!!.jsonPrimitive.int)
        assertEquals(13_743L, point["offset_ms"]!!.jsonPrimitive.long)
        // A media overlay has no separate audiobook to write.
        assertNull(places.audiobook)
        // Never an interpolated place: before any cue there is none.
        val early = read(ReadAlongFixtures.overlayManifest(cues = ReadAlongFixtures.CUES.map { cueJson(it[0], "c${it[1]}", 0, it[2] + 500, it[3] + 500) }))
        assertNull(HeardPlaceMapper(early, hrefs).placesAt(0, 499).ebook)
    }

    @Test
    fun `an imported alignment also names the audiobook file and second`() {
        val readAlong = read(ReadAlongFixtures.importedManifest(), "epub-lighthouse", ReadAlongFixtures.OTHER_GENERATION)
        assertEquals("lighthouse-audio-1", readAlong.pairedPublicationId)
        val places = HeardPlaceMapper(readAlong, hrefs).placesAt(1, 2_250)
        assertEquals(SavedPosition("lh-2", positionSeconds = 2.25), places.audiobook)
        assertEquals("c5", places.ebook!!.locator!!["locations"]!!.jsonObject["fragments"]!!.jsonArray.single().jsonPrimitive.content)
        val heard = readAlong.placeFromAudio("lh-2", 2.25)!!
        assertEquals(NarrationPlace(1, 2_250, 5, exact = true), heard)
        assertNull(readAlong.placeFromAudio("lh-9", 1.0))
        assertNull(readAlong.placeFromAudio("lh-1", Double.NaN))
    }

    @Test
    fun `a saved offset is trusted only for this generation and its own document`() {
        val readAlong = read(ReadAlongFixtures.overlayManifest())
        val mapper = HeardPlaceMapper(readAlong, hrefs)
        fun place(href: String, fragment: String?, generation: String?, offset: Long) = readAlong.placeFromLocator(
            buildJsonObject {
                put("href", href)
                putJsonObject("locations") {
                    fragment?.let { put("fragments", buildJsonArray { add(JsonPrimitive(it)) }) }
                    generation?.let { putJsonObject("readAlong") { put("generation", it); put("audio", 0); put("offset_ms", offset) } }
                }
            },
            mapper::textIndexOf,
        )
        assertEquals(NarrationPlace(0, 13_743, 6, exact = true), place("OEBPS/chapter2.xhtml", "c6", ReadAlongFixtures.GENERATION, 13_743))
        // Another generation's offset falls back to the start of the element's cue.
        assertEquals(NarrationPlace(0, 12_000, 6, exact = false), place("OEBPS/chapter2.xhtml", "c6", ReadAlongFixtures.OTHER_GENERATION, 13_743))
        // An offset whose cue is in another document is not this place either.
        assertEquals(NarrationPlace(0, 2_000, 1, exact = false), place("OEBPS/chapter1.xhtml", "c1", ReadAlongFixtures.GENERATION, 13_743))
        // A reading place with no narrated element gives no narration place.
        assertNull(place("OEBPS/chapter1.xhtml", null, null, 0))
        assertNull(place("OEBPS/notes.xhtml", "c1", ReadAlongFixtures.GENERATION, 2_000))
        // A leading slash or percent-encoding still names the same document.
        assertEquals(1, mapper.textIndexOf("/OEBPS/chapter2.xhtml"))
    }

    @Test
    fun `another edition or generation is changed, not invalid`() {
        refused(ReadAlongFixtures.overlayManifest(generation = ReadAlongFixtures.OTHER_GENERATION), ReadAlongRefused.Kind.CHANGED)
        refused(ReadAlongFixtures.overlayManifest(), ReadAlongRefused.Kind.CHANGED, assetId = "epub-other")
        // Without a known generation (offline, from the stored manifest) any valid one is accepted.
        assertNotNull(read(ReadAlongFixtures.overlayManifest(generation = ReadAlongFixtures.OTHER_GENERATION), generation = null))
    }

    @Test
    fun `broken or unsafe manifests are refused whole`() {
        refused(edit("version", JsonPrimitive(2)))
        refused(edit("version", JsonPrimitive("1")))
        refused(edit("generation", JsonPrimitive("ABC")))
        refused(edit("source", JsonPrimitive("tts")))
        refused(edit("cue_fields", buildJsonArray { listOf("text", "audio", "fragment", "begin_ms", "end_ms").forEach { add(JsonPrimitive(it)) } }))
        refused(edit("text", JsonArray(emptyList())))
        refused(edit("cues", JsonArray(emptyList())))
        refused("{not json")
        // Numbers are numbers: no strings, fractions or out-of-range values.
        refused(withCue(1, buildJsonArray { add(JsonPrimitive("0")); add(JsonPrimitive("c1")); add(JsonPrimitive(0)); add(JsonPrimitive(2_000)); add(JsonPrimitive(3_800)) }))
        refused(withCue(1, buildJsonArray { add(JsonPrimitive(0)); add(JsonPrimitive("c1")); add(JsonPrimitive(0)); add(JsonPrimitive(2_000.5)); add(JsonPrimitive(3_800)) }))
        refused(withCue(1, buildJsonArray { add(JsonPrimitive(0)); add(JsonPrimitive("c1")); add(JsonPrimitive(0)); add(JsonPrimitive(2_000)) }))
        refused(withCue(1, cueJson(2, "c1", 0, 2_000, 3_800)))
        refused(withCue(1, cueJson(0, "c1", 1, 2_000, 3_800)))
        refused(withCue(1, cueJson(0, "", 0, 2_000, 3_800)))
        refused(withCue(1, cueJson(0, "c 1", 0, 2_000, 3_800)))
        refused(withCue(1, cueJson(0, "c1", 0, 3_800, 3_800)))
        refused(withCue(7, cueJson(1, "c7", 0, 14_000, ReadAlongLimits.MAX_MS + 1)))
        // Overlap beyond the 5 ms rounding tolerance, and an open end that isn't last.
        refused(withCue(1, cueJson(0, "c1", 0, 1_700, 3_800)))
        assertEquals(8, read(withCue(1, cueJson(0, "c1", 0, 1_796, 3_800))).cueCount)
        refused(withCue(1, cueJson(0, "c1", 0, 2_000, null)))
        assertEquals(8, read(withCue(7, cueJson(1, "c7", 0, 14_000, null))).cueCount)
        // Canonical reading order: a later document's cue can't come first.
        refused(withCue(0, cueJson(1, "c0", 0, 0, 1_800)))
        // Paths stay inside the package and audio stays on this server.
        for (href in listOf("../chapter1.xhtml", "/OEBPS/chapter1.xhtml", "https://evil.example/c.xhtml", "OEBPS\\c.xhtml", "OEBPS//c.xhtml")) {
            refused(ReadAlongFixtures.overlayManifest().replace("\"OEBPS/chapter1.xhtml\"", JsonPrimitive(href).toString()))
        }
        refused(ReadAlongFixtures.overlayManifest().replace("\"/api/consumer/v1/library/garden-1", "\"https://elsewhere.example/api/consumer/v1/library/garden-1"))
        refused(ReadAlongFixtures.overlayManifest().replace("\"audio/wav\"", "\"text/html\""))
        refused(ReadAlongFixtures.overlayManifest().replace("\"epub_resource\"", "\"publication_asset\""))
        refused(ReadAlongFixtures.overlayManifest(audioSize = 0))
    }

    @Test
    fun `track and cue counts are bounded`() {
        val track = ReadAlongFixtures.overlayManifest().let { ApiJson.parseToJsonElement(it).jsonObject["audio"]!!.jsonArray.single() }
        refused(edit("audio", JsonArray(List(ReadAlongLimits.MAX_TRACKS + 1) { track })))
        assertEquals(ReadAlongLimits.MAX_TRACKS, read(edit("audio", JsonArray(List(ReadAlongLimits.MAX_TRACKS) { track }))).tracks.size)
        val many = buildJsonArray { repeat(ReadAlongLimits.MAX_CUES + 1) { add(cueJson(0, "c$it", 0, it * 10, it * 10 + 5)) } }
        assertTrue(refused(ReadAlongFixtures.overlayManifest(cues = many.map { it as JsonArray })).contains("${ReadAlongLimits.MAX_CUES}"))
        val most = List(ReadAlongLimits.MAX_CUES) { cueJson(0, "c$it", 0, it * 10, it * 10 + 5) }
        assertEquals(ReadAlongLimits.MAX_CUES, read(ReadAlongFixtures.overlayManifest(cues = most)).cueCount)
    }

    @Test
    fun `an imported alignment can't mix audiobooks or kinds`() {
        val manifest = ReadAlongFixtures.importedManifest()
        val generation = ReadAlongFixtures.OTHER_GENERATION
        refused(manifest.replaceFirst("\"lighthouse-audio-1\"", "\"another-audiobook\""), assetId = "epub-lighthouse", generation = generation)
        refused(manifest.replace("\"content_url\":\"/files/lh-1\"", "\"content_url\":\"https://elsewhere.example/lh-1\""), assetId = "epub-lighthouse", generation = generation)
        refused(manifest.replace("\"imported\"", "\"media_overlay\""), assetId = "epub-lighthouse", generation = generation)
        refused(manifest.replace("\"size_bytes\":4000", "\"size_bytes\":\"4000\""), assetId = "epub-lighthouse", generation = generation)
    }

    @Test
    fun `summaries are optional and absent from older servers`() {
        val old = ApiJson.decodeFromString<Asset>("""{"id":"e","format":"epub","content_url":"/c"}""")
        assertNull(old.readAlong)
        val summary = ApiJson.decodeFromString<Asset>(
            """{"id":"e","format":"epub","content_url":"/c","read_along":{"status":"available","source":"media_overlay",
            "generation":"${ReadAlongFixtures.GENERATION}","manifest_url":"/m","coverage":{"complete":false,"text_sections":3,"aligned_sections":2,"cues":9,"audio_ms":1},
            "text_bytes":10,"audio_bytes":20,"future":"ignored"}}""",
        ).readAlong!!
        assertTrue(summary.isAvailable)
        assertEquals("Narration covers 2 of 3 sections; the others are text only.", summary.coverage?.describe())
        for (status in listOf("unaligned", "stale", "invalid", "something-new")) {
            assertFalse(summary.copy(status = status).isAvailable)
        }
        assertFalse(summary.copy(generation = "short").isAvailable)
        assertFalse(summary.copy(source = "tts").isAvailable)
        assertFalse(summary.copy(manifestUrl = null).isAvailable)
        // An existing EPUB opens exactly as before: the summary changes nothing about the file.
        assertEquals(ReadingFormat.EPUB, old.readingFormat)
        assertEquals(old.readingFormat, old.copy(readAlong = summary).readingFormat)
    }

    @Test
    fun `a manifest body larger than the bound is refused while reading`() {
        val head = ReadAlongFixtures.overlayManifest().toByteArray()
        // A valid manifest followed by endless whitespace: never buffered, refused at the bound.
        val endless = object : java.io.InputStream() {
            var position = 0L
            override fun read(): Int = if (position < head.size) head[position++.toInt()].toInt() and 0xff else ' '.code.also { position++ }
        }
        try {
            ReadAlong.read(endless, ReadAlongFixtures.EPUB_ID, null, server)
            fail("an unbounded body was read")
        } catch (_: java.io.IOException) {
            assertTrue(endless.position <= ReadAlongLimits.MAX_MANIFEST_BYTES + 64 * 1024)
        }
        assertEquals(JsonNull, cueJson(0, "x", 0, 0, null)[4])
    }
}
