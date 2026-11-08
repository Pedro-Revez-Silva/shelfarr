package org.shelfarr.app.update

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.shelfarr.app.core.ServerAddress

/**
 * One update feed and the only place its updates may come from. The feed, every
 * redirect and the APK must stay on the feed's HTTPS origin, inside the directory
 * that holds the feed.
 *
 * A feed is either fixed when the app was built ([Kind.BUILT_IN], kept for servers
 * that predate update discovery), or announced by the connected Shelfarr server
 * ([Kind.SERVER]), in which case it must also sit inside that server's address,
 * subpath included. Neither ever receives the account's credential.
 */
class UpdateSource private constructor(
    val feed: HttpUrl,
    val kind: Kind,
    /** The Shelfarr server's [ServerAddress.identity] for [Kind.SERVER]; null for the built-in feed. */
    val server: String?,
) {
    enum class Kind { BUILT_IN, SERVER }

    /** The feed's directory, ending in `/`, for example `/downloads/`. */
    val directory: String = feed.encodedPath.substringBeforeLast('/') + "/"

    /** Where a feed redirect may lead: another JSON document in the same directory. */
    fun allowsFeed(raw: String, url: HttpUrl): Boolean = allows(raw, url) && url.encodedPath.endsWith(".json")

    /** Where the APK, and each redirect towards it, may be. */
    fun allowsArtifact(raw: String, url: HttpUrl): Boolean = allows(raw, url) && url.encodedPath.endsWith(".apk")

    /**
     * [raw] is the text as the publisher wrote it and [url] its parsed form. Both are
     * checked: parsing quietly removes dot segments, so `downloads/../admin` must be
     * refused from the text rather than accepted as `/admin`'s neighbour.
     */
    private fun allows(raw: String, url: HttpUrl): Boolean {
        if (!isClean(raw)) return false
        return url.isHttps &&
            url.host == feed.host &&
            url.port == feed.port &&
            url.username.isEmpty() &&
            url.password.isEmpty() &&
            url.query == null &&
            url.fragment == null &&
            url.encodedPath.startsWith(directory) &&
            url.encodedPath.length > directory.length &&
            url.pathSegments.none { it.isEmpty() || it == "." || it == ".." }
    }

    override fun equals(other: Any?): Boolean =
        other is UpdateSource && other.feed == feed && other.kind == kind && other.server == server

    override fun hashCode(): Int = (feed.hashCode() * 31 + kind.hashCode()) * 31 + server.hashCode()

    override fun toString(): String = "UpdateSource($kind, $feed)"

    companion object {
        private const val MAX_URL_LENGTH = 2_048

        /** The build-time feed, or null when there is none or it is unusable. */
        fun parse(value: String?): UpdateSource? {
            val url = feedUrl(value) ?: return null
            return UpdateSource(url, Kind.BUILT_IN, null)
        }

        /**
         * A feed [server] announced. [reference] may be relative to the server
         * (`/apps/android/release.json`, with or without its subpath) or absolute; either
         * way it must resolve inside the server's HTTPS address. Null if it doesn't.
         */
        fun forServer(server: ServerAddress, reference: String): UpdateSource? {
            if (server.isCleartext) return null
            val value = reference.trim()
            if (!isClean(value)) return null
            val url = server.resolve(value) ?: return null
            // Re-check the resolved text too: resolving must not have produced anything unclean.
            val resolved = feedUrl(url.toString()) ?: return null
            if (!server.contains(resolved)) return null
            return UpdateSource(resolved, Kind.SERVER, server.identity)
        }

        /** Restores a source saved by [AppUpdater]; null if it no longer passes the same checks. */
        internal fun restore(kind: Kind, feed: String, server: ServerAddress?): UpdateSource? = when (kind) {
            Kind.BUILT_IN -> parse(feed)
            Kind.SERVER -> server?.let { forServer(it, feed) }
        }

        private fun feedUrl(value: String?): HttpUrl? {
            val raw = value?.trim().orEmpty()
            if (raw.isEmpty() || !isClean(raw)) return null
            val url = raw.toHttpUrlOrNull() ?: return null
            if (!url.isHttps || url.username.isNotEmpty() || url.password.isNotEmpty()) return null
            if (url.query != null || url.fragment != null) return null
            if (!url.encodedPath.endsWith(".json") || url.pathSize < 2) return null
            if (url.pathSegments.any { it.isEmpty() }) return null
            return url
        }

        /**
         * Text a trusted URL may never contain, whether or not a parser would tidy it:
         * credentials, fragments, queries, backslashes, control characters and
         * encoded or literal dot segments and separators.
         */
        internal fun isClean(raw: String): Boolean {
            if (raw.isEmpty() || raw.length > MAX_URL_LENGTH) return false
            if (raw.any { it.code <= 0x20 || it.code >= 0x7f }) return false
            if (raw.any { it in "\\@#?" }) return false
            val lower = raw.lowercase()
            if (listOf("%2e", "%2f", "%5c", "%00", "%40", "%23", "%3f").any(lower::contains)) return false
            // Absolute or relative (a redirect's Location): no segment may be a dot segment.
            return lower.substringAfter("://").split('/').none { it == "." || it == ".." }
        }
    }
}
