package org.shelfarr.app.transfer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.launch
import org.shelfarr.app.ShelfarrApplication

/**
 * Handles Cancel on the progress notification. The intent names the account it was
 * built for; if someone else is signed in by the time it is tapped, it does nothing.
 */
class DownloadActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CANCEL) return
        val accountKey = intent.getStringExtra(EXTRA_ACCOUNT)
        val ids = intent.getStringArrayExtra(EXTRA_IDS).orEmpty().toList()
        val container = (context.applicationContext as ShelfarrApplication).container
        val pending = goAsync()
        container.scope.launch {
            try {
                container.cancelDownloads(accountKey, ids)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION_CANCEL = "org.shelfarr.app.action.CANCEL_DOWNLOADS"
        const val EXTRA_ACCOUNT = "account"
        const val EXTRA_IDS = "publications"
        internal const val TAG = "ShelfarrTransfers"

        fun logIgnored() = Log.w(TAG, "Ignored a download cancel for an account that is no longer signed in")
    }
}
