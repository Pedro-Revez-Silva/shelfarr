package org.shelfarr.app.ui.setup

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.shelfarr.app.core.DeviceGrant
import org.shelfarr.app.core.PendingAuthorization
import org.shelfarr.app.core.ServerAddress

/** A sign-in started from a link may only send the browser to the linked server's own pages. */
class ApprovalBoundaryTest {
    private val server = (ServerAddress.parse("https://books.example.org/shelfarr") as ServerAddress.ParseResult.Valid).address

    private fun pending(uri: String, complete: String = uri) =
        PendingAuthorization(server, DeviceGrant("device", "ABCD-EFGH", uri, complete, 600), Long.MAX_VALUE)

    @Test
    fun `the server's own approval pages are fine, relative or absolute`() {
        assertTrue(approvalStaysOnServer(pending("/shelfarr/consumer/connect", "/shelfarr/consumer/connect?user_code=ABCD")))
        assertTrue(approvalStaysOnServer(pending("https://books.example.org/shelfarr/consumer/connect")))
        assertTrue(approvalStaysOnServer(pending("consumer/connect")))
    }

    @Test
    fun `anywhere else is refused`() {
        listOf(
            "https://evil.example.org/shelfarr/consumer/connect",
            "https://books.example.org/other/consumer/connect",
            "http://books.example.org/shelfarr/consumer/connect",
            "https://user:pw@books.example.org/shelfarr/consumer/connect",
            "https://books.example.org:8443/shelfarr/consumer/connect",
            "//evil.example.org/x",
            "javascript:alert(1)",
        ).forEach { uri ->
            assertFalse(uri, approvalStaysOnServer(pending(uri)))
            assertFalse(uri, approvalStaysOnServer(pending("/shelfarr/consumer/connect", uri)))
        }
    }
}
