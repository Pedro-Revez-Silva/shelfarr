package org.shelfarr.app.reader

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.mediatype.MediaType
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.shelfarr.app.core.ApiJson
import org.shelfarr.app.core.HeardPlaceMapper
import org.shelfarr.app.core.PendingMutation
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadAlong
import org.shelfarr.app.core.ReadAlongSource
import org.shelfarr.app.core.ServerAddress

/**
 * Opt-in: the client against bytes the real Rails API served (details with the feature
 * header, manifests and the EPUBs), recorded into SHELFARR_RAILS_WIRE_DIR by a server-side
 * integration run. Writes the progress bodies this app would send back, for that run to
 * PUT to the real progress endpoint. Skipped when the directory isn't given.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class RailsWireReadAlongTest {
    private val directory = System.getenv("SHELFARR_RAILS_WIRE_DIR")?.let(::File)
    private val server = (ServerAddress.parse("http://127.0.0.1:3000", true) as ServerAddress.ParseResult.Valid).address

    private fun read(name: String) = File(directory, name)

    private fun hrefs(epub: File, readAlong: ReadAlong): List<String> = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val http = DefaultHttpClient()
        val retriever = AssetRetriever(context.contentResolver, http)
        val asset = retriever.retrieve(epub, MediaType.EPUB).getOrElse { error("not an EPUB") }
        val publication = PublicationOpener(DefaultPublicationParser(context, http, retriever, pdfFactory = null))
            .open(asset, allowUserInteraction = false).getOrElse { error("Readium refused the server's EPUB") }
        val paths = publication.readingOrder.map { HeardPlaceMapper.decodePath(it.url().toString()) }
        readAlong.texts.map { text -> publication.readingOrder[paths.indexOf(text).also { assertTrue("$text not in the reading order", it >= 0) }].url().toString() }
    }

    private fun case(name: String, expected: ReadAlongSource): Pair<ReadAlong, HeardPlaceMapper> {
        val publication = ApiJson.decodeFromString<Publication>(read("detail-$name.json").readText())
        val asset = publication.epubAsset!!
        val summary = assertNotNull(asset.readAlong).let { asset.readAlong!! }
        assertTrue("summary: $summary", summary.isAvailable)
        val readAlong = read("manifest-$name.json").inputStream().use { ReadAlong.read(it, asset.id, summary.generation, server) }
        assertEquals(expected, readAlong.source)
        return readAlong to HeardPlaceMapper(readAlong, hrefs(read("$name.epub"), readAlong))
    }

    private fun write(name: String, mutation: PendingMutation) =
        read(name).writeText(ApiJson.encodeToString(mutation.toUpdate()))

    @Test
    fun theRealServersManifestsParseAndHeardPlacesAreWrittenBack() {
        assumeTrue("SHELFARR_RAILS_WIRE_DIR not set", directory?.isDirectory == true)
        val heardAt = System.currentTimeMillis() - 30_000

        val (overlay, overlayMapper) = case("overlay", ReadAlongSource.MEDIA_OVERLAY)
        assertEquals(8, overlay.cueCount)
        val heard = overlayMapper.placesAt(0, 13_743)
        write("put-overlay.json", PendingMutation(heard.ebook!!, 0, UUID.randomUUID().toString(), heardAt))

        val (imported, importedMapper) = case("imported", ReadAlongSource.IMPORTED)
        val paired = importedMapper.placesAt(0, 9_250)
        assertNotNull(paired.audiobook)
        write("put-imported-ebook.json", PendingMutation(paired.ebook!!, 0, UUID.randomUUID().toString(), heardAt))
        write("put-imported-audiobook.json", PendingMutation(paired.audiobook!!, 0, UUID.randomUUID().toString(), heardAt))
        read("paired-publication.txt").writeText(imported.pairedPublicationId!!)

        // A saved place read back from the server is restored exactly, by this generation.
        val back = ApiJson.parseToJsonElement(read("put-overlay.json").readText()) as JsonObject
        val restored = overlay.placeFromLocator(back["locator"] as JsonObject, overlayMapper::textIndexOf)
        assertEquals(13_743L, restored!!.offsetMs)
        assertTrue(restored.exact)
    }
}
