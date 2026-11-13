package org.shelfarr.app.ui

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.navArgument
import org.shelfarr.app.core.Publication
import org.shelfarr.app.ui.find.FindDestination
import org.shelfarr.app.ui.find.FindScreen
import org.shelfarr.app.ui.find.FindViewModel
import org.shelfarr.app.ui.find.RequestScreen
import org.shelfarr.app.ui.find.TitleScreen

/** Opens approval pages and follows Find's own navigation. Used by the app and its UI tests. */
@Composable
internal fun FindNavigation(find: FindViewModel, navController: NavHostController, openBrowser: (String) -> Unit) {
    LaunchedEffect(find) { find.openBrowser.collect(openBrowser) }
    LaunchedEffect(find, navController) {
        find.destinations.collect { destination ->
            when (destination) {
                FindDestination.Title -> navController.navigate(FIND_TITLE) { launchSingleTop = true }
                is FindDestination.Request -> navController.navigate("request/${Uri.encode(destination.id)}") {
                    // A new request replaces its title page, so Back returns to Find.
                    popUpTo(FIND_TITLE) { inclusive = true }
                    launchSingleTop = true
                }
            }
        }
    }
}

/** Find → title → request, as destinations of the signed-in shell. */
internal fun NavGraphBuilder.findScreens(
    find: FindViewModel,
    navController: NavHostController,
    host: String,
    accountName: String,
    openWebsite: () -> Unit,
    openPublication: (Publication) -> Unit,
    openDetails: (String) -> Unit = { id -> navController.navigate("details/${Uri.encode(id)}") },
) {
    screen(FIND) {
        val access by find.access.collectAsStateWithLifecycle()
        val state by find.find.collectAsStateWithLifecycle()
        LifecycleResumeEffect(find) {
            find.onShown()
            onPauseOrDispose {}
        }
        LaunchedEffect(find) { find.followRequests() }
        FindScreen(
            access = access,
            state = state,
            host = host,
            accountName = accountName,
            onQuery = find::setQuery,
            onSearch = find::search,
            onChoose = find::choose,
            onOpenRequest = find::openRequest,
            onAllow = find::allowRequesting,
            onReopenBrowser = find::reopenApproval,
            onCancelApproval = find::cancelApproval,
            onOpenWebsite = openWebsite,
            onRetryRequests = find::loadRequests,
        )
    }
    screen(FIND_TITLE) {
        val state by find.title.collectAsStateWithLifecycle()
        TitleScreen(
            state = state,
            onBack = navController::popBackStack,
            onSelect = find::selectFormat,
            onSubmit = find::submit,
            onOpenPublication = openDetails,
            onOpenRequest = find::openRequest,
        )
    }
    screen(REQUEST, listOf(navArgument("id") { type = NavType.StringType })) { entry ->
        val id = requireNotNull(entry.arguments?.getString("id"))
        val state by find.track.collectAsStateWithLifecycle()
        LifecycleResumeEffect(find, id) {
            find.followId(id)
            find.startTracking(id)
            onPauseOrDispose { find.stopTracking() }
        }
        RequestScreen(
            state = state,
            host = host,
            onBack = navController::popBackStack,
            onOpen = { publicationId -> find.openPublication(publicationId, openPublication) },
            onDetails = openDetails,
            onCancel = find::cancelRequest,
            onRetry = { find.startTracking(id) },
        )
    }
}
