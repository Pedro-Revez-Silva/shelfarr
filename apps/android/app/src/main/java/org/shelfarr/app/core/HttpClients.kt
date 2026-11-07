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
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        var request = chain.request()
        var hops = 0
        while (true) {
            val credential = credentials.current()
            val builder = request.newBuilder().removeHeader(AUTHORIZATION)
            val attached = credential?.takeIf { it.server.contains(request.url) }
            if (attached != null) builder.header(AUTHORIZATION, "Bearer ${attached.accessToken}")
            val response = chain.proceed(builder.build())

            if (response.code == 401 && attached != null) onRejected(attached)

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
    onRejected: (Credential) -> Unit = {},
): OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .followRedirects(false)
    .followSslRedirects(false)
    .addInterceptor(ScopedAuthInterceptor(credentials, onRejected))
    .build()
