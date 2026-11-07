package org.shelfarr.app.ui

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlinx.coroutines.flow.MutableStateFlow
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
