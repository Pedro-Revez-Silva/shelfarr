package org.shelfarr.app.core

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/** Every answer that describes publications is asked for in the formats this app reads. */
class ReaderFormatsHeaderTest {
    private val web = MockWebServer()
    private lateinit var server: ServerAddress
    private lateinit var api: ConsumerApi
    private val publication = """{"id":"b","title":"T","book_type":"ebook"}"""

    @Before
    fun setUp() {
        web.start()
        server = (ServerAddress.parse(web.url("/").toString(), true) as ServerAddress.ParseResult.Valid).address
        api = ConsumerApi(buildHttpClient({ Credential(server, "token") }))
    }

    @After
    fun tearDown() = web.close()

    private fun respond(body: String) = web.enqueue(MockResponse.Builder().code(200).body(body).build())

    @Test
    fun `library, details, Continue and status changes declare epub, pdf and cbz`() = runTest {
        respond("""{"items":[$publication],"next_cursor":"n"}""")
        api.library(server, LibraryQuery(), cursor = "c")
        respond("""{"items":[$publication],"next_cursor":null}""")
        api.library(server, LibraryQuery(), cursor = "n")
        respond(publication)
        api.publication(server, "b")
        respond("""{"items":[$publication]}""")
        api.continueReading(server)
        respond(publication)
        api.setReadingStatus(server, "b", ReadingStatus.FINISHED)
        repeat(5) { assertEquals("epub,pdf,cbz", web.takeRequest().headers[READER_FORMATS_HEADER]) }

        // Calls that describe no publication are unchanged.
        respond("""{"id":"u"}""")
        api.me(server)
        assertNull(web.takeRequest().headers[READER_FORMATS_HEADER])
    }
}
