package org.shelfarr.app.core

import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromStream
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * Read-along (docs/read-along.md): real narration aligned to the exact EPUB on the server.
 *
 * It is a reader feature, not a format. This app declares it with [READER_FEATURES_HEADER]
 * on publication details only; without that header (and from older servers) every
 * projection is exactly what it was, and the book reads as a normal EPUB.
 *
 * Nothing here ever estimates timing. A cue exists only because the manifest names both an
 * element of a text document and an interval of a narration file, and a saved place is only
 * ever the element of a cue that was actually reached.
 */
const val READER_FEATURES_HEADER = "X-Shelfarr-Reader-Features"
const val READER_FEATURES = "read-along"

/** The manifest version this build reads. */
const val READ_ALONG_VERSION = 1

object ReadAlongLimits {
    const val MAX_CUES = 200_000
    const val MAX_TRACKS = 2_000
    /** 48 hours: the longest interval and offset the contract allows. */
    const val MAX_MS = 48 * 3_600_000
    const val MAX_FRAGMENT = 256
    /** Rounded clip values in real overlays can touch; real overlap cannot. */
    const val OVERLAP_TOLERANCE_MS = 5

    /** Far above any real manifest (200,000 short cues are a few MiB), so a hostile body can't fill memory. */
    const val MAX_MANIFEST_BYTES = 48L shl 20
}

private val HEX64 = Regex("[0-9a-f]{64}")

@Serializable
data class ReadAlongCoverage(
    val complete: Boolean = false,
    @SerialName("text_sections") val textSections: Int = 0,
    @SerialName("aligned_sections") val alignedSections: Int = 0,
    @SerialName("unaligned_sections") val unalignedSections: List<String> = emptyList(),
    val cues: Int = 0,
    @SerialName("audio_ms") val audioMs: Long = 0,
) {
    /** A short, honest description of how much of the text has narration. */
    fun describe(): String? {
        if (textSections <= 0) return null
        if (complete || alignedSections >= textSections) {
            return if (textSections == 1) "Narration covers the whole text." else "Narration covers all $textSections sections."
        }
        return "Narration covers $alignedSections of $textSections sections; the others are text only."
    }
}

@Serializable
data class ReadAlongAudiobook(val id: String, val title: String? = null)

/** What the server says about one EPUB asset's read-along, from publication details. */
@Serializable
data class ReadAlongSummary(
    val status: String,
    val source: String? = null,
    val generation: String? = null,
    @SerialName("manifest_url") val manifestUrl: String? = null,
    val coverage: ReadAlongCoverage? = null,
    @SerialName("text_bytes") val textBytes: Long? = null,
    @SerialName("audio_bytes") val audioBytes: Long? = null,
    val reason: String? = null,
    /** An unaligned EPUB whose work has an acquired audiobook names it; an imported alignment names its own. */
    val audiobook: ReadAlongAudiobook? = null,
) {
    val isAvailable: Boolean
        get() = status == AVAILABLE && generation?.matches(HEX64) == true && !manifestUrl.isNullOrBlank() &&
            ReadAlongSource.fromWire(source) != null

    companion object {
        const val AVAILABLE = "available"
        const val UNALIGNED = "unaligned"
        const val STALE = "stale"
        const val INVALID = "invalid"
    }
}

enum class ReadAlongSource(val wire: String) {
    /** EPUB 3 Media Overlays: the narration is inside the EPUB. */
    MEDIA_OVERLAY("media_overlay"),

    /** An alignment imported for a separate audiobook of the same work. */
    IMPORTED("imported"),
    ;

    companion object {
        fun fromWire(value: String?): ReadAlongSource? = entries.firstOrNull { it.wire == value }
    }
}

enum class NarrationKind(val wire: String) {
    /** An entry of the same EPUB, by archive path. */
    EPUB_RESOURCE("epub_resource"),

    /** A file of the paired audiobook publication, fetched with its normal content URL. */
    PUBLICATION_ASSET("publication_asset"),
}

