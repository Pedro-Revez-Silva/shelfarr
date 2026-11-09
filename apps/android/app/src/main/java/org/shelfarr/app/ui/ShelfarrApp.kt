package org.shelfarr.app.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NamedNavArgument
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import org.shelfarr.app.AppContainer
import org.shelfarr.app.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.ConnectDecision
import org.shelfarr.app.core.ConnectLinks
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.playback.AudioChapter
import org.shelfarr.app.playback.PlaybackController
import org.shelfarr.app.reader.ReaderActivity
import org.shelfarr.app.ui.components.ShelfarrIcons
import org.shelfarr.app.ui.details.DetailsActions
import org.shelfarr.app.core.ReadingFormat
import org.shelfarr.app.ui.details.DetailsScreen
import org.shelfarr.app.ui.details.DetailsViewModel
import org.shelfarr.app.ui.downloads.DownloadsScreen
import org.shelfarr.app.ui.find.FindViewModel
import org.shelfarr.app.ui.home.HomeScreen
import org.shelfarr.app.ui.home.HomeViewModel
import org.shelfarr.app.ui.home.LibraryScreen
import org.shelfarr.app.ui.home.LibraryViewModel
import org.shelfarr.app.ui.player.MiniPlayer
import org.shelfarr.app.ui.player.PlayerControls
import org.shelfarr.app.ui.player.PlayerRoute
import org.shelfarr.app.ui.player.PlayerViewModel
import org.shelfarr.app.ui.settings.SettingsScreen
import org.shelfarr.app.ui.settings.UpdateActions
import org.shelfarr.app.update.AppUpdater
import org.shelfarr.app.update.InstallRequest
import org.shelfarr.app.update.hasUpdate
import org.shelfarr.app.ui.setup.AuthorizationEndedScreen
import org.shelfarr.app.ui.setup.AuthorizeScreen
import org.shelfarr.app.ui.setup.ServerSetupScreen
import org.shelfarr.app.ui.setup.SetupPhase
import org.shelfarr.app.ui.setup.SetupViewModel
import org.shelfarr.app.ui.theme.ShelfarrTheme

internal const val HOME = "home"
internal const val LIBRARY = "library"
internal const val SETTINGS = "settings"
internal const val DETAILS = "details/{id}"
internal const val PLAYER = "player/{id}"
internal const val DOWNLOADS = "downloads"
internal const val FIND = "find"
internal const val FIND_TITLE = "find/title"
internal const val REQUEST = "request/{id}"

@Composable
fun ShelfarrApp(
    container: AppContainer,
    requestedScreen: MutableStateFlow<AppScreen?> = remember { MutableStateFlow(null) },
    connectRequest: MutableStateFlow<ServerAddress?> = remember { MutableStateFlow(null) },
) {
    val sessionState by container.sessions.session.collectAsStateWithLifecycle()
    // Survives rotation; a link's explanation stays until the person dismisses it.
    var noticeTitle by rememberSaveable { mutableStateOf<String?>(null) }
    var noticeMessage by rememberSaveable { mutableStateOf<String?>(null) }
    val explain: (ConnectDecision.Explain) -> Unit = { decision ->
        noticeTitle = decision.title
        noticeMessage = decision.message
    }
    Surface(Modifier.fillMaxSize()) {
        when (val state = sessionState) {
            is SessionState.SignedIn -> CompositionLocalProvider(LocalServer provides state.session.server) {
                // Signed in, a link never connects anything: at most it explains.
                ConnectLinkEffect(connectRequest, decide = { ConnectLinks.decide(it, state) }, onConnect = {}, onExplain = explain)
                MainShell(container, state.session, requestedScreen)
            }
            else -> {
                // A notification can't open another account's downloads through the sign-in screen.
                LaunchedEffect(Unit) { requestedScreen.value = null }
                SetupFlow(container, connectRequest, explain)
            }
        }
    }
    val title = noticeTitle
    val message = noticeMessage
    if (title != null && message != null) {
        ConnectLinkNotice(title, message) {
            noticeTitle = null
            noticeMessage = null
        }
    }
}

/**
 * Acts once on a `shelfarr://connect` link the activity received, cold or warm. The
 * request is consumed as soon as it is decided, so recreation can't repeat it.
 */
@Composable
internal fun ConnectLinkEffect(
    connectRequest: MutableStateFlow<ServerAddress?>,
    decide: (ServerAddress) -> ConnectDecision,
    onConnect: (ServerAddress) -> Unit,
    onExplain: (ConnectDecision.Explain) -> Unit,
) {
    val requested by connectRequest.collectAsStateWithLifecycle()
    LaunchedEffect(requested) {
        val server = requested ?: return@LaunchedEffect
        connectRequest.value = null
        when (val decision = decide(server)) {
            is ConnectDecision.Connect -> onConnect(decision.server)
            ConnectDecision.AlreadyThere -> Unit
            is ConnectDecision.Explain -> onExplain(decision)
        }
    }
}

