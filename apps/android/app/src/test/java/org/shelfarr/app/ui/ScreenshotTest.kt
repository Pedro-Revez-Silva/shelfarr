package org.shelfarr.app.ui

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.Asset
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.DeviceGrant
import org.shelfarr.app.core.DownloadProblem
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState
import org.shelfarr.app.core.DownloadedFile
import org.shelfarr.app.core.LibrarySort
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.core.LibraryFilter
import org.shelfarr.app.core.Me
import org.shelfarr.app.core.Progress
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SyncStatus
import org.shelfarr.app.playback.AudioChapter
import org.shelfarr.app.playback.PlaybackSnapshot
import org.shelfarr.app.reader.ReaderBars
import org.shelfarr.app.reader.ReaderSettings
import org.shelfarr.app.reader.ReaderTheme
import org.shelfarr.app.reader.ReadingPlace
import org.shelfarr.app.reader.SettingsSheet
import org.shelfarr.app.ui.details.DetailsScreen
import org.shelfarr.app.ui.details.DetailsState
import org.shelfarr.app.ui.downloads.DownloadsScreen
import org.shelfarr.app.ui.home.HomeScreen
import org.shelfarr.app.ui.home.HomeState
import org.shelfarr.app.ui.home.LibraryScreen
import org.shelfarr.app.ui.home.LibraryState
import org.shelfarr.app.ui.player.MiniPlayer
import org.shelfarr.app.ui.player.PlayerControls
import org.shelfarr.app.ui.player.PlayerRoute
import org.shelfarr.app.ui.player.PlayerState
import org.shelfarr.app.ui.settings.SettingsScreen
import org.shelfarr.app.ui.setup.AuthorizeScreen
import org.shelfarr.app.ui.setup.ServerSetupScreen
import org.shelfarr.app.ui.setup.SetupPhase
import org.shelfarr.app.ui.setup.SetupState
import org.shelfarr.app.ui.theme.AppearanceMode
import org.shelfarr.app.ui.theme.ShelfarrTheme

