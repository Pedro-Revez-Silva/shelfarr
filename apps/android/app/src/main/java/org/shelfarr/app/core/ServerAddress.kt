package org.shelfarr.app.core

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * The configured Shelfarr server: an origin plus an optional subpath.
 *
 * This is also the credential boundary. A bearer token is only ever attached to
 * URLs for which [contains] returns true.
 */
class ServerAddress private constructor(val baseUrl: HttpUrl) {

    /** Normal form with no trailing slash, e.g. `https://example.org/shelfarr`. */
    val display: String = baseUrl.toString().trimEnd('/')

    val host: String get() = baseUrl.host

    private val basePath: String = baseUrl.encodedPath.trimEnd('/')

    val isCleartext: Boolean get() = !baseUrl.isHttps

    /** Unique key for this server, independent of how the address was typed. */
    val identity: String get() = display.lowercase()

    fun api(path: String): HttpUrl = baseUrl.newBuilder()
        .encodedPath("$basePath/api/consumer/v1/${path.trimStart('/')}")
        .build()

    /** True when [url] shares this server's scheme, host, port and subpath. */
    fun contains(url: HttpUrl): Boolean {
        if (url.scheme != baseUrl.scheme || url.host != baseUrl.host || url.port != baseUrl.port) {
            return false
        }
        if (basePath.isEmpty()) return true
        val path = url.encodedPath
        return path == basePath || path.startsWith("$basePath/")
    }

    /**
     * Resolves a URL from an API response.
     *
     * Absolute URLs are returned untouched, so callers must still check [contains].
     * A server-relative path gains the configured subpath unless it already has it.
     */
    fun resolve(reference: String): HttpUrl? {
        val value = reference.trim()
        if (value.isEmpty()) return null
        if (value.startsWith("//")) return null
        if (ABSOLUTE.containsMatchIn(value)) return value.toHttpUrlOrNull()

        val path = when {
            !value.startsWith("/") -> "$basePath/$value"
            basePath.isNotEmpty() && (value == basePath || value.startsWith("$basePath/")) -> value
            else -> "$basePath$value"
        }
        return baseUrl.resolve(path)
    }

    override fun equals(other: Any?): Boolean = other is ServerAddress && other.identity == identity

    override fun hashCode(): Int = identity.hashCode()

    override fun toString(): String = display

    sealed interface ParseResult {
        data class Valid(val address: ServerAddress) : ParseResult
        data object Empty : ParseResult
        data object Malformed : ParseResult
        data object CleartextNotAllowed : ParseResult
    }

    companion object {
        private val ABSOLUTE = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*:")
        private val SCHEME = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://")

        /**
         * Parses user input. HTTPS is assumed when no scheme is given. Plain HTTP
         * needs [allowLocalHttp] and a host that is only reachable locally.
         */
        fun parse(input: String, allowLocalHttp: Boolean = false): ParseResult {
            val value = input.trim()
            if (value.isEmpty()) return ParseResult.Empty

            val withScheme = if (SCHEME.containsMatchIn(value)) value else "https://$value"
            val url = withScheme.toHttpUrlOrNull() ?: return ParseResult.Malformed
            if (url.username.isNotEmpty() || url.password.isNotEmpty()) return ParseResult.Malformed
            if (url.query != null || url.fragment != null) return ParseResult.Malformed

            if (!url.isHttps && !(allowLocalHttp && isLocalHost(url.host))) {
                return ParseResult.CleartextNotAllowed
            }
            return ParseResult.Valid(ServerAddress(normalise(url)))
        }

        /** Restores an address that already passed [parse]. */
        fun restore(stored: String): ServerAddress? = stored.toHttpUrlOrNull()?.let { ServerAddress(normalise(it)) }

        private fun normalise(url: HttpUrl): HttpUrl {
            val path = url.encodedPath.trimEnd('/').ifEmpty { "/" }
            return url.newBuilder().encodedPath(path).build()
        }

        internal fun isLocalHost(host: String): Boolean {
            val name = host.lowercase().trim('[', ']')
            if (name == "localhost" || name == "::1" || name.endsWith(".local")) return true
            val octets = name.split('.').map { it.toIntOrNull() ?: return false }
            if (octets.size != 4 || octets.any { it !in 0..255 }) return false
            val (a, b) = octets
            return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) ||
                (a == 169 && b == 254)
        }
    }
}