@Composable
internal fun ConnectLinkNotice(title: String, message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
    )
}

/**
 * Asks once, on the first download, whether progress may be shown as a notification.
 * The download starts either way; declining only hides the notification.
 */
@Composable
private fun rememberDownloadStarter(container: AppContainer, start: () -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { start() }
    return remember(container, launcher) {
        {
            val needsAsking = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !container.transferNotifications.canPost && !container.askedForNotifications
            if (needsAsking) {
                container.askedForNotifications = true
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                start()
            }
        }
    }
}

/** Android's per-app "Install unknown apps" switch, which a self-update needs once. */
private fun Context.installPermissionIntent(): Intent =
    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))

@Composable
private fun rememberUpdateActions(updater: AppUpdater, setAutoDownload: (Boolean) -> Unit): UpdateActions {
    val context = LocalContext.current
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        updater.onPermissionReturned()
    }
    return remember(updater, permission) {
        object : UpdateActions {
            override fun check() = updater.checkNow()
            override fun download() = updater.download()
            override fun cancelDownload() = updater.cancelDownload()
            override fun install(pausePlayback: Boolean): InstallRequest = updater.install(pausePlayback)
            override fun openInstallPermission() {
                try {
                    permission.launch(context.installPermissionIntent())
                } catch (_: ActivityNotFoundException) {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
                }
            }
            override fun dismissPermission() = updater.dismissPermission()
            override fun showPrompt() = updater.showPromptAgain()
            override fun cancelInstall() = updater.cancelInstall()
            override fun setAutoDownload(enabled: Boolean) = setAutoDownload(enabled)
        }
    }
}

private fun Context.openNotificationSettings() {
    val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
    try {
        startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
    }
}

