package org.shelfarr.app.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

val ApiJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

@Serializable
data class DeviceRequest(
    @SerialName("client_name") val clientName: String,
    /** Omitted for the read-and-listen connection; the whole requesting bundle when opting in. */
    val scope: String? = null,
)

@Serializable
data class DeviceGrant(
    @SerialName("device_code") val deviceCode: String,
    @SerialName("user_code") val userCode: String,
    @SerialName("verification_uri") val verificationUri: String,
    @SerialName("verification_uri_complete") val verificationUriComplete: String,
    @SerialName("expires_in") val expiresIn: Long,
    val interval: Long = 5,
) {
    // A grant is a live secret: keep it out of logs and crash reports.
    override fun toString(): String = "DeviceGrant(userCode=$userCode, expiresIn=$expiresIn)"
}

@Serializable
data class TokenRequest(@SerialName("device_code") val deviceCode: String)

@Serializable
data class TokenResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("token_type") val tokenType: String = "Bearer",
    val scope: String = "",
    @SerialName("expires_in") val expiresIn: Long = 0,
) {
    override fun toString(): String = "TokenResponse(scope=$scope, expiresIn=$expiresIn)"
}

@Serializable
data class ErrorBody(
    val error: String? = null,
    val progress: Progress? = null,
    val message: String? = null,
    @SerialName("publication_id") val publicationId: String? = null,
    @SerialName("required_scope") val requiredScope: String? = null,
)

@Serializable
data class Me(
    val id: String,
    val name: String? = null,
    val username: String? = null,
    /** What this credential may do. Absent from servers that predate requesting. */
    val scopes: List<String>? = null,
) {
    val displayName: String get() = name?.takeIf(String::isNotBlank) ?: username ?: "Reader"
}

@Serializable
enum class BookType {
    @SerialName("ebook") EBOOK,
    @SerialName("audiobook") AUDIOBOOK,
}

/** Where the reader is with a publication. Set explicitly, or derived when an older server omits it. */
@Serializable
enum class ReadingStatus(val query: String) {
    @SerialName("unread") UNREAD("unread"),
    @SerialName("in_progress") IN_PROGRESS("in_progress"),
    @SerialName("finished") FINISHED("finished"),
}

@Serializable
data class ReadingStatusUpdate(val status: ReadingStatus)

@Serializable
data class Asset(
    val id: String,
    val filename: String = "",
    @SerialName("media_type") val mediaType: String = "",
    val format: String = "",
    @SerialName("size_bytes") val sizeBytes: Long = 0,
    @SerialName("content_url") val contentUrl: String,
    val position: Int = 0,
    /** CBZ only: how many pages the generation's reading order lists. Absent elsewhere and from older servers. */
    @SerialName("page_count") val pageCount: Int? = null,
    /** CBZ only: where this exact generation's page order is. Bound by the same origin and subpath rules as content. */
    @SerialName("reading_order_url") val readingOrderUrl: String? = null,
) {
    val isEpub: Boolean get() = format.equals("epub", ignoreCase = true) || mediaType == "application/epub+zip"

    /**
     * The reading format, by the declared format first and the media type second. Null for
     * audio and anything this app can't read. A CBZ without its reading order can't be
     * paged, and a file over the format's size limit is refused rather than opened.
     */
    val readingFormat: ReadingFormat?
        get() {
            val declared = declaredFormat ?: return null
            if (declared.isPaged && sizeBytes > declared.maxBytes) return null
            if (declared == ReadingFormat.CBZ && readingOrderUrl.isNullOrBlank()) return null
            return declared
        }

    /** The format this file says it is, before any size or reading-order check. */
    val declaredFormat: ReadingFormat?
        get() {
            // EPUB is recognized exactly as before, so an EPUB-only book keeps the same file.
            if (isEpub) return ReadingFormat.EPUB
            return ReadingFormat.fromWire(format.lowercase()) ?: when (mediaType) {
                PDF_MEDIA_TYPE -> ReadingFormat.PDF
                CBZ_MEDIA_TYPE -> ReadingFormat.CBZ
                else -> null
            }
        }

    val isAudio: Boolean
        get() = mediaType.startsWith("audio/") || format.lowercase() in AUDIO_FORMATS

    private companion object {
        val AUDIO_FORMATS = setOf("mp3", "m4b", "m4a", "aac", "ogg", "oga", "opus", "flac", "wav")
    }
}

