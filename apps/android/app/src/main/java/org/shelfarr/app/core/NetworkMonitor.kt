package org.shelfarr.app.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the device has a network that claims internet access. It is only a hint for
 * when to try again: whether the server is reachable is decided by real requests.
 */
class NetworkMonitor(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val state = MutableStateFlow(current())
    val online: StateFlow<Boolean> = state.asStateFlow()

    init {
        try {
            connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    state.value = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                }

                override fun onLost(network: Network) {
                    state.value = false
                }
            })
        } catch (error: RuntimeException) {
            // Too many callbacks or a missing permission: requests still decide, just without a nudge.
            Log.w("ShelfarrNetwork", "Could not watch connectivity", error)
        }
    }

    /** Whether the active network is unmetered, such as Wi-Fi: a hint for optional downloads. */
    fun isUnmetered(): Boolean = try {
        connectivity.activeNetwork != null && !connectivity.isActiveNetworkMetered
    } catch (error: RuntimeException) {
        Log.w("ShelfarrNetwork", "Could not read the network's metering", error)
        false
    }

    private fun current(): Boolean {
        val network = connectivity.activeNetwork ?: return false
        return connectivity.getNetworkCapabilities(network)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }
}
