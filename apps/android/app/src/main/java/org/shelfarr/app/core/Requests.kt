package org.shelfarr.app.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** The scopes that together let an app find and request titles for its own account. */
object RequestScopes {
    val BASE = listOf("library:read", "progress:write")
    val REQUESTING = listOf("search:read", "requests:read", "requests:write")
    val ALL: String = (BASE + REQUESTING).joinToString(" ")

    fun allows(scopes: Collection<String>?): Boolean = scopes != null && scopes.containsAll(REQUESTING)
}

/** Public facts from `/server.json`. Older servers omit `consumer_features` and `reader_formats`. */
@Serializable
data class ServerFacts(
    @SerialName("consumer_features") val consumerFeatures: List<String> = emptyList(),
    /** Formats the server can offer readers that declare them. Null: an older, EPUB-only server. */
    @SerialName("reader_formats") val readerFormats: List<String>? = null,
) {
    val offersRequesting: Boolean get() = "requests" in consumerFeatures
}

/** Where a request is, in the words the app shows. Unknown future stages decode as [UNKNOWN]. */
@Serializable
enum class RequestStage {
    @SerialName("queued") QUEUED,
    @SerialName("searching") SEARCHING,
    @SerialName("not_found") NOT_FOUND,
    @SerialName("awaiting_purchase") AWAITING_PURCHASE,
    @SerialName("downloading") DOWNLOADING,
    @SerialName("processing") PROCESSING,
    @SerialName("available") AVAILABLE,
    @SerialName("completed") COMPLETED,
    @SerialName("failed") FAILED,
    UNKNOWN,
    ;

    /** Still on its way: worth following. */
    val isOpen: Boolean get() = this in setOf(QUEUED, SEARCHING, NOT_FOUND, AWAITING_PURCHASE, DOWNLOADING, PROCESSING)
}

@Serializable
data class RequestItem(
    val id: String,
    val stage: RequestStage = RequestStage.UNKNOWN,
    val status: String? = null,
    val title: String,
    val author: String? = null,
    @SerialName("book_type") val bookType: BookType,
    @SerialName("cover_url") val coverUrl: String? = null,
    @SerialName("download_percent") val downloadPercent: Int? = null,
    @SerialName("can_cancel") val canCancel: Boolean = false,
    @SerialName("attention_needed") val attentionNeeded: Boolean = false,
    @SerialName("publication_id") val publicationId: String? = null,
    @SerialName("next_retry_at") val nextRetryAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
) {
    val isReady: Boolean get() = stage == RequestStage.AVAILABLE && publicationId != null
}

@Serializable
enum class FormatState {
    @SerialName("requestable") REQUESTABLE,
    @SerialName("in_library") IN_LIBRARY,
    @SerialName("requested") REQUESTED,
    @SerialName("requested_by_someone") REQUESTED_BY_SOMEONE,
    UNKNOWN,
}

@Serializable
data class FormatOption(
    @SerialName("book_type") val bookType: BookType,
    val state: FormatState = FormatState.UNKNOWN,
    @SerialName("publication_id") val publicationId: String? = null,
    val request: RequestItem? = null,
)

@Serializable
data class DiscoverItem(
    val id: String,
    @SerialName("work_id") val workId: String,
    @SerialName("source_work_ids") val sourceWorkIds: List<String> = emptyList(),
    val title: String,
    val author: String? = null,
    val year: Int? = null,
    val description: String? = null,
    @SerialName("cover_url") val coverUrl: String? = null,
    @SerialName("series_name") val seriesName: String? = null,
    @SerialName("series_position") val seriesPosition: String? = null,
    val formats: List<FormatOption> = emptyList(),
) {
    fun format(type: BookType): FormatOption? = formats.firstOrNull { it.bookType == type }

    /** A publication stand-in, so the shared cover drawing can render a candidate. */
    fun asPublication(type: BookType = BookType.EBOOK): Publication =
        Publication(id = "find:$id", title = title, author = author, bookType = type, coverUrl = coverUrl)
}

@Serializable
data class DiscoverPage(val items: List<DiscoverItem> = emptyList())

@Serializable
data class RequestList(val items: List<RequestItem> = emptyList())

@Serializable
data class RequestEnvelope(val request: RequestItem, val existing: Boolean = false)

@Serializable
data class NewRequest(
    @SerialName("work_id") val workId: String,
    @SerialName("book_type") val bookType: BookType,
    val title: String,
    val author: String? = null,
    @SerialName("cover_url") val coverUrl: String? = null,
    val year: Int? = null,
    @SerialName("source_work_ids") val sourceWorkIds: List<String> = emptyList(),
) {
    companion object {
        fun from(item: DiscoverItem, type: BookType) =
            NewRequest(item.workId, type, item.title, item.author, item.coverUrl, item.year, item.sourceWorkIds)
    }
}

/** What asking for a title produced. Only [Created] made something new. */
sealed interface RequestOutcome {
    val request: RequestItem? get() = null

    data class Created(override val request: RequestItem) : RequestOutcome
    /** This account had already asked; nothing new was made. */
    data class Existing(override val request: RequestItem) : RequestOutcome
    data class InLibrary(val publicationId: String?, val message: String?) : RequestOutcome
    data class RequestedBySomeone(val message: String?) : RequestOutcome
    data class Refused(val message: String?) : RequestOutcome
}
