package org.shelfarr.app.core

import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response

/** The credential the app currently holds, if any. */
data class Credential(val server: ServerAddress, val accessToken: String) {
    override fun toString(): String = "Credential(server=$server)"
}

fun interface CredentialSource {
    fun current(): Credential?
}

/**
 * Decides a refusal of [rejected] before it is reported: while that sign-in is being
 * handed over to a replacement token, the server may already have retired [rejected].
 * Called on an HTTP thread; it may block until the handover is answered or [canceled].
 */
fun interface RefusalResolver {
    fun resolve(rejected: Credential, canceled: () -> Boolean): RefusalResolution
}

/** Thrown when a replacement token couldn't be confirmed yet: to callers, a dropped connection. */
class HandoverPendingIOException : IOException("The sign-in's new token is being confirmed")

/** Thrown from the network stack, so OkHttp treats it as a normal failed call. */
class BlockedRedirectIOException(val location: String) : IOException("Redirect left the configured server")

/**
 * Attaches the bearer token to in-scope requests and nothing else, and refuses
 * to follow a redirect out of scope. OkHttp's own redirect handling is disabled
 * so that this is the only code that can decide to re-send a request.
 */
class ScopedAuthInterceptor(
    private val credentials: CredentialSource,
    private val onRejected: (Credential) -> Unit = {},
    private val refusals: RefusalResolver? = null,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        var request = chain.request()
        var hops = 0
        // Once a refusal is resolved, the replay carries exactly the credential it resolved to,
        // so it can never pick up a different sign-in's token from [credentials].
        var replay: Credential? = null
        while (true) {
            val credential = replay ?: credentials.current()
            val builder = request.newBuilder().removeHeader(AUTHORIZATION)
            val attached = credential?.takeIf { it.server.contains(request.url) }
            if (attached != null) builder.header(AUTHORIZATION, "Bearer ${attached.accessToken}")
            val response = chain.proceed(builder.build())

            if (response.code == 401 && attached != null) {
                when (val resolution = refusals?.takeIf { replay == null }?.resolve(attached) { chain.call().isCanceled() }) {
                    is RefusalResolution.Replay -> if (resolution.credential.accessToken != attached.accessToken &&
                        resolution.credential.server.contains(request.url)
                    ) {
                        // The same sign-in goes on with a replacement token: once more with it, never a loop.
                        response.close()
                        replay = resolution.credential
                        continue
                    }
                    RefusalResolution.Unconfirmed -> {
                        response.close()
                        throw HandoverPendingIOException()
                    }
                    RefusalResolution.Ended, null -> Unit
                }
                onRejected(attached)
            }

            if (!response.isRedirect) return response
            val location = response.header("Location") ?: return response
            val target = request.url.resolve(location)
            response.close()

            val scope = credential?.server
            val allowed = target != null && scope != null && scope.contains(target) && scope.contains(request.url)
            if (!allowed) throw BlockedRedirectIOException(target?.toString() ?: location)
            if (++hops > MAX_REDIRECTS) throw IOException("Too many redirects")

            val keepsMethod = response.code == 307 || response.code == 308 || request.method == "GET" || request.method == "HEAD"
            request = request.newBuilder()
                .url(target)
                .apply { if (!keepsMethod) method("GET", null) }
                .build()
        }
    }

    private companion object {
        const val AUTHORIZATION = "Authorization"
        const val MAX_REDIRECTS = 5
    }
}

/** The single HTTP stack behind the API, EPUB downloads, covers and audio. */
fun buildHttpClient(
    credentials: CredentialSource,
    refusals: RefusalResolver? = null,
    onRejected: (Credential) -> Unit = {},
): OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .followRedirects(false)
    .followSslRedirects(false)
    .addInterceptor(ScopedAuthInterceptor(credentials, onRejected, refusals))
    .build()
