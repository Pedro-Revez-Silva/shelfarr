package org.shelfarr.app.transfer

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.shelfarr.app.ShelfarrApplication

/**
 * Android 8–13 only: a `dataSync` foreground service started while the app is visible,
 * so a long download isn't cut into ten-minute job slices. It drives the same queue as
 * the job and stops itself when nothing is left. It is never restarted from the
 * background; the job covers that.
 */
class DownloadForegroundService : Service() {
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (job?.isActive == true) return START_NOT_STICKY
        val container = (application as ShelfarrApplication).container
        container.currentAccount()
        val notifications = container.transferNotifications
        try {
            ServiceCompat.startForeground(
                this,
                TransferNotifications.PROGRESS_ID,
                notifications.preparing(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
        } catch (error: RuntimeException) {
            // Not allowed now (for example started too late); the scheduled job still runs the queue.
            Log.w(TAG, "Could not enter the foreground", error)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        isRunning = true
        job = container.scope.launch {
            try {
                TransferDriver(container.transferAccounts, budget = null).drive(
                    publish = { account, records -> notifications.show(notifications.progress(transferSummary(records), account.accountKey)) },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.e(TAG, "The download service failed", error)
            } finally {
                withContext(Dispatchers.Main) { finish() }
            }
        }
        return START_NOT_STICKY
    }

    /** Android 15+ would time out a long dataSync service; this service isn't used there, but stop cleanly anyway. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "The download service timed out")
        job?.cancel()
        finish()
    }

    private fun finish() {
        isRunning = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        isRunning = false
        job?.cancel()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "ShelfarrTransfers"

        @Volatile
        var isRunning: Boolean = false
            private set
    }
}
