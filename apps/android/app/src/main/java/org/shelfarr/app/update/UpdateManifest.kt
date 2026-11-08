package org.shelfarr.app.update

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

/** One release the publisher feed announces, after every field has been checked. */
data class UpdateRelease(
    val channel: String,
    val packageName: String,
    val versionCode: Int,
    val versionName: String,
    val apkUrl: HttpUrl,
    val sizeBytes: Long,
    /** Lowercase hex SHA-256 of the whole APK. */
    val sha256: String,
    val releaseNotes: String?,
    val minSdk: Int?,
    /**
     * The consumer API generations this build speaks. Required from a Shelfarr server's
     * feed; the built-in publisher feed may leave it out, meaning generation 1.
     */
    val consumerApiVersions: Set<Int>? = null,
) {
    /** The canonical feed document for this release, kept so a relaunch can re-check it. */
    fun toJson(): String = buildJsonObject {
        put("schema_version", UpdateManifest.SCHEMA_VERSION)
        put("channel", channel)
        put("package_name", packageName)
        put("version_code", versionCode)
        put("version_name", versionName)
        put("apk_url", apkUrl.toString())
        put("size_bytes", sizeBytes)
        put("sha256", sha256)
        releaseNotes?.let { put("release_notes", it) }
        minSdk?.let { put("min_sdk", it) }
        consumerApiVersions?.let { versions -> putJsonArray("consumer_api_versions") { versions.sorted().forEach { add(JsonPrimitive(it)) } } }
    }.toString()

    /** Whether this build can talk to a server speaking [serverVersions]. */
    fun worksWith(serverVersions: Set<Int>): Boolean = (consumerApiVersions ?: setOf(ConsumerApiGenerations.ORIGINAL)).any(serverVersions::contains)
}

/** Consumer API generations, independent of server and app release labels. */
object ConsumerApiGenerations {
    /** What servers from before update discovery speak, and what feeds without the field mean. */
    const val ORIGINAL = 1

    /** The generations this build of the app speaks. */
    val SUPPORTED: Set<Int> = setOf(1)
}

/** What this build expects of its feed. A Shelfarr server's feed must say which API generations each build speaks. */
data class FeedExpectation(val source: UpdateSource, val channel: String, val packageName: String) {
    val requiresApiVersions: Boolean get() = source.kind == UpdateSource.Kind.SERVER
}

/**
 * Parses the publisher feed. Version 1:
 *
 * ```
 * {
 *   "schema_version": 1,
 *   "channel": "development",
 *   "package_name": "org.shelfarr.app.debug",
 *   "version_code": 3,
 *   "version_name": "0.1.2-debug",
 *   "apk_url": "https://example.org/downloads/shelfarr-android-development-3.apk",
 *   "size_bytes": 41234567,
 *   "sha256": "<64 lowercase hex>",
 *   "release_notes": "Optional, plain text, at most 4000 characters",
 *   "min_sdk": 26,
 *   "consumer_api_versions": [1]
 * }
 * ```
 *
 * `consumer_api_versions` is required in a Shelfarr server's feed and optional in the
 * built-in publisher feed.
 *
 * Unknown fields are ignored so a later publisher may add some. Wrong types,
 * out-of-range values and URLs outside the trusted directory reject the feed.
 */
object UpdateManifest {
    const val SCHEMA_VERSION = 1
    const val MAX_FEED_BYTES = 64L * 1024
    const val MAX_APK_BYTES = 256L * 1024 * 1024
    const val MAX_VERSION_CODE = 2_100_000_000
    const val MAX_NOTES_CHARS = 4_000
    private const val MAX_NAME_CHARS = 64
    private const val MAX_API_VERSIONS = 16

    private val json = Json { isLenient = false }
    private val VERSION_NAME = Regex("[0-9A-Za-z][0-9A-Za-z._+-]*")
    private val SHA256 = Regex("[0-9a-f]{64}")

