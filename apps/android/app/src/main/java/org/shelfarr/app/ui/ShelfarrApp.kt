package org.shelfarr.app.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.BuildConfig
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.playback.AudioChapter
import org.shelfarr.app.playback.PlaybackController
import org.shelfarr.app.reader.ReaderActivity
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.details.DetailsScreen
import org.shelfarr.app.ui.details.DetailsViewModel
import org.shelfarr.app.ui.home.HomeScreen
import org.shelfarr.app.ui.home.HomeViewModel
import org.shelfarr.app.ui.home.LibraryScreen
import org.shelfarr.app.ui.home.LibraryViewModel
import org.shelfarr.app.ui.player.MiniPlayer
import org.shelfarr.app.ui.player.PlayerControls
import org.shelfarr.app.ui.player.PlayerRoute
import org.shelfarr.app.ui.player.PlayerViewModel
import org.shelfarr.app.ui.settings.SettingsScreen
import org.shelfarr.app.ui.setup.AuthorizationEndedScreen
import org.shelfarr.app.ui.setup.AuthorizeScreen
import org.shelfarr.app.ui.setup.ServerSetupScreen
import org.shelfarr.app.ui.setup.SetupPhase
import org.shelfarr.app.ui.setup.SetupViewModel
import org.shelfarr.app.ui.theme.ShelfarrTheme

private const val HOME = "home"
private const val LIBRARY = "library"
private const val SETTINGS = "settings"
private const val DETAILS = "details/{id}"
private const val PLAYER = "player/{id}"

@Composable
fun ShelfarrApp(container: AppContainer) {
    val sessionState by container.sessions.session.collectAsStateWithLifecycle()
    Surface(Modifier.fillMaxSize()) {
        when (val state = sessionState) {
            is SessionState.SignedIn -> CompositionLocalProvider(LocalServer provides state.session.server) {
                MainShell(container, state.session)
            }
            else -> SetupFlow(container)
        }
    }
}

@Composable
private fun SetupFlow(container: AppContainer) {
    val viewModel: SetupViewModel = viewModel { SetupViewModel(container) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current

    LaunchedEffect(viewModel) {
        viewModel.openBrowser.collect { uri -> context.openInBrowser(uri) }
    }

    when (val phase = state.phase) {
        is SetupPhase.Authorizing -> AuthorizeScreen(
            phase = phase,
            onOpenBrowser = { context.openInBrowser(phase.browserUri) },
            onCancel = viewModel::cancel,
        )
        is SetupPhase.Ended -> AuthorizationEndedScreen(
            phase = phase,
            onRetry = viewModel::connect,
            onChangeServer = viewModel::startOver,
        )
        else -> ServerSetupScreen(
            state = state,
            canUseLocalHttp = viewModel.canUseLocalHttp,
            onAddressChange = viewModel::onAddressChange,
            onAllowLocalHttpChange = viewModel::onAllowLocalHttpChange,
            onConnect = viewModel::connect,
        )
    }
}

private fun Context.openInBrowser(uri: String) {
    try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addCategory(Intent.CATEGORY_BROWSABLE))
    } catch (_: ActivityNotFoundException) {
        // The screen already shows the address and code for use on another device.
    }
}

private data class Tab(val route: String, val label: String, val icon: ImageVector)

private val TABS = listOf(
    Tab(HOME, "Home", ShelfarrIcons.Home),
    Tab(LIBRARY, "Library", ShelfarrIcons.Library),
    Tab(SETTINGS, "Settings", ShelfarrIcons.Settings),
)

