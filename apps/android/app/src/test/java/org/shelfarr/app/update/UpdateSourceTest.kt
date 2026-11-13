package org.shelfarr.app.update

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.shelfarr.app.core.ServerAddress

class UpdateSourceTest {
    private val source = requireNotNull(UpdateSource.parse("https://shelfarr.alguidar.org/downloads/android-development.json"))

    private fun artifact(raw: String) = source.allowsArtifact(raw, raw.toHttpUrl())

    @Test
    fun `the trusted directory is the feed's own folder`() {
        assertEquals("/downloads/", source.directory)
    }

    @Test
    fun `a feed is required to be a plain https json document inside a directory`() {
        assertNull(UpdateSource.parse(""))
        assertNull(UpdateSource.parse(null))
        assertNull(UpdateSource.parse("http://shelfarr.alguidar.org/downloads/feed.json"))
        assertNull(UpdateSource.parse("https://user:pass@shelfarr.alguidar.org/downloads/feed.json"))
        assertNull(UpdateSource.parse("https://shelfarr.alguidar.org/downloads/feed.json?token=1"))
        assertNull(UpdateSource.parse("https://shelfarr.alguidar.org/downloads/feed.json#x"))
        assertNull(UpdateSource.parse("https://shelfarr.alguidar.org/feed.json"))
        assertNull(UpdateSource.parse("https://shelfarr.alguidar.org/downloads/feed.txt"))
        assertNull(UpdateSource.parse("https://shelfarr.alguidar.org/downloads/../feed.json"))
        assertNotNull(UpdateSource.parse("https://shelfarr.alguidar.org:8443/a/b/feed.json"))
    }

    @Test
    fun `accepts an apk in the publisher directory, including a subfolder`() {
        assertTrue(artifact("https://shelfarr.alguidar.org/downloads/shelfarr-3.apk"))
        assertTrue(artifact("https://shelfarr.alguidar.org/downloads/android/shelfarr-3.apk"))
        assertTrue(artifact("https://SHELFARR.alguidar.org:443/downloads/shelfarr-3.apk"))
    }

    @Test
    fun `refuses downgrades, other origins and other directories`() {
        assertFalse(artifact("http://shelfarr.alguidar.org/downloads/shelfarr-3.apk"))
        assertFalse(artifact("https://evil.example/downloads/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org.evil.example/downloads/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org:8443/downloads/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/api/v1/consumer/publications/1/file.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloadsx/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/shelfarr-3.zip"))
    }

    @Test
    fun `refuses credentials, queries, fragments and traversal, encoded or not`() {
        assertFalse(artifact("https://user@shelfarr.alguidar.org/downloads/shelfarr-3.apk"))
        assertFalse(artifact("https://user:pw@shelfarr.alguidar.org/downloads/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/shelfarr-3.apk?sig=abc"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/shelfarr-3.apk#x"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/../admin/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/%2e%2e/admin/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/%2E%2E/admin/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/..%2fadmin/shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads/./shelfarr-3.apk"))
        assertFalse(artifact("https://shelfarr.alguidar.org/downloads//shelfarr-3.apk"))
    }

    @Test
    fun `a relative redirect is judged on its text before it is resolved`() {
        val base = "https://shelfarr.alguidar.org/downloads/shelfarr-3.apk".toHttpUrl()
        // Resolution tidies "../" away; the text check must already have refused it.
        val sneaky = "../downloads/shelfarr-3.apk"
        assertEquals("/downloads/shelfarr-3.apk", base.resolve(sneaky)!!.encodedPath)
        assertFalse(source.allowsArtifact(sneaky, base.resolve(sneaky)!!))
        assertFalse(source.allowsArtifact("\\\\evil.example/x.apk", base.resolve("/downloads/x.apk")!!))
        val plain = "mirror/shelfarr-3.apk"
        assertTrue(source.allowsArtifact(plain, base.resolve(plain)!!))
    }

    private fun server(value: String) = (ServerAddress.parse(value) as ServerAddress.ParseResult.Valid).address

    @Test
    fun `a server's feed must resolve inside its own address, subpath included`() {
        val shelfarr = server("https://books.example.org/shelfarr")
        listOf(
            "/shelfarr/apps/android/release.json",
            "/apps/android/release.json",
            "apps/android/release.json",
            "https://books.example.org/shelfarr/apps/android/release.json",
        ).forEach { reference ->
            val feed = requireNotNull(UpdateSource.forServer(shelfarr, reference)) { reference }
            assertEquals(reference, "/shelfarr/apps/android/release.json", feed.feed.encodedPath)
            assertEquals(UpdateSource.Kind.SERVER, feed.kind)
            assertEquals("https://books.example.org/shelfarr", feed.server)
            assertEquals("/shelfarr/apps/android/", feed.directory)
        }
        listOf(
            "https://other.example.org/shelfarr/apps/android/release.json",
            "https://books.example.org/elsewhere/apps/android/release.json",
            "https://books.example.org:8443/shelfarr/apps/android/release.json",
            "http://books.example.org/shelfarr/apps/android/release.json",
            "//other.example.org/apps/android/release.json",
            "/shelfarr/../admin/release.json",
            "/shelfarr/apps/%2e%2e/release.json",
            "/shelfarr/apps/android/release.json?x=1",
            "/shelfarr/apps/android/release.json#x",
            "https://u:p@books.example.org/shelfarr/apps/android/release.json",
            "/shelfarr/apps/android/release",
            "/shelfarr/apps//release.json",
            "",
        ).forEach { reference -> assertNull(reference, UpdateSource.forServer(shelfarr, reference)) }
    }

    @Test
    fun `a server's APKs may sit in a folder beside its feed, but nowhere else`() {
        val feed = requireNotNull(UpdateSource.forServer(server("https://books.example.org/shelfarr"), "/shelfarr/apps/android/release.json"))
        fun allows(raw: String) = feed.allowsArtifact(raw, raw.toHttpUrl())
        assertTrue(allows("https://books.example.org/shelfarr/apps/android/release/42-${"a".repeat(64)}.apk"))
        assertFalse(allows("https://books.example.org/shelfarr/other/release/42.apk"))
        assertFalse(allows("https://books.example.org/apps/android/release/42.apk"))
        assertFalse(allows("https://github.com/Pedro-Revez-Silva/shelfarr/releases/download/x/42.apk"))
    }

    @Test
    fun `a plain HTTP server can't announce a feed`() {
        val local = (ServerAddress.parse("http://192.168.1.4:3000", allowLocalHttp = true) as ServerAddress.ParseResult.Valid).address
        assertNull(UpdateSource.forServer(local, "/apps/android/development.json"))
    }

    @Test
    fun `sources are equal only for the same feed, kind and server`() {
        val a = server("https://books.example.org")
        val one = UpdateSource.forServer(a, "/apps/android/release.json")
        assertEquals(one, UpdateSource.forServer(a, "https://books.example.org/apps/android/release.json"))
        assertFalse(one == UpdateSource.parse("https://books.example.org/apps/android/release.json"))
        assertFalse(one == UpdateSource.forServer(a, "/apps/android/development.json"))
    }
}