    fun parse(body: String, expected: FeedExpectation): UpdateRelease {
        val root = try {
            json.parseToJsonElement(body).jsonObject
        } catch (error: SerializationException) {
            throw UpdateException(UpdateProblem.BAD_FEED, "The update feed isn't valid JSON", error)
        } catch (error: IllegalArgumentException) {
            throw UpdateException(UpdateProblem.BAD_FEED, "The update feed isn't a JSON object", error)
        }

        val schema = root.integer("schema_version", 1..Int.MAX_VALUE)
        if (schema != SCHEMA_VERSION) {
            throw UpdateException(UpdateProblem.BAD_FEED, "The update feed uses a format this version doesn't understand")
        }
        val channel = root.text("channel", 64)
        if (channel != expected.channel) bad("The update feed is for the \"$channel\" channel")
        val packageName = root.text("package_name", 255)
        if (packageName != expected.packageName) {
            throw UpdateException(UpdateProblem.WRONG_APP, "The update feed is for a different app")
        }
        val versionCode = root.integer("version_code", 1..MAX_VERSION_CODE)
        val versionName = root.text("version_name", MAX_NAME_CHARS)
        if (!VERSION_NAME.matches(versionName)) bad("The update's version name isn't usable")
        val rawUrl = root.text("apk_url", 2_048)
        val apkUrl = try {
            rawUrl.toHttpUrl()
        } catch (_: IllegalArgumentException) {
            null
        }
        if (apkUrl == null || !expected.source.allowsArtifact(rawUrl, apkUrl)) {
            throw UpdateException(UpdateProblem.UNTRUSTED_LOCATION, "The update file isn't hosted where this app trusts")
        }
        val size = root.long("size_bytes", 1..MAX_APK_BYTES)
        val sha256 = root.text("sha256", 64)
        if (!SHA256.matches(sha256)) bad("The update's checksum isn't a SHA-256 value")
        val notes = root.optionalText("release_notes", MAX_NOTES_CHARS)?.let(::plainText)?.takeIf(String::isNotBlank)
        val minSdk = if (root["min_sdk"] == null || root["min_sdk"] is JsonNull) null else root.integer("min_sdk", 1..1_000)
        val apiVersions = when (root["consumer_api_versions"]) {
            null, JsonNull -> if (expected.requiresApiVersions) bad("The update feed is missing consumer_api_versions") else null
            else -> apiVersions(root, "consumer_api_versions")
        }

        return UpdateRelease(channel, packageName, versionCode, versionName, apkUrl, size, sha256, notes, minSdk, apiVersions)
    }

    /** A non-empty list of distinct whole numbers from 1 to 1000. Shared with server discovery. */
    internal fun apiVersions(root: JsonObject, name: String, describe: String = "update feed"): Set<Int> {
        val array = root[name] as? JsonArray ?: throw UpdateException(UpdateProblem.BAD_FEED, "The $describe's $name isn't a list")
        if (array.isEmpty() || array.size > MAX_API_VERSIONS) throw UpdateException(UpdateProblem.BAD_FEED, "The $describe's $name is empty or too long")
        val versions = array.map { element ->
            val value = element as? JsonPrimitive
            val number = value?.takeIf { !it.isString && it.content.all(Char::isDigit) }?.longOrNull
            if (number == null || number !in 1L..1_000L) throw UpdateException(UpdateProblem.BAD_FEED, "The $describe's $name must list whole numbers")
            number.toInt()
        }
        if (versions.toSet().size != versions.size) throw UpdateException(UpdateProblem.BAD_FEED, "The $describe's $name repeats a version")
        return versions.toSet()
    }

    /** Keeps line breaks and tabs, drops other control characters. */
    private fun plainText(value: String): String =
        value.replace("\r\n", "\n").filter { it == '\n' || it == '\t' || !it.isISOControl() }.trim()

    private fun bad(message: String): Nothing = throw UpdateException(UpdateProblem.BAD_FEED, message)

    private fun JsonObject.primitive(name: String): JsonPrimitive {
        val value: JsonElement = this[name] ?: bad("The update feed is missing $name")
        return value as? JsonPrimitive ?: bad("The update feed's $name has the wrong type")
    }

    private fun JsonObject.text(name: String, maxChars: Int): String {
        val value = primitive(name)
        if (!value.isString) bad("The update feed's $name has the wrong type")
        val content = value.content
        if (content.isEmpty() || content.length > maxChars) bad("The update feed's $name is empty or too long")
        return content
    }

    private fun JsonObject.optionalText(name: String, maxChars: Int): String? {
        val value = this[name] ?: return null
        if (value is JsonNull) return null
        val primitive = value as? JsonPrimitive ?: bad("The update feed's $name has the wrong type")
        if (!primitive.isString) bad("The update feed's $name has the wrong type")
        // Match Ruby String#length and Python len: Unicode codepoints, rather
        // than UTF-16 code units (an emoji can occupy two of those).
        if (primitive.content.codePointCount(0, primitive.content.length) > maxChars) bad("The update feed's $name is too long")
        return primitive.content
    }

    private fun JsonObject.long(name: String, range: LongRange): Long {
        val value = primitive(name)
        // A quoted number, a fraction or an exponent is not an integer field.
        if (value.isString || !value.content.all { it.isDigit() || it == '-' }) {
            bad("The update feed's $name must be a whole number")
        }
        val number = value.longOrNull ?: bad("The update feed's $name must be a whole number")
        if (number !in range) bad("The update feed's $name is out of range")
        return number
    }

    private fun JsonObject.integer(name: String, range: IntRange): Int =
        long(name, range.first.toLong()..range.last.toLong()).toInt()
}
