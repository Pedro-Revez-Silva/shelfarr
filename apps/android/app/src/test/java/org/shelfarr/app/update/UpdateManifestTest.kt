package org.shelfarr.app.update

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class UpdateManifestTest {
    private val source = requireNotNull(UpdateSource.parse("https://updates.example.org/downloads/android-development.json"))
    private val expected = FeedExpectation(source, "development", PACKAGE)
    private val sha = "0123456789abcdef".repeat(4)

    private fun feed(vararg changes: Pair<String, JsonElement?>): String {
        val fields = linkedMapOf<String, JsonElement?>(
            "schema_version" to JsonPrimitive(1),
            "channel" to JsonPrimitive("development"),
            "package_name" to JsonPrimitive(PACKAGE),
            "version_code" to JsonPrimitive(3),
            "version_name" to JsonPrimitive("0.1.2-debug"),
            "apk_url" to JsonPrimitive("https://updates.example.org/downloads/shelfarr-3.apk"),
            "size_bytes" to JsonPrimitive(41_000_000),
            "sha256" to JsonPrimitive(sha),
        )
        changes.forEach { (key, value) -> fields[key] = value }
        return buildJsonObject { fields.forEach { (key, value) -> if (value != null) put(key, value) } }.toString()
    }

    private fun rejects(problem: UpdateProblem, body: String) {
        val error = assertThrows(UpdateException::class.java) { UpdateManifest.parse(body, expected) }
        assertEquals(error.message, problem, error.problem)
    }

    @Test
    fun `parses a valid feed and ignores fields it doesn't know`() {
        val release = UpdateManifest.parse(
            feed(
                "release_notes" to JsonPrimitive("Line one\r\nLine two\u0007"),
                "min_sdk" to JsonPrimitive(26),
                "published_at" to JsonPrimitive("2026-11-08"),
            ),
            expected,
        )
        assertEquals(3, release.versionCode)
        assertEquals("0.1.2-debug", release.versionName)
        assertEquals(41_000_000L, release.sizeBytes)
        assertEquals("Line one\nLine two", release.releaseNotes)
        assertEquals(26, release.minSdk)
        // What a relaunch re-reads parses back to the same release.
        assertEquals(release, UpdateManifest.parse(release.toJson(), expected))
    }

    @Test
    fun `optional fields may be missing or null`() {
        val release = UpdateManifest.parse(feed("release_notes" to JsonNull, "min_sdk" to JsonNull), expected)
        assertNull(release.releaseNotes)
        assertNull(release.minSdk)
    }

    @Test
    fun `release note limits count Unicode codepoints like the publisher and server`() {
        val notes = "😀".repeat(UpdateManifest.MAX_NOTES_CHARS)
        assertEquals(notes, UpdateManifest.parse(feed("release_notes" to JsonPrimitive(notes)), expected).releaseNotes)
        rejects(UpdateProblem.BAD_FEED, feed("release_notes" to JsonPrimitive(notes + "😀")))
    }

    @Test
    fun `refuses a feed for another app or channel`() {
        rejects(UpdateProblem.WRONG_APP, feed("package_name" to JsonPrimitive("org.shelfarr.app")))
        rejects(UpdateProblem.WRONG_APP, feed("package_name" to JsonPrimitive("com.evil.debug")))
        rejects(UpdateProblem.BAD_FEED, feed("channel" to JsonPrimitive("release")))
    }

    @Test
    fun `refuses an unknown schema and malformed documents`() {
        rejects(UpdateProblem.BAD_FEED, feed("schema_version" to JsonPrimitive(2)))
        rejects(UpdateProblem.BAD_FEED, feed("schema_version" to null))
        rejects(UpdateProblem.BAD_FEED, "[]")
        rejects(UpdateProblem.BAD_FEED, "not json")
        rejects(UpdateProblem.BAD_FEED, "{\"schema_version\": 1,}")
    }

    @Test
    fun `numbers must be whole, unquoted and in range`() {
        rejects(UpdateProblem.BAD_FEED, feed("version_code" to JsonPrimitive("3")))
        rejects(UpdateProblem.BAD_FEED, feed("version_code" to JsonPrimitive(3.5)))
        rejects(UpdateProblem.BAD_FEED, feed("version_code" to JsonPrimitive(0)))
        rejects(UpdateProblem.BAD_FEED, feed("version_code" to JsonPrimitive(-4)))
        rejects(UpdateProblem.BAD_FEED, feed("version_code" to JsonPrimitive(3_000_000_000)))
        rejects(UpdateProblem.BAD_FEED, feed("size_bytes" to JsonPrimitive(0)))
        rejects(UpdateProblem.BAD_FEED, feed("size_bytes" to JsonPrimitive(UpdateManifest.MAX_APK_BYTES + 1)))
        rejects(UpdateProblem.BAD_FEED, feed("size_bytes" to JsonPrimitive(1e6)))
    }

    @Test
    fun `refuses unusable names, checksums and notes`() {
        rejects(UpdateProblem.BAD_FEED, feed("version_name" to JsonPrimitive("")))
        rejects(UpdateProblem.BAD_FEED, feed("version_name" to JsonPrimitive("1.0 <b>")))
        rejects(UpdateProblem.BAD_FEED, feed("sha256" to JsonPrimitive(sha.uppercase())))
        rejects(UpdateProblem.BAD_FEED, feed("sha256" to JsonPrimitive(sha.dropLast(1))))
        rejects(UpdateProblem.BAD_FEED, feed("release_notes" to JsonPrimitive("x".repeat(UpdateManifest.MAX_NOTES_CHARS + 1))))
        rejects(UpdateProblem.BAD_FEED, feed("release_notes" to JsonPrimitive(5)))
    }

    @Test
    fun `refuses an apk outside the trusted origin and directory`() {
        listOf(
            "http://updates.example.org/downloads/shelfarr-3.apk",
            "https://evil.example/downloads/shelfarr-3.apk",
            "https://updates.example.org/api/v1/consumer/files/3.apk",
            "https://updates.example.org/downloads/../api/shelfarr-3.apk",
            "https://token@updates.example.org/downloads/shelfarr-3.apk",
            "/downloads/shelfarr-3.apk",
            "not a url",
        ).forEach { url -> rejects(UpdateProblem.UNTRUSTED_LOCATION, feed("apk_url" to JsonPrimitive(url))) }
    }

    @Test
    fun `refuses a document that only claims fields with the wrong types`() {
        rejects(UpdateProblem.BAD_FEED, buildJsonObject { put("schema_version", 1); put("channel", 7) }.toString())
    }

    private val serverSource = requireNotNull(
        UpdateSource.forServer(
            (org.shelfarr.app.core.ServerAddress.parse("https://updates.example.org") as org.shelfarr.app.core.ServerAddress.ParseResult.Valid).address,
            "/downloads/android-development.json",
        ),
    )

    @Test
    fun `a server's feed must list the API generations the build speaks`() {
        val fromServer = FeedExpectation(serverSource, "development", PACKAGE)
        val missing = assertThrows(UpdateException::class.java) { UpdateManifest.parse(feed(), fromServer) }
        assertEquals(UpdateProblem.BAD_FEED, missing.problem)
        val versions = kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive(1), JsonPrimitive(2)))
        val release = UpdateManifest.parse(feed("consumer_api_versions" to versions), fromServer)
        assertEquals(setOf(1, 2), release.consumerApiVersions)
        assertEquals(release, UpdateManifest.parse(release.toJson(), fromServer))
        assertEquals(true, release.worksWith(setOf(2)))
        assertEquals(false, release.worksWith(setOf(3)))
    }

    @Test
    fun `the built-in feed may leave the API generations out, meaning the original one`() {
        val release = UpdateManifest.parse(feed(), expected)
        assertNull(release.consumerApiVersions)
        assertEquals(true, release.worksWith(setOf(ConsumerApiGenerations.ORIGINAL)))
        assertEquals(false, release.worksWith(setOf(2)))
        assertEquals(release, UpdateManifest.parse(release.toJson(), expected))
    }

    @Test
    fun `malformed API generations reject the feed`() {
        listOf("[]", "[\"1\"]", "[0]", "[1001]", "[1,1]", "[1.0]", "1", "{}").forEach { raw ->
            val value = kotlinx.serialization.json.Json.parseToJsonElement(raw)
            rejects(UpdateProblem.BAD_FEED, feed("consumer_api_versions" to value))
        }
    }
}
