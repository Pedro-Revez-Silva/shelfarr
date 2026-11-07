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

/** A fully read response. Reading happens off the main thread, inside [ConsumerApi.execute]. */
private class Reply(val code: Int, val body: String) {
    val isSuccessful: Boolean get() = code in 200..299
}

/** Typed client for `/api/consumer/v1`. Credentials are applied by the HTTP stack. */
class ConsumerApi(
    private val client: OkHttpClient,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {

    suspend fun startDeviceAuthorization(server: ServerAddress, clientName: String): DeviceGrant =
        post(server.api("auth/device"), ApiJson.encodeToString(DeviceRequest(clientName))).parse()

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
    ): LibraryPage {
        val url = server.api("library").newBuilder().apply {
            filter.query?.let { addQueryParameter("type", it) }
            query?.takeIf(String::isNotBlank)?.let { addQueryParameter("q", it) }
            cursor?.let { addQueryParameter("cursor", it) }
            addQueryParameter("limit", limit.toString())
        }.build()
        return get(url).parse()
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
            403 -> throw ApiException.Forbidden()
            404 -> throw ApiException.NotFound()
            409 -> {
                val current = runCatching { ApiJson.decodeFromString<ErrorBody>(body).progress }.getOrNull()
                throw ApiException.ProgressConflict(current)
            }
            400, 422 -> {
                val error = runCatching { ApiJson.decodeFromString<ErrorBody>(body).error }.getOrNull()
                throw ApiException.Rejected(error)
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
