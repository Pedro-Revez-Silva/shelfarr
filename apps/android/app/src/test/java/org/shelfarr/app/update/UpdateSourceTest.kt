package org.shelfarr.app.update

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
