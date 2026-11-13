package org.shelfarr.app.reader.pages

import android.app.Application
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.reader.ReaderTheme

/**
 * Default qualifiers on purpose: under Robolectric at the phone-sized xxhdpi qualifiers the
 * other reader tests use, even a stock Material 3 dialog holding a text field never idles.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class)
class GoToPageDialogTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun `go to page accepts only pages the book has, then shows that page`() {
        val settled = CopyOnWriteArrayList<Int>()
        compose.setContent {
            PagedReader(
                title = "Fixture", format = ReadingFormat.PDF, pageCount = 6, initialPage = 0, theme = ReaderTheme.PAPER,
                chromeVisible = true, render = { index, width, height -> PageFixtures.draw(index, width, height) },
                onPageSettled = { settled += it }, onToggleChrome = {}, onClose = {},
            )
        }
        compose.onNodeWithText("Page 1 of 6").performClick()
        compose.onNodeWithText("Page (1–6)").assertExists()
        compose.onNodeWithText("Go").assertIsEnabled()
        compose.onNodeWithText("1").performTextReplacement("7")
        compose.onNodeWithText("Go").assertIsNotEnabled()
        compose.onNodeWithText("7").performTextReplacement("0")
        compose.onNodeWithText("Go").assertIsNotEnabled()
        compose.onNodeWithText("0").performTextReplacement("6")
        compose.onNodeWithText("Go").performClick()
        compose.waitForIdle()
        assertEquals(5, settled.last())
    }
}
