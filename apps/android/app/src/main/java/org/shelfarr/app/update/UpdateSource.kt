package org.shelfarr.app.update

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * The publisher feed fixed when the app was built, and the only place updates may
 * come from. Trust never depends on the Shelfarr server or account in use: the feed,
 * every redirect and the APK must stay on the feed's HTTPS origin, inside the
 * directory that holds the feed.
 */
class UpdateSource private constructor(val feed: HttpUrl) {
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

    override fun toString(): String = "UpdateSource($feed)"

    companion object {
        private const val MAX_URL_LENGTH = 2_048

        /** The build-time feed, or null when updates are switched off or it is unusable. */
        fun parse(value: String?): UpdateSource? {
            val raw = value?.trim().orEmpty()
            if (raw.isEmpty() || !isClean(raw)) return null
            val url = raw.toHttpUrlOrNull() ?: return null
            if (!url.isHttps || url.username.isNotEmpty() || url.password.isNotEmpty()) return null
            if (url.query != null || url.fragment != null) return null
            if (!url.encodedPath.endsWith(".json") || url.pathSize < 2) return null
            return UpdateSource(url)
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
