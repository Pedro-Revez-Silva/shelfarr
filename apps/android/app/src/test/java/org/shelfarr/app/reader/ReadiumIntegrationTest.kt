package org.shelfarr.app.reader

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.positions
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.mediatype.MediaType
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Opens a real EPUB through the same Readium path the reader uses. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class ReadiumIntegrationTest {
    @get:Rule val folder = TemporaryFolder()

    private fun writeEpub(): File {
        val file = folder.newFile("book.epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            fun entry(name: String, content: String, stored: Boolean = false) {
                val zipEntry = ZipEntry(name)
                if (stored) {
                    val bytes = content.toByteArray()
                    zipEntry.method = ZipEntry.STORED
                    zipEntry.size = bytes.size.toLong()
                    zipEntry.compressedSize = bytes.size.toLong()
                    zipEntry.crc = java.util.zip.CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(zipEntry)
                zip.write(content.toByteArray())
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip", stored = true)
            entry(
                "META-INF/container.xml",
                """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""",
            )
            entry(
                "OEBPS/content.opf",
                """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:test</dc:identifier>
                <dc:title>Integration</dc:title><dc:language>en</dc:language></metadata>
                <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>""",
            )
            entry(
                "OEBPS/nav.xhtml",
                """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
                <nav epub:type="toc"><ol><li><a href="c1.xhtml">One</a></li><li><a href="c2.xhtml">Two</a></li></ol></nav></body></html>""",
            )
            val text = "Reading. ".repeat(800)
            entry("OEBPS/c1.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><body><p>$text</p></body></html>""")
            entry("OEBPS/c2.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><body><p>$text</p></body></html>""")
        }
        return file
    }

    private suspend fun open(file: File): Publication? {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val http = DefaultHttpClient()
        val retriever = AssetRetriever(context.contentResolver, http)
        val opener = PublicationOpener(DefaultPublicationParser(context, http, retriever, pdfFactory = null))
        val asset = retriever.retrieve(file, MediaType.EPUB).getOrElse { return null }
        return opener.open(asset, allowUserInteraction = false).getOrElse { return null }
    }

    @Test
    fun `opens an epub, exposes contents and positions, and locators survive JSON`() = runTest {
        val publication = assertNotNullResult(open(writeEpub()))
        assertEquals("Integration", publication.metadata.title)
        assertEquals(listOf("One", "Two"), publication.tableOfContents.map { it.title })

        val positions = publication.positions()
        assertTrue(positions.size >= 2)
        val locator = positions.last()
        val restored = Locator.fromJSON(JSONObject(locator.toJSON().toString()))
        assertEquals(locator, restored)
        assertNotNull(locator.locations.totalProgression)
    }

    @Test
    fun `a file that is not an epub cannot open`() = runTest {
        val file = folder.newFile("broken.epub").apply { writeText("PK not really a zip") }
        assertNull(open(file))
    }

    @Test
    fun `reader settings always form valid Readium preferences`() {
        for (theme in ReaderTheme.entries) {
            for (font in ReaderFont.entries) {
                val preferences = ReaderSettings(theme = theme, font = font, fontSize = 2.5, justify = true).toPreferences()
                assertEquals(theme.readium, preferences.theme)
                assertEquals(font == ReaderFont.ORIGINAL, preferences.publisherStyles)
            }
        }
    }

    private fun <T : Any> assertNotNullResult(value: T?): T {
        assertNotNull(value)
        return value!!
    }
}