@Composable
private fun MainShell(container: AppContainer, session: Session) {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()
    val route = backStack?.destination?.route
    val playback by container.playback.snapshot.collectAsStateWithLifecycle()
    val context = LocalContext.current

    fun open(publication: Publication) = navController.navigate("details/${Uri.encode(publication.id)}")

    fun start(publication: Publication) {
        if (publication.bookType == BookType.EBOOK) {
            context.startActivity(ReaderActivity.intent(context, publication.id))
        } else {
            navController.navigate("player/${Uri.encode(publication.id)}")
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            Column {
                if (playback.isLoaded && route != PLAYER) {
                    MiniPlayer(
                        snapshot = playback,
                        onOpen = { playback.publication?.let(::start) },
                        onToggle = container.playback::togglePlay,
                    )
                }
                if (route in TABS.map { it.route }) TabBar(navController, route)
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = HOME,
            modifier = Modifier.padding(bottom = padding.calculateBottomPadding()),
        ) {
            composable(HOME) {
                val viewModel: HomeViewModel = viewModel { HomeViewModel(container) }
                val state by viewModel.state.collectAsStateWithLifecycle()
                LifecycleResumeEffect(viewModel) {
                    viewModel.refresh()
                    onPauseOrDispose {}
                }
                HomeScreen(state, session.server.host, ::open, ::start, viewModel::retry)
            }
            composable(LIBRARY) {
                val viewModel: LibraryViewModel = viewModel { LibraryViewModel(container) }
                val state by viewModel.state.collectAsStateWithLifecycle()
                LibraryScreen(
                    state = state,
                    host = session.server.host,
                    onFilter = viewModel::setFilter,
                    onQuery = viewModel::setQuery,
                    onOpen = ::open,
                    onLoadMore = viewModel::loadMore,
                    onRetry = viewModel::reload,
                )
            }
            composable(SETTINGS) {
                val appearance by container.appearance.collectAsState()
                val scope = rememberCoroutineScope()
                var disconnecting by remember { mutableStateOf(false) }
                SettingsScreen(
                    session = session,
                    appearance = appearance,
                    version = BuildConfig.VERSION_NAME,
                    disconnecting = disconnecting,
                    onAppearance = container::setAppearance,
                    onDisconnect = {
                        disconnecting = true
                        scope.launch { container.disconnect() }
                    },
                )
            }
            composable(DETAILS, listOf(navArgument("id") { type = NavType.StringType })) { entry ->
                val id = requireNotNull(entry.arguments?.getString("id"))
                val viewModel: DetailsViewModel = viewModel { DetailsViewModel(container, id) }
                val state by viewModel.state.collectAsStateWithLifecycle()
                LifecycleResumeEffect(viewModel) {
                    viewModel.load()
                    onPauseOrDispose {}
                }
                DetailsScreen(state, session.server.host, navController::popBackStack, ::start, viewModel::retry)
            }
            composable(PLAYER, listOf(navArgument("id") { type = NavType.StringType })) { entry ->
                val id = requireNotNull(entry.arguments?.getString("id"))
                val viewModel: PlayerViewModel = viewModel { PlayerViewModel(container, id) }
                val state by viewModel.state.collectAsStateWithLifecycle()
                val snapshot by viewModel.playback.collectAsStateWithLifecycle()
                val sync by viewModel.syncStatus.collectAsStateWithLifecycle()
                PlayerRoute(
                    state = state,
                    snapshot = snapshot,
                    syncStatus = sync,
                    host = session.server.host,
                    controls = remember { ControllerControls(container.playback) },
                    onBack = navController::popBackStack,
                    onRetry = viewModel::start,
                    onChooseResume = viewModel::chooseResume,
                    onKeepThisPlace = viewModel::keepThisPlace,
                    onUseOtherPlace = viewModel::useOtherPlace,
                )
            }
        }
    }
}

private class ControllerControls(private val playback: PlaybackController) : PlayerControls {
    override fun togglePlay() = playback.togglePlay()
    override fun seekTo(positionMs: Long) = playback.seekTo(positionMs)
    override fun skipBack() = playback.skipBack()
    override fun skipForward() = playback.skipForward()
    override fun playTrack(index: Int) = playback.playTrack(index)
    override fun playChapter(chapter: AudioChapter) = playback.playChapter(chapter)
    override fun setSpeed(speed: Float) = playback.setSpeed(speed)
    override fun setSleepTimer(minutes: Int?) = playback.setSleepTimer(minutes)
}

@Composable
private fun TabBar(navController: NavHostController, route: String?) {
    Column {
        HorizontalDivider(color = ShelfarrTheme.extended.hairline)
        NavigationBar(containerColor = MaterialTheme.colorScheme.background, tonalElevation = androidx.compose.ui.unit.Dp(0f)) {
            TABS.forEach { tab ->
                NavigationBarItem(
                    selected = route == tab.route,
                    onClick = {
                        navController.navigate(tab.route) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(tab.icon, null) },
                    label = { Text(tab.label, style = MaterialTheme.typography.labelSmall) },
                    colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = MaterialTheme.colorScheme.primary,
                        selectedTextColor = MaterialTheme.colorScheme.primary,
                        indicatorColor = ShelfarrTheme.extended.accentSoft,
                        unselectedIconColor = ShelfarrTheme.extended.inkMuted,
                        unselectedTextColor = ShelfarrTheme.extended.inkMuted,
                    ),
                )
            }
        }
    }
}
