package org.shelfarr.app.ui

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DownloadProblem
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.DownloadedFile
import org.shelfarr.app.core.NarrationDownload
import org.shelfarr.app.core.NarrationState
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadAlongSummary
import org.shelfarr.app.ui.downloads.DownloadPanel
import org.shelfarr.app.ui.downloads.NarrationAction
import org.shelfarr.app.ui.downloads.downloadCopy
import org.shelfarr.app.ui.downloads.narrationCopy
import org.shelfarr.app.ui.downloads.retryLabel
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/** What a narration request stopped before its manifest says, and offers, on the book's download. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class NarrationRecoveryCopyTest {
    @get:Rule val compose = createComposeRule()

    private val generation = "a".repeat(64)
    private val summary = ReadAlongSummary("available", "media_overlay", generation, "/m", audioBytes = 61_000_000)
    private val book = Publication(
        id = "garden-1", title = "The Narrated Garden", bookType = BookType.EBOOK,
        assets = listOf(Asset("epub-garden", "garden.epub", "application/epub+zip", "epub", 2_200_000, "/c", readAlong = summary)),
    )
    private val ready = DownloadRecord(
        "garden-1", book, listOf(DownloadedFile("epub-garden", "000-a.epub", 2_200_000, complete = true, bytesDone = 2_200_000)),
        DownloadState.READY, withNarration = true, narrationPending = true,
    )

    private fun stopped(problem: DownloadProblem) = ready.copy(narrationProblem = problem)

    @Test
    fun `a request stopped before its manifest says why and offers to resume it`() {
        val interrupted = narrationCopy(stopped(DownloadProblem.INTERRUPTED), summary, offline = false)!!
        assertEquals(NarrationAction.RETRY, interrupted.action)
        assertTrue(interrupted.text.startsWith("Narration stopped before it finished."))
        assertTrue(interrupted.text.endsWith("The book itself reads offline."))
        assertNull(interrupted.progress)
        assertEquals("Resume narration", retryLabel(stopped(DownloadProblem.INTERRUPTED)))
        assertEquals("Try narration again", retryLabel(stopped(DownloadProblem.SERVER)))

        val signedOut = narrationCopy(stopped(DownloadProblem.SIGN_IN), summary, offline = false)!!
        assertTrue(signedOut.text.contains("Sign in to this account again"))
        // Offline, there is nothing to retry yet; an edition without narration can't be retried at all.
        assertNull(narrationCopy(stopped(DownloadProblem.OFFLINE), summary, offline = true)!!.action)
        assertNull(narrationCopy(stopped(DownloadProblem.UNSUPPORTED), null, offline = false)!!.action)

        // Still waiting is "preparing", never stopped; a kept generation is said to still play.
        assertEquals("Preparing narration…", narrationCopy(ready, summary, offline = false)!!.text)
        val kept = NarrationDownload(generation, "media_overlay", "ra-x.json", listOf(DownloadedFile("n0", "ra-x-0000.wav", 10, complete = true, bytesDone = 10)), NarrationState.READY)
        assertTrue(narrationCopy(stopped(DownloadProblem.SIGN_IN).copy(narration = kept), summary, offline = false)!!.text.endsWith("The earlier narration on this device still plays offline."))
    }

    @Test
    fun `a previously unavailable narration offers retry when the server advertises it again`() {
        val record = stopped(DownloadProblem.UNSUPPORTED)
        assertEquals(NarrationAction.RETRY, narrationCopy(record, summary, offline = false)!!.action)
        assertNull(narrationCopy(record, summary, offline = true)!!.action)
        assertNull(narrationCopy(record, null, offline = false)!!.action)
    }

    @Test
    fun `the downloads list shows the book as downloaded with narration stopped, and can resume it`() {
        val copy = downloadCopy(stopped(DownloadProblem.INTERRUPTED))
        assertEquals("Downloaded · narration stopped", copy.title)
        assertTrue(copy.canRetry)
        assertTrue(copy.detail.contains("The book opens without a connection."))
        // A request that isn't stopped, or none at all, reads exactly as before.
        assertEquals("Downloaded · fetching narration", downloadCopy(ready).title)
        assertEquals("Downloaded", downloadCopy(ready.copy(withNarration = false, narrationPending = false)).title)
    }

    @Test
    fun `the book's page offers one narration retry and nothing that looks downloaded`() {
        compose.setContent {
            ShelfarrTheme(AppearanceMode.LIGHT) {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.padding(20.dp)) { DownloadPanel(book, stopped(DownloadProblem.SIGN_IN), false, {}, {}, {}, {}) }
                }
            }
        }
        compose.onAllNodesWithText("Try narration again").assertCountEquals(1)
        compose.onAllNodesWithText("Resume narration").assertCountEquals(0)
        compose.onAllNodesWithText("Narration is on this device", substring = true).assertCountEquals(0)
        // The reason is said once on this page.
        compose.onAllNodesWithText("Sign in to this account again", substring = true).assertCountEquals(1)
        compose.onRoot().captureRoboImage("build/screenshots/read-along/18-download-narration-stopped-signed-out.png")
    }
}