/** One narration file, in the manifest's order (its index is the cue's audio index). */
@Serializable
data class NarrationTrack(
    val index: Int,
    val kind: NarrationKind,
    @SerialName("media_type") val mediaType: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    /** Where to stream it, bound to the manifest generation. */
    val url: String,
    /** Archive path, for [NarrationKind.EPUB_RESOURCE]. */
    val href: String? = null,
    /** The audiobook publication and asset, for [NarrationKind.PUBLICATION_ASSET]. */
    @SerialName("publication_id") val publicationId: String? = null,
    @SerialName("asset_id") val assetId: String? = null,
    val filename: String? = null,
    /** The audiobook asset's normal content URL, for downloading it. */
    @SerialName("content_url") val contentUrl: String? = null,
) {
    val label: String get() = filename ?: href?.substringAfterLast('/') ?: "Narration ${index + 1}"
}

/** Why a manifest can't be used. The book still reads as a normal EPUB. */
class ReadAlongRefused(val kind: Kind, message: String) : Exception(message) {
    enum class Kind {
        /** The manifest itself is broken or unsafe. */
        INVALID,

        /** It belongs to another edition or generation than the one open. */
        CHANGED,
    }
}

@Serializable
private data class TextWire(val href: String? = null, @SerialName("media_type") val mediaType: String? = null)

@Serializable
private data class AudioWire(
    val kind: String? = null,
    val href: String? = null,
    @SerialName("media_type") val mediaType: String? = null,
    @SerialName("size_bytes") val sizeBytes: JsonPrimitive? = null,
    val url: String? = null,
    @SerialName("publication_id") val publicationId: String? = null,
    @SerialName("asset_id") val assetId: String? = null,
    val filename: String? = null,
    @SerialName("content_url") val contentUrl: String? = null,
)

@Serializable
private data class ManifestWire(
    /** Kept as JSON so a quoted "1" is refused rather than read as a number. */
    val version: JsonPrimitive? = null,
    val generation: String? = null,
    val source: String? = null,
    @SerialName("publication_id") val publicationId: String? = null,
    @SerialName("ebook_asset_id") val ebookAssetId: String? = null,
    @SerialName("package_path") val packagePath: String? = null,
    val text: List<TextWire> = emptyList(),
    val audio: List<AudioWire> = emptyList(),
    @SerialName("cue_fields") val cueFields: List<String> = emptyList(),
    val cues: CueTable = CueTable.EMPTY,
    val coverage: ReadAlongCoverage? = null,
)

/**
 * The cue array, read one cue at a time into primitive arrays so a 200,000-cue manifest
 * never exists as a tree of JSON objects. Shapes are checked here; ranges once the text
 * and audio lists are known.
 */
@Serializable(with = CueTableSerializer::class)
internal class CueTable(
    val count: Int,
    val text: IntArray,
    val fragment: Array<String>,
    val audio: IntArray,
    val begin: IntArray,
    /** -1 for an open end ("to the end of the file"). */
    val end: IntArray,
) {
    companion object {
        val EMPTY = CueTable(0, IntArray(0), emptyArray(), IntArray(0), IntArray(0), IntArray(0))
    }
}

internal object CueTableSerializer : KSerializer<CueTable> {
    private val list = ListSerializer(JsonArray.serializer())
    override val descriptor: SerialDescriptor = list.descriptor

    override fun serialize(encoder: Encoder, value: CueTable) {
        val cues = (0 until value.count).map { index ->
            buildJsonArray {
                add(JsonPrimitive(value.text[index]))
                add(JsonPrimitive(value.fragment[index]))
                add(JsonPrimitive(value.audio[index]))
                add(JsonPrimitive(value.begin[index]))
                add(if (value.end[index] < 0) JsonNull else JsonPrimitive(value.end[index]))
            }
        }
        list.serialize(encoder, cues)
    }

