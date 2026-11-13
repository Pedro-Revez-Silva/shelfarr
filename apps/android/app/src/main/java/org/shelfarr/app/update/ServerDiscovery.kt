package org.shelfarr.app.update

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import org.shelfarr.app.core.ServerAddress

/** What a Shelfarr server says about app updates. */
sealed interface ServerUpdates {
    /** The server predates update discovery: it answered 404 or 410 for its description. */
    data object NotOffered : ServerUpdates

    /**
     * A server that describes itself. [source] is its feed for the asked-for channel, or
     * null when it doesn't offer that channel.
     */
    data class Described(val apiVersions: Set<Int>, val source: UpdateSource?) : ServerUpdates
}

/**
 * Reads `GET <server>/api/consumer/v1/server.json`, which needs no credential:
 *
 * ```
 * {
 *   "schema_version": 1,
 *   "server_version": "2026.11.1",
 *   "consumer_api_versions": [1],
 *   "android": {
 *     "release": { "feed_url": "/apps/android/release.json", "download_page_url": "/apps/android" },
 *     "development": { "feed_url": "/apps/android/development.json", "download_page_url": "/apps/android?channel=development" }
 *   }
 * }
 * ```
 *
 * It uses the updater's own HTTP client, which has no credential, cookies or cache.
 * The description and every redirect must stay on the server's HTTPS address. A
 * channel's feed may be relative or absolute but must resolve inside that address.
 */
class ServerDiscovery(private val client: OkHttpClient) {
    /**
     * Throws [UpdateException] when the server couldn't be asked or answered something
     * unusable; callers must then keep what they had rather than switch publishers.
     */
    suspend fun discover(server: ServerAddress, channel: String): ServerUpdates {
        if (server.isCleartext) throw UpdateException(UpdateProblem.UNTRUSTED_LOCATION, "Updates need a secure https:// server")
        val url = server.api(PATH)
        val body = try {
            guardedGet(
                client = client,
                raw = url.toString(),
                url = url,
                allowed = { raw, target -> allows(server, raw, target) },
                headers = {
                    header("Accept", "application/json")
                    header("Cache-Control", "no-cache")
                },
            ) { response -> boundedText(response, MAX_BYTES) { throw bad("The server's description is too large") } }
        } catch (error: UpdateException) {
            if (error.problem == UpdateProblem.SERVER && (error.status == 404 || error.status == 410)) return ServerUpdates.NotOffered
            throw error
        }
        return parse(body, server, channel)
    }

    private fun allows(server: ServerAddress, raw: String, url: HttpUrl): Boolean =
        UpdateSource.isClean(raw) && url.isHttps && url.username.isEmpty() && url.password.isEmpty() &&
            url.query == null && url.fragment == null && server.contains(url) &&
            url.encodedPath.endsWith(".json") && url.pathSegments.none { it.isEmpty() || it == "." || it == ".." }

    companion object {
        const val PATH = "server.json"
        const val SCHEMA_VERSION = 1
        const val MAX_BYTES = 32L * 1024

        private val json = Json { isLenient = false }

        internal fun parse(body: String, server: ServerAddress, channel: String): ServerUpdates.Described {
            val root = try {
                json.parseToJsonElement(body).jsonObject
            } catch (error: SerializationException) {
                throw UpdateException(UpdateProblem.BAD_FEED, "The server's description isn't valid JSON", error)
            } catch (error: IllegalArgumentException) {
                throw UpdateException(UpdateProblem.BAD_FEED, "The server's description isn't a JSON object", error)
            }
            val schema = (root["schema_version"] as? JsonPrimitive)?.takeIf { !it.isString }?.content
            if (schema != SCHEMA_VERSION.toString()) throw bad("The server describes itself in a format this version doesn't understand")
            val versions = UpdateManifest.apiVersions(root, "consumer_api_versions", "server's description")
            val source = when (val android = root["android"]) {
                null, JsonNull -> null
                is JsonObject -> when (val entry = android[channel]) {
                    null, JsonNull -> null
                    is JsonObject -> {
                        val feed = (entry["feed_url"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                            ?: throw bad("The server's $channel updates have no feed")
                        UpdateSource.forServer(server, feed)
                            ?: throw UpdateException(UpdateProblem.UNTRUSTED_LOCATION, "The server's update feed isn't inside its own address")
                    }
                    else -> throw bad("The server's $channel updates aren't described properly")
                }
                else -> throw bad("The server's app updates aren't described properly")
            }
            return ServerUpdates.Described(versions, source)
        }

        private fun bad(message: String) = UpdateException(UpdateProblem.BAD_FEED, message)
    }
}