/**
 * Renders every main screen on the JVM. Content here is test fixture data for
 * reviewing layout; the shipped app has no demo content.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], application = Application::class, qualifiers = "w393dp-h852dp-xxhdpi")
class ScreenshotTest {
    @get:Rule val compose = createComposeRule()

    private val server = (ServerAddress.parse("https://books.example.org") as ServerAddress.ParseResult.Valid).address
    private val session = Session(server, Me("1", "Ada Reader", "ada"), "fixture")

    private fun locator(total: Double) = buildJsonObject {
        put("href", "c.xhtml")
        putJsonObject("locations") { put("totalProgression", total) }
    }

    private fun epub(id: String) = Asset(id, "$id.epub", "application/epub+zip", "epub", 1_840_000, "/c/$id")

    private val book = Publication(
        id = "p1",
        title = "The Left Hand of Darkness",
        author = "Ursula K. Le Guin",
        description = "A lone human ambassador is sent to Winter, an alien world without gender, " +
            "where he must bridge the gulf between his own views and those of the strange society he encounters.",
        bookType = BookType.EBOOK,
        assets = listOf(epub("a1")),
        progress = Progress("a1", locator(0.42), version = 3, updatedAt = "2026-11-07T10:00:00Z"),
    )
    private val tracks = (1..12).map { Asset("t$it", "Part %02d.mp3".format(it), "audio/mpeg", "mp3", 42_000_000, "/c/t$it", it) }
    private val audiobook = Publication(
        id = "p2",
        title = "Piranesi",
        author = "Susanna Clarke",
        description = "Piranesi's house is no ordinary building.",
        bookType = BookType.AUDIOBOOK,
        assets = tracks,
        progress = Progress("t3", positionSeconds = 740.0, version = 9, updatedAt = "2026-11-06T22:00:00Z"),
    )
    private val shelf = listOf(
        book,
        audiobook,
        Publication("p3", "Middlemarch", "George Eliot", bookType = BookType.EBOOK, assets = listOf(epub("a3"))),
        Publication("p4", "The Dispossessed", "Ursula K. Le Guin", bookType = BookType.EBOOK, assets = listOf(epub("a4"))),
        Publication("p5", "Project Hail Mary", "Andy Weir", bookType = BookType.AUDIOBOOK, assets = tracks),
        Publication("p6", "A Very Long Title That Runs Over Several Lines of the Jacket", "Someone With A Long Name", bookType = BookType.EBOOK, assets = listOf(epub("a6"))),
        Publication("p7", "Dune", "Frank Herbert", bookType = BookType.EBOOK, assets = listOf(epub("a7"))),
        Publication("p8", "Circe", "Madeline Miller", bookType = BookType.AUDIOBOOK, assets = tracks),
        Publication("p9", "Beloved", "Toni Morrison", bookType = BookType.EBOOK, assets = listOf(epub("a9"))),
    )
    private val home = HomeState.Loaded(
        inProgress = shelf.filter { it.progress != null },
        books = shelf.filter { it.bookType == BookType.EBOOK },
        audiobooks = shelf.filter { it.bookType == BookType.AUDIOBOOK },
    )
    private val playing = PlaybackSnapshot(
        publication = audiobook,
        tracks = tracks,
        trackIndex = 2,
        isPlaying = true,
        positionMs = 740_000,
        durationMs = 2_260_000,
        speed = 1.2f,
    )

    private object NoControls : PlayerControls {
        override fun togglePlay() = Unit
        override fun seekTo(positionMs: Long) = Unit
        override fun skipBack() = Unit
        override fun skipForward() = Unit
        override fun playTrack(index: Int) = Unit
        override fun playChapter(chapter: AudioChapter) = Unit
        override fun setSpeed(speed: Float) = Unit
        override fun setSleepTimer(minutes: Int?) = Unit
    }

    private fun shot(name: String, dark: Boolean = false, content: @Composable () -> Unit) {
        compose.setContent {
            ShelfarrTheme(if (dark) AppearanceMode.DARK else AppearanceMode.LIGHT) {
                Surface(Modifier.fillMaxSize()) { content() }
            }
        }
        compose.onRoot().captureRoboImage("build/screenshots/$name.png")
    }

    @Test
    fun server_setup() = shot("01-setup") {
        ServerSetupScreen(SetupState(address = "books.example.org"), false, {}, {}, {})
    }

    @Test
    fun server_setup_error_dark() = shot("01-setup-error-dark", dark = true) {
        ServerSetupScreen(
            SetupState(address = "books.example.org", errorMessage = "Couldn't reach books.example.org. Check the address and your connection."),
            true,
            {},
            {},
            {},
        )
    }

    @Test
    fun authorize() = shot("02-authorize") {
        AuthorizeScreen(
            SetupPhase.Authorizing(server, "WDJB-MJHT", "https://books.example.org/device", "https://books.example.org/device?code=x", 512),
            {},
            {},
        )
    }

    @Test
    fun home_light() = shot("03-home") { HomeScreen(home, "books.example.org", {}, {}, {}) }

    @Test
    fun home_dark() = shot("03-home-dark", dark = true) { HomeScreen(home, "books.example.org", {}, {}, {}) }

    @Test
    fun home_empty() = shot("03-home-empty") {
        HomeScreen(HomeState.Loaded(emptyList(), emptyList(), emptyList()), "books.example.org", {}, {}, {})
    }

    @Test
    fun home_offline_dark() = shot("03-home-offline-dark", dark = true) {
        HomeScreen(HomeState.Failed(ApiException.Offline()), "books.example.org", {}, {}, {})
    }

    @Test
    fun library() = shot("04-library") {
        LibraryScreen(LibraryState(items = shelf, loading = false, filter = LibraryFilter.ALL), "books.example.org", {}, {}, {}, {}, {})
    }

    @Test
    fun library_dark() = shot("04-library-dark", dark = true) {
        LibraryScreen(LibraryState(items = shelf, loading = false, filter = LibraryFilter.EBOOK), "books.example.org", {}, {}, {}, {}, {})
    }

    @Test
    fun details_book() = shot("05-details-book") {
        DetailsScreen(DetailsState.Loaded(book), "books.example.org", {}, {}, {})
    }

    @Test
    fun details_audio_dark() = shot("05-details-audio-dark", dark = true) {
        DetailsScreen(DetailsState.Loaded(audiobook), "books.example.org", {}, {}, {})
    }

    @Test
    fun player() = shot("06-player") {
        PlayerRoute(PlayerState.Active(), playing, SyncStatus.Saved, "books.example.org", NoControls, {}, {}, {}, {}, {})
    }

    @Test
    fun player_dark() = shot("06-player-dark", dark = true) {
        PlayerRoute(PlayerState.Active(), playing.copy(isPlaying = false), SyncStatus.Saved, "books.example.org", NoControls, {}, {}, {}, {}, {})
    }

    @Test
    fun mini_player() = shot("06-mini-player") {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) { MiniPlayer(playing, {}, {}) }
    }

    @Test
    fun reader_chrome() = readerShot("07-reader-chrome", ReaderTheme.PAPER)

    @Test
    fun reader_chrome_night() = readerShot("07-reader-chrome-night", ReaderTheme.NIGHT)

    private fun readerShot(name: String, theme: ReaderTheme) = shot(name) {
        val settings = ReaderSettings(theme = theme)
        Box(Modifier.fillMaxSize().background(theme.pageColor)) {
            ReaderBars(
                title = book.title,
                positionCount = 842,
                settings = settings,
                place = ReadingPlace(0.42f, 354, "Chapter 7: The Place Inside the Blizzard"),
                onClose = {},
                onContents = {},
                onAppearance = {},
                onScrub = {},
            )
        }
    }

    @Test
    fun reader_settings() = shot("07-reader-settings") {
        Column(Modifier.background(ReaderTheme.PAPER.barColor)) { SettingsSheet(ReaderSettings()) {} }
    }

    @Test
    @Config(qualifiers = "w320dp-h568dp-xhdpi")
    fun small_phone_player() = shot("09-small-phone-player") {
        PlayerRoute(PlayerState.Active(), playing, SyncStatus.Saved, "books.example.org", NoControls, {}, {}, {}, {}, {})
    }

    @Test
    fun large_text_home() {
        RuntimeEnvironment.setFontScale(1.6f)
        shot("09-large-text-home") { HomeScreen(home, "books.example.org", {}, {}, {}) }
    }

    @Test
    fun large_text_player() {
        RuntimeEnvironment.setFontScale(1.6f)
        shot("09-large-text-player") {
            PlayerRoute(PlayerState.Active(), playing, SyncStatus.Saved, "books.example.org", NoControls, {}, {}, {}, {}, {})
        }
    }

    @Test
    @Config(qualifiers = "w834dp-h1194dp-xhdpi")
    fun tablet_library() = shot("09-tablet-library") {
        LibraryScreen(LibraryState(items = shelf, loading = false), "books.example.org", {}, {}, {}, {}, {})
    }

    @Test
    fun settings() = shot("08-settings") {
        SettingsScreen(session, AppearanceMode.SYSTEM, "0.1.0", false, {}, {})
    }

    private fun files(publication: Publication, doneFraction: Double) = publication.playableAssets.mapIndexed { index, asset ->
        val share = (doneFraction * publication.playableAssets.size - index).coerceIn(0.0, 1.0)
        DownloadedFile(asset.id, "$index.bin", asset.sizeBytes, "\"e\"", complete = share >= 1.0, bytesDone = (asset.sizeBytes * share).toLong())
    }

    private val downloading = DownloadRecord("p2", audiobook, files(audiobook, 0.42), DownloadState.DOWNLOADING)
    private val downloaded = DownloadRecord("p1", book, files(book, 1.0), DownloadState.READY)
    private val offlinePaused = DownloadRecord("p5", shelf[4], files(shelf[4], 0.3), DownloadState.FAILED, DownloadProblem.OFFLINE)

    @Test
    fun details_downloading() = shot("10-details-downloading") {
        DetailsScreen(DetailsState.Loaded(audiobook), "books.example.org", {}, {}, {}, download = downloading)
    }

    @Test
    fun details_downloaded_finished_dark() = shot("10-details-downloaded-dark", dark = true) {
        DetailsScreen(
            DetailsState.Loaded(book.copy(readingStatus = ReadingStatus.FINISHED)),
            "books.example.org",
            {},
            {},
            {},
            download = downloaded,
        )
    }

    @Test
    fun details_offline() = shot("10-details-offline") {
        DetailsScreen(DetailsState.Loaded(book, offline = true), "books.example.org", {}, {}, {}, download = downloaded)
    }

    @Test
    fun downloads() = shot("11-downloads") {
        DownloadsScreen(listOf(downloading, downloaded, offlinePaused), {}, {}, {}, {}, {})
    }

    @Test
    fun home_offline_with_downloads() = shot("11-home-offline-downloads") {
        HomeScreen(
            HomeState.Loaded(emptyList(), emptyList(), emptyList(), downloads = listOf(book, audiobook), hasDownloadRecords = true, offline = ApiException.Offline()),
            "books.example.org",
            {},
            {},
            {},
        )
    }

    @Test
    fun library_finished_by_title() = shot("12-library-finished-title") {
        LibraryScreen(
            LibraryState(items = shelf.take(4), loading = false, status = ReadingStatus.FINISHED, sort = LibrarySort.TITLE),
            "books.example.org",
            {},
            {},
            {},
            {},
            {},
        )
    }

    @Test
    fun library_status_empty_dark() = shot("12-library-status-empty-dark", dark = true) {
        LibraryScreen(LibraryState(items = emptyList(), loading = false, status = ReadingStatus.IN_PROGRESS), "books.example.org", {}, {}, {}, {}, {})
    }
}
