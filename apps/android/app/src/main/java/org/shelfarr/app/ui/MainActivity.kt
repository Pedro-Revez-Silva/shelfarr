package org.shelfarr.app.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import org.shelfarr.app.ShelfarrApplication
import org.shelfarr.app.ui.theme.ShelfarrTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = (application as ShelfarrApplication).container
        setContent {
            val appearance by container.appearance.collectAsState()
            ShelfarrTheme(appearance) { ShelfarrApp(container) }
        }
    }
}
