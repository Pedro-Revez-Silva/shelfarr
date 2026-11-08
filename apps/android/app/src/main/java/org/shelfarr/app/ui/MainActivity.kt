package org.shelfarr.app.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.ui.theme.ShelfarrTheme

class MainActivity : ComponentActivity() {
    /** A screen asked for from outside, such as the download notification. Consumed once shown. */
    private val requestedScreen = MutableStateFlow<AppScreen?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // The tab bar carries its own background, so no system scrim is wanted.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) window.isNavigationBarContrastEnforced = false
        val container = (application as ShelfarrApplication).container
        // A recreated activity has already handled its launch intent.
        if (savedInstanceState == null) handle(intent)
        setContent {
            val appearance by container.appearance.collectAsState()
            ShelfarrTheme(appearance) { ShelfarrApp(container, requestedScreen) }
        }
        // Android's update confirmation is only ever shown over a visible Shelfarr screen.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                container.updater.confirmation.filterNotNull().collect { pending ->
                    container.updater.confirmationShown(pending.sessionId)
                    try {
                        startActivity(pending.intent)
                    } catch (_: ActivityNotFoundException) {
                        container.updater.cancelInstall()
                    } catch (_: SecurityException) {
                        container.updater.cancelInstall()
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        if (intent?.action == ACTION_OPEN_DOWNLOADS) requestedScreen.value = AppScreen.DOWNLOADS
    }

    companion object {
        const val ACTION_OPEN_DOWNLOADS = "org.shelfarr.app.action.OPEN_DOWNLOADS"
    }
}

/** Screens that can be opened from outside the app. */
enum class AppScreen { DOWNLOADS }