@Serializable
data class Publication(
    val id: String,
    val title: String,
    val author: String? = null,
    val description: String? = null,
    @SerialName("book_type") val bookType: BookType,
    @SerialName("cover_url") val coverUrl: String? = null,
    val assets: List<Asset> = emptyList(),
    val progress: Progress? = null,
    /** Absent from older servers; read [status] instead. Unknown values decode as absent. */
    @SerialName("reading_status") val readingStatus: ReadingStatus? = null,
    /** `graphic` for comics and other page-image books, `book` otherwise. Absent from older servers. */
    @SerialName("content_kind") val contentKind: String? = null,
) {
    /** The explicit status, or one derived from the saved place when the server sends none. */
    val status: ReadingStatus
        get() = readingStatus ?: if (progress?.isUsable == true) ReadingStatus.IN_PROGRESS else ReadingStatus.UNREAD

    val orderedAssets: List<Asset> get() = assets.sortedBy { it.position }
    val epubAsset: Asset? get() = orderedAssets.firstOrNull { it.isEpub }
    val audioAssets: List<Asset> get() = orderedAssets.filter { it.isAudio }

    /**
     * One file per reading format, the first of each in the server's order. An EPUB-only
     * book gives exactly [epubAsset], as before PDF and CBZ existed.
     */
    val readingAssets: List<Asset>
        get() = if (bookType == BookType.EBOOK) {
            orderedAssets.filter { it.readingFormat != null }.distinctBy { it.readingFormat }
        } else {
            emptyList()
        }

    /** The assets a saved position may legitimately refer to in this edition. */
    val playableAssets: List<Asset>
        get() = if (bookType == BookType.EBOOK) readingAssets else audioAssets

    val isGraphic: Boolean get() = contentKind == "graphic"

    val isReadableHere: Boolean get() = playableAssets.isNotEmpty()
}

@Serializable
data class Progress(
    @SerialName("asset_id") val assetId: String,
    val locator: JsonObject? = null,
    @SerialName("position_seconds") val positionSeconds: Double? = null,
    val version: Int = 0,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("client_mutation_id") val clientMutationId: String? = null,
    /** When the place was actually reached. Null from older servers and rows: unknown, never the upload time. */
    @SerialName("observed_at") val observedAt: String? = null,
) {
    /** [observedAt] as epoch milliseconds, when it is well formed. Check plausibility before ordering by it. */
    val observedAtEpochMs: Long? get() = ActivityTime.parse(observedAt)

    /** 0.0–1.0 through the whole publication, when the locator states it. */
    val totalProgression: Double?
        get() = locator?.get("locations")?.jsonObject?.get("totalProgression")?.jsonPrimitive?.doubleOrNull
            ?.coerceIn(0.0, 1.0)

    val isUsable: Boolean get() = locator != null || positionSeconds != null
}

@Serializable
data class ProgressEnvelope(val progress: Progress? = null)

@Serializable
data class LibraryPage(
    val items: List<Publication> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null,
)

@Serializable
data class ContinueList(val items: List<Publication> = emptyList())

@Serializable
data class ProgressUpdate(
    @SerialName("asset_id") val assetId: String,
    val locator: JsonObject? = null,
    @SerialName("position_seconds") val positionSeconds: Double? = null,
    @SerialName("expected_version") val expectedVersion: Int,
    @SerialName("client_mutation_id") val clientMutationId: String,
    /** Omitted when this device does not know when the place was reached. */
    @SerialName("observed_at") val observedAt: String? = null,
    /** Only ever true for an explicit "Keep this device" choice; omitted otherwise. */
    @SerialName("resolve_conflict") val resolveConflict: Boolean? = null,
)
