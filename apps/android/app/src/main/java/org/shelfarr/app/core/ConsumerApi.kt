package org.shelfarr.app.core

import java.io.IOException
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

enum class LibraryFilter(val query: String?) {
    ALL(null),
    EBOOK("ebook"),
    AUDIOBOOK("audiobook"),
}

enum class LibrarySort(val query: String?) {
    /** Recently acquired first, the server default. */
    RECENT(null),
    TITLE("title"),
}

/** Everything that selects one library listing. A cursor is only valid for the query that produced it. */
data class LibraryQuery(
    val filter: LibraryFilter = LibraryFilter.ALL,
    val text: String = "",
    val status: ReadingStatus? = null,
    val sort: LibrarySort = LibrarySort.RECENT,
)

/** A fully read response. Reading happens off the main thread, inside [ConsumerApi.execute]. */
private class Reply(val code: Int, val body: String) {
    val isSuccessful: Boolean get() = code in 200..299
}

/** Typed client for `/api/consumer/v1`. Credentials are applied by the HTTP stack. */
class ConsumerApi(
    private val client: OkHttpClient,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {

    /**
     * Starts a browser approval. With [scope], an app asks for more than reading and
     * listening; when already signed in, the HTTP stack sends its bearer, so the server
     * adds the permission to this connection and only its own account may approve it.
     */
    suspend fun startDeviceAuthorization(server: ServerAddress, clientName: String, scope: String? = null): DeviceGrant =
        post(server.api("auth/device"), ApiJson.encodeToString(DeviceRequest(clientName, scope))).parse()

    /** Public, bearer-free server facts. A server without the file answers 404. */
    suspend fun serverFacts(server: ServerAddress): ServerFacts = get(server.api("server.json")).parse()

    /** Metadata search beyond the library. Needs `search:read`. */
    suspend fun discover(server: ServerAddress, query: String, limit: Int = 12): List<DiscoverItem> {
        val url = server.api("discover").newBuilder()
            .addQueryParameter("q", query)
            .addQueryParameter("limit", limit.toString())
            .build()
        return get(url).parse<DiscoverPage>().items
    }

    /** This account's requests, most recently changed first. */
    suspend fun requests(server: ServerAddress, limit: Int = 30): List<RequestItem> {
        val url = server.api("requests").newBuilder().addQueryParameter("limit", limit.toString()).build()
        return get(url).parse<RequestList>().items
    }

    suspend fun request(server: ServerAddress, id: String): RequestItem =
        get(server.api("requests/${encodePath(id)}")).parse<RequestEnvelope>().request

    /**
     * Asks for one format of a title. A duplicate is never an error: the server answers
     * with what already exists, which this reports as anything but [RequestOutcome.Created].
     */
    suspend fun createRequest(server: ServerAddress, request: NewRequest): RequestOutcome {
        val reply = post(server.api("requests"), ApiJson.encodeToString(request))
        val error = if (reply.isSuccessful) null else runCatching { ApiJson.decodeFromString<ErrorBody>(reply.body) }.getOrNull()
        return when {
            reply.code == 201 -> RequestOutcome.Created(reply.parse<RequestEnvelope>().request)
            reply.isSuccessful -> RequestOutcome.Existing(reply.parse<RequestEnvelope>().request)
            reply.code == 409 && error?.error == "already_in_library" -> RequestOutcome.InLibrary(error.publicationId, error.message)
            reply.code == 409 && error?.error == "already_requested" -> RequestOutcome.RequestedBySomeone(error.message)
            reply.code == 422 && error?.error == "request_rejected" -> RequestOutcome.Refused(error.message)
            else -> {
                reply.requireSuccess()
                throw ApiException.Protocol()
            }
        }
    }

    /** Stops a request that hasn't finished. The server decides whether it still can be. */
    suspend fun cancelRequest(server: ServerAddress, id: String): RequestItem {
        val request = Request.Builder().url(server.api("requests/${encodePath(id)}")).delete().build()
        return execute(request).parse<RequestEnvelope>().request
    }

    /** Polls once. Pending and terminal states arrive as [ApiException.Authorization]. */
    suspend fun exchangeDeviceCode(server: ServerAddress, deviceCode: String): TokenResponse {
        val reply = post(server.api("auth/token"), ApiJson.encodeToString(TokenRequest(deviceCode)))
        if (reply.code == 400) {
            val code = runCatching { ApiJson.decodeFromString<ErrorBody>(reply.body).error }.getOrNull()
            throw ApiException.Authorization(code ?: "invalid_request")
        }
        return reply.parse()
    }

    suspend fun me(server: ServerAddress): Me = get(server.api("me")).parse()

    suspend fun revoke(server: ServerAddress) {
        post(server.api("auth/revoke"), "{}").requireSuccess()
    }

    suspend fun library(
        server: ServerAddress,
        filter: LibraryFilter = LibraryFilter.ALL,
        query: String? = null,
        cursor: String? = null,
        limit: Int = 30,
    ): LibraryPage = library(server, LibraryQuery(filter, query.orEmpty()), cursor, limit)

    suspend fun library(server: ServerAddress, query: LibraryQuery, cursor: String? = null, limit: Int = 30): LibraryPage {
        val url = server.api("library").newBuilder().apply {
            query.filter.query?.let { addQueryParameter("type", it) }
            query.text.takeIf(String::isNotBlank)?.let { addQueryParameter("q", it) }
            query.status?.let { addQueryParameter("status", it.query) }
            query.sort.query?.let { addQueryParameter("sort", it) }
            cursor?.let { addQueryParameter("cursor", it) }
            addQueryParameter("limit", limit.toString())
        }.build()
        return get(url).parse()
    }

    /** Library-wide recent activity across every acquired publication. */
    suspend fun continueReading(server: ServerAddress, limit: Int = 10): List<Publication> {
        val url = server.api("continue").newBuilder().addQueryParameter("limit", limit.toString()).build()
        return get(url).parse<ContinueList>().items
    }

    /** Sets the explicit status. The saved place is kept by the server. */
    suspend fun setReadingStatus(server: ServerAddress, publicationId: String, status: ReadingStatus): Publication {
        val request = Request.Builder()
            .url(server.api("library/${encodePath(publicationId)}/reading_status"))
            .put(ApiJson.encodeToString(ReadingStatusUpdate(status)).toRequestBody(JSON))
            .build()
        return execute(request).parse()
    }

    suspend fun publication(server: ServerAddress, id: String): Publication =
        get(server.api("library/${encodePath(id)}")).parse()

    suspend fun progress(server: ServerAddress, publicationId: String): Progress? =
        get(server.api("library/${encodePath(publicationId)}/progress"))
            .parse<ProgressEnvelope>()
            .progress

    suspend fun saveProgress(server: ServerAddress, publicationId: String, update: ProgressUpdate): Progress {
        val url = server.api("library/${encodePath(publicationId)}/progress")
        val request = Request.Builder()
            .url(url)
            .put(ApiJson.encodeToString(update).toRequestBody(JSON))
            .build()
        val envelope: ProgressEnvelope = execute(request).parse()
        return envelope.progress ?: throw ApiException.Protocol()
    }

    private suspend fun get(url: HttpUrl): Reply = execute(Request.Builder().url(url).get().build())

    private suspend fun post(url: HttpUrl, body: String): Reply =
        execute(Request.Builder().url(url).post(body.toRequestBody(JSON)).build())

    private suspend fun execute(request: Request): Reply = withContext(io) {
        val call = client.newCall(request.newBuilder().header("Accept", "application/json").build())
        try {
            call.await().use { Reply(it.code, it.body.string()) }
        } catch (error: BlockedRedirectIOException) {
            throw ApiException.RedirectBlocked(error.location)
        } catch (error: IOException) {
            throw ApiException.Offline(error)
        }
    }

    private inline fun <reified T> Reply.parse(): T {
        requireSuccess()
        try {
            return ApiJson.decodeFromString<T>(body)
        } catch (error: SerializationException) {
            throw ApiException.Protocol(error)
        } catch (error: IllegalArgumentException) {
            throw ApiException.Protocol(error)
        }
    }

    private fun Reply.requireSuccess() {
        if (isSuccessful) return
        when (code) {
            401 -> throw ApiException.Unauthorized()
            403 -> {
                val scope = runCatching { ApiJson.decodeFromString<ErrorBody>(body).requiredScope }.getOrNull()
                throw ApiException.Forbidden(scope)
            }
            404 -> throw ApiException.NotFound()
            409 -> {
                val current = runCatching { ApiJson.decodeFromString<ErrorBody>(body).progress }.getOrNull()
                throw ApiException.ProgressConflict(current)
            }
            400, 422 -> {
                val error = runCatching { ApiJson.decodeFromString<ErrorBody>(body) }.getOrNull()
                throw ApiException.Rejected(error?.error, error?.message)
            }
            in 500..599 -> throw ApiException.Server(code)
            else -> throw ApiException.Protocol()
        }
    }

    private fun encodePath(id: String): String = HttpUrlPathEncoder.encode(id)

    private companion object {
        val JSON = "application/json".toMediaType()
    }
}

private object HttpUrlPathEncoder {
    private val base = HttpUrl.Builder().scheme("https").host("x").build()

    fun encode(segment: String): String =
        base.newBuilder().addPathSegment(segment).build().encodedPathSegments.last()
}

/** Suspends until the call responds, cancelling it if the coroutine is cancelled. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    enqueue(ContinuationCallback(this, continuation))
    continuation.invokeOnCancellation { runCatching { cancel() } }
}

private class ContinuationCallback(
    private val call: Call,
    private val continuation: CancellableContinuation<Response>,
) : Callback {
    override fun onResponse(call: Call, response: Response) {
        continuation.resume(response) { _, value, _ -> value.close() }
    }

    override fun onFailure(call: Call, e: IOException) {
        if (!this.call.isCanceled()) continuation.resumeWithException(e)
    }
}