@Composable
private fun SetupFlow(
    container: AppContainer,
    connectRequest: MutableStateFlow<ServerAddress?>,
    onExplain: (ConnectDecision.Explain) -> Unit,
) {
    val viewModel: SetupViewModel = viewModel { SetupViewModel(container) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current

    ConnectLinkEffect(
        connectRequest,
        decide = { server ->
            val setup = viewModel.state.value
            ConnectLinks.decide(server, container.sessions.session.value, setup.signInActivity, setup.signingInTo)
        },
        onConnect = viewModel::connectFromLink,
        onExplain = onExplain,
    )

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
    Tab(FIND, "Find", ShelfarrIcons.Search),
    Tab(SETTINGS, "Settings", ShelfarrIcons.Settings),
)

@Composable
internal fun RequestedScreenNavigation(navController: NavHostController, requestedScreen: MutableStateFlow<AppScreen?>) {
    val requested by requestedScreen.collectAsStateWithLifecycle()
    LaunchedEffect(navController, requested) {
        if (requested == AppScreen.DOWNLOADS) {
            // A cold notification can arrive before NavHost has installed its
            // graph; wait for the first installed entry.
            navController.currentBackStackEntryFlow.first()
            navController.navigate(DOWNLOADS) { launchSingleTop = true }
            requestedScreen.value = null
        }
    }
}

@Composable
private fun MainShell(container: AppContainer, session: Session, requestedScreen: MutableStateFlow<AppScreen?>) {
    val navController = rememberNavController()
    RequestedScreenNavigation(navController, requestedScreen)
    val playback by container.playback.snapshot.collectAsStateWithLifecycle()
    val update by container.updater.state.collectAsStateWithLifecycle()
    val context = LocalContext.current

    fun open(publication: Publication) = navController.navigate("details/${Uri.encode(publication.id)}")

    fun start(publication: Publication, explicit: Boolean = true) {
        // An explicit Read or Listen may mark an unread book in progress; it never blocks opening.
        if (explicit) container.currentAccount()?.markStarted(publication)
        if (publication.bookType == BookType.EBOOK) {
            context.startActivity(ReaderActivity.intent(context, publication.id))
        } else {
            navController.navigate("player/${Uri.encode(publication.id)}")
        }
    }

    val miniPlayer: (@Composable () -> Unit)? = if (playback.isLoaded) {
        {
            MiniPlayer(
                snapshot = playback,
                onOpen = { playback.publication?.let { start(it, explicit = false) } },
                onToggle = container.playback::togglePlay,
            )
        }
    } else {
        null
    }

    // One Find model for the tab, the title page and the request page, scoped to the shell.
    val find: FindViewModel = viewModel { FindViewModel(container) }
    FindNavigation(find, navController, openBrowser = { context.openInBrowser(it) })

    MainShellLayout(navController, miniPlayer, badges = if (update.hasUpdate) setOf(SETTINGS) else emptySet()) {
        screen(HOME) {
            val viewModel: HomeViewModel = viewModel { HomeViewModel(container) }
            val state by viewModel.state.collectAsStateWithLifecycle()
            LifecycleResumeEffect(viewModel) {
                viewModel.refresh()
                onPauseOrDispose {}
            }
            HomeScreen(state, session.server.host, ::open, { start(it) }, viewModel::retry, onDownloads = { navController.navigate(DOWNLOADS) })
        }
        screen(LIBRARY) {
            val viewModel: LibraryViewModel = viewModel { LibraryViewModel(container) }
            val state by viewModel.state.collectAsStateWithLifecycle()
            LifecycleResumeEffect(viewModel) {
                viewModel.reload()
                onPauseOrDispose {}
            }
            LibraryScreen(
                state = state,
                host = session.server.host,
                onFilter = viewModel::setFilter,
                onQuery = viewModel::setQuery,
                onOpen = ::open,
                onLoadMore = viewModel::loadMore,
                onRetry = viewModel::reload,
                onStatus = viewModel::setStatus,
                onSort = viewModel::setSort,
            )
        }
        findScreens(
            find = find,
            navController = navController,
            host = session.server.host,
            accountName = session.user.displayName,
            openWebsite = { context.openInBrowser(session.server.display) },
            openPublication = { start(it) },
        )
        screen(SETTINGS) {
            val appearance by container.appearance.collectAsState()
            var disconnecting by remember { mutableStateOf(false) }
            val records by (container.currentAccount()?.downloads?.records ?: remember { MutableStateFlow(emptyMap()) })
                .collectAsStateWithLifecycle()
            val updateActions = rememberUpdateActions(container.updater, container::setAutoDownloadUpdates)
            val autoDownloadUpdates by container.autoDownloadUpdates.collectAsStateWithLifecycle()
            LifecycleResumeEffect(container.updater) {
                // Android may have dropped an installation without saying so.
                container.updater.reconcileInstalling()
                onPauseOrDispose {}
            }
            SettingsScreen(
                session = session,
                appearance = appearance,
                version = BuildConfig.VERSION_NAME,
                disconnecting = disconnecting,
                onAppearance = container::setAppearance,
                onDisconnect = {
                    disconnecting = true
                    container.disconnect()
                },
                downloadsSummary = downloadsSummary(records.values),
                onDownloads = { navController.navigate(DOWNLOADS) },
                update = update,
                updateActions = updateActions,
                autoDownloadUpdates = autoDownloadUpdates,
            )
        }
        screen(DETAILS, listOf(navArgument("id") { type = NavType.StringType })) { entry ->
            val id = requireNotNull(entry.arguments?.getString("id"))
            val viewModel: DetailsViewModel = viewModel { DetailsViewModel(container, id) }
            val state by viewModel.state.collectAsStateWithLifecycle()
            LifecycleResumeEffect(viewModel) {
                viewModel.load()
                onPauseOrDispose {}
            }
            val download by viewModel.download.collectAsStateWithLifecycle()
            val statusEdit by viewModel.statusEdit.collectAsStateWithLifecycle()
            val startDownload = rememberDownloadStarter(container) { viewModel.download() }
            val actions = remember(viewModel, startDownload) {
                object : DetailsActions by viewModel {
                    override fun download() {
                        viewModel.prepareDownload(null)
                        startDownload()
                    }

                    override fun downloadFormat(format: ReadingFormat) {
                        viewModel.prepareDownload(format)
                        startDownload()
                    }

                    override fun downloadNarration(include: Boolean) {
                        viewModel.prepareDownload(null, include)
                        startDownload()
                    }
                }
            }
            DetailsScreen(
                state = state,
                host = session.server.host,
                onBack = navController::popBackStack,
                onPrimary = { start(it) },
                onRetry = viewModel::retry,
                download = download,
                statusEdit = statusEdit,
                actions = actions,
            )
        }
        screen(DOWNLOADS) {
            val downloads = container.currentAccount()?.downloads
            val records by (downloads?.records ?: remember { MutableStateFlow(emptyMap()) }).collectAsStateWithLifecycle()
            var notificationsOff by remember { mutableStateOf(!container.transferNotifications.canPost) }
            LifecycleResumeEffect(Unit) {
                notificationsOff = !container.transferNotifications.canPost
                onPauseOrDispose {}
            }
            DownloadsScreen(
                records = records.values.sortedByDescending { it.updatedAtEpochMs },
                onBack = navController::popBackStack,
                onOpen = ::open,
                onCancel = { id -> container.scope.launch { downloads?.cancel(id) } },
                onRemove = { id -> container.scope.launch { downloads?.remove(id) } },
                onRetry = { id -> container.scope.launch { downloads?.retry(id) } },
                notificationsOff = notificationsOff,
                onTurnOnNotifications = { context.openNotificationSettings() },
            )
        }
        screen(PLAYER, listOf(navArgument("id") { type = NavType.StringType })) { entry ->
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

private val TAB_ROUTES = TABS.map { it.route }.toSet()

// Material fade-through: the outgoing screen fades out before the incoming one fades
// in, so two translucent screens are never drawn over each other.
private val FadeThroughIn = fadeIn(tween(durationMillis = 210, delayMillis = 90, easing = LinearOutSlowInEasing))
private val FadeThroughOut = fadeOut(tween(durationMillis = 90, easing = FastOutLinearInEasing))

/**
 * Bottom space each destination keeps clear of the shell's bars. It depends on the
 * destination rather than the current route, so a screen still animating out keeps
 * its layout while the bars change for the screen coming in.
 */
@Immutable
private data class ShellBars(val systemBottom: Dp = 0.dp, val miniPlayer: Dp = 0.dp, val tabBar: Dp = 0.dp) {
    fun bottomPadding(route: String): Dp {
        val bars = (if (route != PLAYER) miniPlayer else 0.dp) + (if (route in TAB_ROUTES) tabBar else 0.dp)
        // As in Scaffold: with no bar below it, a screen keeps clear of the system bar.
        return if (bars > 0.dp) bars else systemBottom
    }
}

private val LocalShellBars = compositionLocalOf { ShellBars() }

/**
 * The signed-in shell: tab bar, mini player and the destination graph. Kept apart
 * from [MainShell] so tests can drive real navigation without account fixtures.
 */
@Composable
internal fun MainShellLayout(
    navController: NavHostController,
    miniPlayer: (@Composable () -> Unit)?,
    badges: Set<String> = emptySet(),
    builder: NavGraphBuilder.() -> Unit,
) {
    val backStack by navController.currentBackStackEntryAsState()
    val route = backStack?.destination?.route
    val density = LocalDensity.current
    var miniPlayerHeight by remember { mutableStateOf(0.dp) }
    var tabBarHeight by remember { mutableStateOf(0.dp) }
    val bars = ShellBars(
        systemBottom = WindowInsets.systemBars.asPaddingValues().calculateBottomPadding(),
        miniPlayer = if (miniPlayer != null) miniPlayerHeight else 0.dp,
        tabBar = tabBarHeight,
    )

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize()) {
            CompositionLocalProvider(LocalShellBars provides bars) {
                NavHost(
                    navController = navController,
                    startDestination = HOME,
                    enterTransition = { FadeThroughIn },
                    exitTransition = { FadeThroughOut },
                    builder = builder,
                )
            }
            Column(Modifier.align(Alignment.BottomCenter)) {
                if (miniPlayer != null && route != PLAYER) {
                    Box(Modifier.onSizeChanged { miniPlayerHeight = with(density) { it.height.toDp() } }) { miniPlayer() }
                }
                AnimatedVisibility(route in TAB_ROUTES, enter = FadeThroughIn, exit = FadeThroughOut) {
                    TabBar(
                        navController = navController,
                        route = route,
                        badges = badges,
                        modifier = Modifier.onSizeChanged { tabBarHeight = with(density) { it.height.toDp() } },
                    )
                }
            }
        }
    }
}

/** A shell destination, laid out above the bars that belong to it. */
internal fun NavGraphBuilder.screen(
    route: String,
    arguments: List<NamedNavArgument> = emptyList(),
    content: @Composable (NavBackStackEntry) -> Unit,
) = composable(route, arguments) { entry ->
    Box(Modifier.fillMaxSize().padding(bottom = LocalShellBars.current.bottomPadding(route))) { content(entry) }
}

private fun downloadsSummary(records: Collection<DownloadRecord>): String {
    if (records.isEmpty()) return "Nothing downloaded"
    val ready = records.filter { it.isReady }
    val active = records.count { it.isActive }
    val parts = buildList {
        if (ready.isNotEmpty()) add("${ready.size} on this device · ${formatBytes(ready.sumOf { it.bytesDone })}")
        if (active > 0) add("$active downloading")
        if (ready.isEmpty() && active == 0) add("${records.size} stopped")
    }
    return parts.joinToString(" · ")
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
private fun TabBar(navController: NavHostController, route: String?, badges: Set<String>, modifier: Modifier = Modifier) {
    Column(modifier) {
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
                    icon = {
                        if (tab.route in badges) {
                            BadgedBox(badge = { Badge() }) { Icon(tab.icon, null) }
                        } else {
                            Icon(tab.icon, null)
                        }
                    },
                    modifier = if (tab.route in badges) Modifier.semantics { stateDescription = "Update available" } else Modifier,
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