    override fun deserialize(decoder: Decoder): CueTable {
        var capacity = 1_024
        var text = IntArray(capacity)
        var audio = IntArray(capacity)
        var begin = IntArray(capacity)
        var end = IntArray(capacity)
        var fragment = arrayOfNulls<String>(capacity)
        var count = 0
        val input = decoder.beginStructure(descriptor)
        while (true) {
            val index = input.decodeElementIndex(descriptor)
            if (index == CompositeDecoder.DECODE_DONE) break
            if (count >= ReadAlongLimits.MAX_CUES) throw SerializationException("more than ${ReadAlongLimits.MAX_CUES} cues")
            val cue = input.decodeSerializableElement(descriptor, index, JsonArray.serializer())
            if (cue.size != 5) throw SerializationException("a cue must have five fields")
            if (count == capacity) {
                capacity = minOf(capacity * 2, ReadAlongLimits.MAX_CUES)
                text = text.copyOf(capacity)
                audio = audio.copyOf(capacity)
                begin = begin.copyOf(capacity)
                end = end.copyOf(capacity)
                fragment = fragment.copyOf(capacity)
            }
            text[count] = integer(cue[0])
            fragment[count] = (cue[1] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw SerializationException("a cue fragment must be a string")
            audio[count] = integer(cue[2])
            begin[count] = integer(cue[3])
            end[count] = if (cue[4] is JsonNull) -1 else integer(cue[4])
            count++
        }
        input.endStructure(descriptor)
        @Suppress("UNCHECKED_CAST")
        return CueTable(count, text.copyOf(count), (fragment.copyOf(count) as Array<String>), audio.copyOf(count), begin.copyOf(count), end.copyOf(count))
    }

    /** A JSON integer, never a string, fraction or anything outside 32 bits. */
    private fun integer(element: kotlinx.serialization.json.JsonElement): Int {
        val primitive = element as? JsonPrimitive ?: throw SerializationException("a cue number must be a number")
        if (primitive.isString) throw SerializationException("a cue number must not be a string")
        val value = primitive.longOrNull ?: throw SerializationException("a cue number must be a whole number")
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) throw SerializationException("a cue number is out of range")
        return value.toInt()
    }
}

/** A place in the narration: a file and an offset into it. */
data class NarrationPoint(val track: Int, val offsetMs: Long)

/** Where restoring a saved place puts the narration. [exact] when it names this generation's offset. */
data class NarrationPlace(val track: Int, val offsetMs: Long, val cue: Int, val exact: Boolean)

/**
 * A validated, indexed manifest for one exact EPUB asset and generation.
 *
 * Cues are kept in the manifest's canonical reading order (spine, then document); each
 * narration file also has its cues sorted by start, for finding the cue being heard.
 */
class ReadAlong private constructor(
    val generation: String,
    val source: ReadAlongSource,
    val publicationId: String?,
    val ebookAssetId: String,
    /** Spine documents by archive path, in the manifest's order. */
    val texts: List<String>,
    val textMediaTypes: List<String>,
    val tracks: List<NarrationTrack>,
    val coverage: ReadAlongCoverage,
    private val cueText: IntArray,
    private val cueFragment: Array<String>,
    private val cueAudio: IntArray,
    private val cueBegin: IntArray,
    private val cueEnd: IntArray,
    /** Per narration file, cue indexes sorted by start. */
    private val byAudio: Array<IntArray>,
    /** Per text, the first cue index; cues of one text are contiguous in reading order. */
    private val textStart: IntArray,
) {
    val cueCount: Int get() = cueText.size

    /** For an imported alignment, the audiobook publication every narration file belongs to. */
    val pairedPublicationId: String?
        get() = tracks.firstOrNull()?.takeIf { it.kind == NarrationKind.PUBLICATION_ASSET }?.publicationId

    fun textOf(cue: Int): Int = cueText[cue]
    fun fragmentOf(cue: Int): String = cueFragment[cue]
    fun trackOf(cue: Int): Int = cueAudio[cue]
    fun beginOf(cue: Int): Long = cueBegin[cue].toLong()

    /** The end of [cue], or null when it runs to the end of its file. */
    fun endOf(cue: Int): Long? = cueEnd[cue].takeIf { it >= 0 }?.toLong()

    /** Cues of one text document, in document order. */
    fun cuesOf(text: Int): IntRange =
        if (text !in texts.indices) IntRange.EMPTY else textStart[text] until textStart[text + 1]

    /** The cue whose interval contains [ms] of [track], or -1 between cues. */
    fun cueAt(track: Int, ms: Long): Int {
        val cue = cueReached(track, ms)
        if (cue < 0) return -1
        val end = cueEnd[cue]
        return if (end < 0 || ms < end) cue else -1
    }

    /** The last cue on [track] that began at or before [ms] (the narration most recently reached), or -1. */
    fun cueReached(track: Int, ms: Long): Int {
        val list = byAudio.getOrNull(track) ?: return -1
        val position = reachedPosition(list, ms)
        return if (position < 0) -1 else list[position]
    }

    /** When the cue being heard at [ms] of [track] ends or the next one starts, for scheduling the highlight. */
    fun nextBoundary(track: Int, ms: Long): Long? {
        val list = byAudio.getOrNull(track) ?: return null
        val position = reachedPosition(list, ms)
        if (position >= 0) {
            val end = cueEnd[list[position]]
            if (end >= 0 && ms < end) return end.toLong()
        }
        return list.getOrNull(position + 1)?.let { cueBegin[it].toLong() }
    }

    /** Index into [list] of the last cue that began at or before [ms], or -1. */
    private fun reachedPosition(list: IntArray, ms: Long): Int {
        var low = 0
        var high = list.size - 1
        var found = -1
        while (low <= high) {
            val middle = (low + high) ushr 1
            if (cueBegin[list[middle]] <= ms) {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /** The first cue for an element of a text document, or -1. */
    fun cueFor(text: Int, fragment: String): Int {
        for (cue in cuesOf(text)) if (cueFragment[cue] == fragment) return cue
        return -1
    }

    /** The first narrated cue in a text after [text], for a page with no narration of its own. */
    fun firstCueAfter(text: Int): Int {
        for (next in text + 1 until texts.size) {
            val range = cuesOf(next)
            if (!range.isEmpty()) return range.first
        }
        return -1
    }

    fun trackForAsset(assetId: String): Int = tracks.indexOfFirst { it.kind == NarrationKind.PUBLICATION_ASSET && it.assetId == assetId }

    /**
     * Where a saved ebook locator puts the narration: its exact offset when it was saved
     * against this generation and that offset's cue is in the locator's own document,
     * otherwise the start of its element's cue. Null when it names neither.
     */
    fun placeFromLocator(locator: JsonObject?, textIndexOf: (String) -> Int?): NarrationPlace? {
        locator ?: return null
        val href = (locator["href"] as? JsonPrimitive)?.contentOrNull ?: return null
        val text = textIndexOf(href) ?: return null
        val locations = locator["locations"] as? JsonObject
        val point = locations?.get("readAlong") as? JsonObject
        if (point != null && (point["generation"] as? JsonPrimitive)?.contentOrNull == generation) {
            val track = (point["audio"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
            val offset = (point["offset_ms"] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
            if (track != null && track in tracks.indices && offset != null && offset in 0..ReadAlongLimits.MAX_MS.toLong()) {
                val cue = cueReached(track, offset)
                if (cue >= 0 && cueText[cue] == text) return NarrationPlace(track, offset, cue, exact = true)
            }
        }
        val fragment = (locations?.get("fragments") as? JsonArray)?.firstOrNull()?.let { it as? JsonPrimitive }?.contentOrNull
        val cue = fragment?.let { cueFor(text, it) } ?: -1
        return if (cue >= 0) NarrationPlace(cueAudio[cue], cueBegin[cue].toLong(), cue, exact = false) else null
    }

    /** Where an audiobook place (imported alignments) lands in the text, or null when it maps to no cue. */
    fun placeFromAudio(assetId: String, seconds: Double?): NarrationPlace? {
        val track = trackForAsset(assetId)
        if (track < 0 || seconds == null || !seconds.isFinite() || seconds < 0) return null
        val ms = Math.round(seconds * 1_000)
        if (ms > ReadAlongLimits.MAX_MS) return null
        val cue = cueReached(track, ms)
        return if (cue >= 0) NarrationPlace(track, ms, cue, exact = true) else null
    }

    /**
     * The saved place for narration heard at [ms] of [track]: the reached cue's element plus
     * the exact offset. Null before the first cue of that file. [href] is the reader's own
     * href for the cue's document (see [texts]).
     */
    fun locatorFor(track: Int, ms: Long, href: (Int) -> String, totalProgression: (Int) -> Double?): JsonObject? {
        val cue = cueReached(track, ms)
        if (cue < 0) return null
        val text = cueText[cue]
        return buildJsonObject {
            put("href", href(text))
            put("type", textMediaTypes[text])
            putJsonObject("locations") {
                putJsonArray("fragments") { add(JsonPrimitive(cueFragment[cue])) }
                totalProgression(text)?.let { put("totalProgression", it.coerceIn(0.0, 1.0)) }
                putJsonObject("readAlong") {
                    put("generation", generation)
                    put("audio", track)
                    put("offset_ms", ms.coerceIn(0, ReadAlongLimits.MAX_MS.toLong()))
                }
            }
        }
    }

    companion object {
        /**
         * Reads a manifest body, refusing anything larger than [ReadAlongLimits.MAX_MANIFEST_BYTES]
         * and checking it against the EPUB asset (and generation, when known) it was fetched for.
         */
        @OptIn(ExperimentalSerializationApi::class)
        fun read(
            body: InputStream,
            ebookAssetId: String,
            expectedGeneration: String?,
            server: ServerAddress,
        ): ReadAlong {
            val wire = try {
                ApiJson.decodeFromStream(ManifestWire.serializer(), LimitedInputStream(body, ReadAlongLimits.MAX_MANIFEST_BYTES))
            } catch (error: SerializationException) {
                throw ReadAlongRefused(ReadAlongRefused.Kind.INVALID, "This book's read-along data couldn't be read (${error.message}).")
            } catch (error: IllegalArgumentException) {
                throw ReadAlongRefused(ReadAlongRefused.Kind.INVALID, "This book's read-along data couldn't be read.")
            }
            return prepare(wire, ebookAssetId, expectedGeneration, server)
        }

        private fun invalid(message: String): Nothing = throw ReadAlongRefused(ReadAlongRefused.Kind.INVALID, message)

        private fun prepare(wire: ManifestWire, ebookAssetId: String, expectedGeneration: String?, server: ServerAddress): ReadAlong {
            if (wire.version?.takeUnless { it.isString }?.intOrNull != READ_ALONG_VERSION) invalid("This read-along data is from an unsupported version.")
            val generation = wire.generation?.takeIf { it.matches(HEX64) } ?: invalid("This read-along data has no valid generation.")
            if (expectedGeneration != null && generation != expectedGeneration) {
                throw ReadAlongRefused(ReadAlongRefused.Kind.CHANGED, "This book's read-along data changed. Open the book again to use the current edition.")
            }
            if (wire.ebookAssetId != ebookAssetId) {
                throw ReadAlongRefused(ReadAlongRefused.Kind.CHANGED, "This read-along data belongs to another edition.")
            }
            val source = ReadAlongSource.fromWire(wire.source) ?: invalid("This read-along data has an unknown source.")
            if (wire.cueFields != CUE_FIELDS) invalid("This read-along data has an unknown layout.")
            val texts = wire.text
            if (texts.isEmpty()) invalid("This read-along data names no text.")
            val hrefs = texts.map { text -> text.href?.takeIf(::isSafePath) ?: invalid("This read-along data names an unsafe text document.") }
            if (hrefs.toSet().size != hrefs.size) invalid("This read-along data lists a text document twice.")
            val audio = wire.audio
            if (audio.isEmpty() || audio.size > ReadAlongLimits.MAX_TRACKS) invalid("This read-along data has no narration, or too many files.")
            val tracks = audio.mapIndexed { index, track -> track(index, track, source, server) }
            if (source == ReadAlongSource.IMPORTED && tracks.mapNotNull { it.publicationId }.toSet().size != 1) {
                invalid("This read-along data mixes audiobooks.")
            }

            val cues = wire.cues
            if (cues.count == 0) invalid("This read-along data has no cues.")
            var previousText = 0
            for (cue in 0 until cues.count) {
                val text = cues.text[cue]
                val track = cues.audio[cue]
                val begin = cues.begin[cue]
                val end = cues.end[cue]
                val fragment = cues.fragment[cue]
                if (text !in hrefs.indices || track !in tracks.indices) invalid("This read-along data has a cue outside its text or narration.")
                if (fragment.isEmpty() || fragment.length > ReadAlongLimits.MAX_FRAGMENT || fragment.any { it.isWhitespace() || it.isISOControl() }) {
                    invalid("This read-along data has a cue without a usable element ID.")
                }
                if (begin < 0 || begin > ReadAlongLimits.MAX_MS || (end >= 0 && (end <= begin || end > ReadAlongLimits.MAX_MS))) {
                    invalid("This read-along data has a cue with an invalid interval.")
                }
                // Canonical reading order: spine order, then document order.
                if (text < previousText) invalid("This read-along data isn't in reading order.")
                previousText = text
            }

            val byAudio = Array(tracks.size) { IntArray(0) }
            val counts = IntArray(tracks.size)
            for (cue in 0 until cues.count) counts[cues.audio[cue]]++
            for (track in tracks.indices) byAudio[track] = IntArray(counts[track])
            val fill = IntArray(tracks.size)
            for (cue in 0 until cues.count) {
                val track = cues.audio[cue]
                byAudio[track][fill[track]++] = cue
            }
            for (list in byAudio) {
                val sorted = list.sortedWith(compareBy<Int>({ cues.begin[it] }, { it })).toIntArray()
                sorted.copyInto(list)
                for (position in 1 until list.size) {
                    val previous = list[position - 1]
                    if (cues.end[previous] < 0) invalid("A cue without an end isn't the last on its narration file.")
                    if (cues.begin[list[position]] < cues.end[previous] - ReadAlongLimits.OVERLAP_TOLERANCE_MS) {
                        invalid("This read-along data has overlapping cues.")
                    }
                }
            }

            val textStart = IntArray(hrefs.size + 1) { cues.count }
            for (cue in cues.count - 1 downTo 0) textStart[cues.text[cue]] = cue
            for (text in hrefs.size - 1 downTo 0) if (textStart[text] > textStart[text + 1]) textStart[text] = textStart[text + 1]

            return ReadAlong(
                generation = generation,
                source = source,
                publicationId = wire.publicationId,
                ebookAssetId = ebookAssetId,
                texts = hrefs,
                textMediaTypes = texts.map { it.mediaType?.takeIf(String::isNotBlank) ?: "application/xhtml+xml" },
                tracks = tracks,
                coverage = wire.coverage ?: ReadAlongCoverage(),
                cueText = cues.text,
                cueFragment = cues.fragment,
                cueAudio = cues.audio,
                cueBegin = cues.begin,
                cueEnd = cues.end,
                byAudio = byAudio,
                textStart = textStart,
            )
        }

        private fun track(index: Int, wire: AudioWire, source: ReadAlongSource, server: ServerAddress): NarrationTrack {
            val mediaType = wire.mediaType?.takeIf { it.startsWith("audio/") && it.length <= 128 } ?: invalid("A narration file isn't audio.")
            val size = wire.sizeBytes?.takeUnless { it.isString }?.longOrNull?.takeIf { it > 0 } ?: invalid("A narration file has no size.")
            val url = wire.url?.takeIf { inScope(it, server) } ?: invalid("This read-along data names narration on another server.")
            return when (wire.kind) {
                NarrationKind.EPUB_RESOURCE.wire -> {
                    if (source != ReadAlongSource.MEDIA_OVERLAY) invalid("This read-along data mixes narration sources.")
                    val href = wire.href?.takeIf(::isSafePath) ?: invalid("This read-along data names an unsafe narration file.")
                    NarrationTrack(index, NarrationKind.EPUB_RESOURCE, mediaType, size, url, href = href)
                }
                NarrationKind.PUBLICATION_ASSET.wire -> {
                    if (source != ReadAlongSource.IMPORTED) invalid("This read-along data mixes narration sources.")
                    val publication = wire.publicationId?.takeIf { it.isNotBlank() && it.length <= 128 } ?: invalid("A narration file names no audiobook.")
                    val asset = wire.assetId?.takeIf { it.isNotBlank() && it.length <= 128 } ?: invalid("A narration file names no audiobook file.")
                    val content = wire.contentUrl?.takeIf { inScope(it, server) } ?: invalid("A narration file has no download address on this server.")
                    NarrationTrack(
                        index, NarrationKind.PUBLICATION_ASSET, mediaType, size, url,
                        publicationId = publication, assetId = asset, filename = wire.filename?.take(255), contentUrl = content,
                    )
                }
                else -> invalid("A narration file is of an unknown kind.")
            }
        }

        private fun inScope(reference: String, server: ServerAddress): Boolean =
            server.resolve(reference)?.let(server::contains) == true

        /** A relative archive path: no scheme, root, backslash, control character or parent step. */
        internal fun isSafePath(path: String): Boolean =
            path.isNotEmpty() && path.length <= 2_048 && !path.startsWith("/") && ':' !in path && '\\' !in path &&
                path.none { it.isISOControl() } && path.split('/').none { it == ".." || it.isEmpty() }

        val CUE_FIELDS = listOf("text", "fragment", "audio", "begin_ms", "end_ms")
    }
}

/** Fails the read once more than [limit] bytes arrive, instead of buffering an unbounded body. */
private class LimitedInputStream(input: InputStream, private val limit: Long) : FilterInputStream(input) {
    private var count = 0L

    override fun read(): Int {
        val value = super.read()
        if (value >= 0 && ++count > limit) throw IOException("read-along data is too large")
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val read = super.read(buffer, offset, length)
        if (read > 0) {
            count += read
            if (count > limit) throw IOException("read-along data is too large")
        }
        return read
    }
}

/** The read-along places one narration checkpoint writes: the ebook's and, for imported alignments, the audiobook's. */
data class HeardPlaces(val ebook: SavedPosition?, val audiobook: SavedPosition?)

/**
 * Turns narration heard at an exact point into saved places. The ebook place is the reached
 * cue's element with the offset; the paired audiobook (imported alignments) gets that file
 * and second. Both are written with the same activity time by the caller.
 */
class HeardPlaceMapper(
    private val readAlong: ReadAlong,
    /** The reader's own href for each text document, by text index. */
    private val hrefs: List<String>,
    /** Start of each text in the whole book (0–1), when known. */
    private val progressions: List<Double?> = emptyList(),
) {
    init {
        require(hrefs.size == readAlong.texts.size) { "Every text needs an href" }
    }

    fun placesAt(track: Int, ms: Long): HeardPlaces {
        val locator = readAlong.locatorFor(track, ms, hrefs::get) { progressions.getOrNull(it) }
        val ebook = locator?.let { SavedPosition(readAlong.ebookAssetId, it) }
        val narration = readAlong.tracks.getOrNull(track)
        val audiobook = narration?.takeIf { it.kind == NarrationKind.PUBLICATION_ASSET }?.assetId?.let { asset ->
            SavedPosition(asset, positionSeconds = ms.coerceAtLeast(0) / 1_000.0)
        }
        return HeardPlaces(ebook, audiobook)
    }

    /** The text index for a reader href, comparing decoded archive paths. */
    fun textIndexOf(href: String): Int? = hrefs.indexOf(href).takeIf { it >= 0 }
        ?: readAlong.texts.indexOf(decodePath(href)).takeIf { it >= 0 }

    companion object {
        fun decodePath(href: String): String = try {
            java.net.URLDecoder.decode(href.substringBefore('#').trimStart('/').replace("+", "%2B"), "UTF-8")
        } catch (_: IllegalArgumentException) {
            href
        }
    }
}

/** True when [locator] names this exact narration offset (rather than only a page or element). */
fun JsonObject.readAlongGeneration(): String? = runCatching {
    this["locations"]?.jsonObject?.get("readAlong")?.jsonObject?.get("generation")?.jsonPrimitive?.contentOrNull
}.getOrNull()

/** For tests and diagnostics: a manifest's cue as the wire spells it. */
internal fun cueJson(text: Int, fragment: String, audio: Int, begin: Int, end: Int?): JsonArray = buildJsonArray {
    add(JsonPrimitive(text))
    add(JsonPrimitive(fragment))
    add(JsonPrimitive(audio))
    add(JsonPrimitive(begin))
    add(end?.let(::JsonPrimitive) ?: JsonNull)
}
