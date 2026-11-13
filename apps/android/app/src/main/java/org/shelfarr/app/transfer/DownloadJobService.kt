package org.shelfarr.app.transfer

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Build
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.shelfarr.app.ShelfarrApplication

/**
 * The OS-managed host for downloads: a user-initiated data transfer job on Android 14+,
 * or a regular network-constrained job before that. It drives the account's single
 * [org.shelfarr.app.core.DownloadManager] and finishes when nothing is queued.
 */
class DownloadJobService : JobService() {
    private val running = ConcurrentHashMap<Int, Job>()

    override fun onStartJob(params: JobParameters): Boolean {
        val container = (application as ShelfarrApplication).container
        // Restore the persisted session synchronously before the driver observes
        // the account flow; its collector may not have run in a cold process yet.
        container.currentAccount()
        val notifications = container.transferNotifications
        val userInitiated = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && params.isUserInitiatedJob
        if (userInitiated) {
            // Required promptly for a user-initiated job; it also lists the job in the Task Manager.
            setNotification(params, TransferNotifications.PROGRESS_ID, notifications.preparing(), JOB_END_NOTIFICATION_POLICY_REMOVE)
        }
        var lastEstimate = -1L
        lateinit var job: Job
        job = container.scope.launch(start = CoroutineStart.LAZY) {
            var reschedule = false
            try {
                reschedule = TransferDriver(container.transferAccounts, container.transfers).drive(
                    publish = { account, records ->
                        val summary = transferSummary(records)
                        val notification = notifications.progress(summary, account.accountKey)
                        if (userInitiated) {
                            setNotification(params, TransferNotifications.PROGRESS_ID, notification, JOB_END_NOTIFICATION_POLICY_REMOVE)
                            val remaining = account.downloads.remainingBytes
                            if (remaining != lastEstimate) {
                                lastEstimate = remaining
                                updateEstimatedNetworkBytes(params, remaining, 0)
                            }
                        } else if (!DownloadForegroundService.isRunning) {
                            notifications.show(notification)
                        }
                    },
                    finished = { _, finished, stopped ->
                        transferResult(finished, stopped)?.let { (title, text) -> notifications.showResult(title, text) }
                    },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                Log.e(TAG, "The download job failed", error)
            } finally {
                if (!userInitiated && !DownloadForegroundService.isRunning) notifications.cancelProgress()
                // After onStopJob the system has already let go of this job.
                if (running.remove(params.jobId, job)) jobFinished(params, reschedule)
            }
        }
        running.put(params.jobId, job)?.cancel()
        job.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        running.remove(params.jobId)?.cancel()
        val container = (application as ShelfarrApplication).container
        var byUser = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val reason = params.stopReason
            Log.i(TAG, "Download job stopped, reason $reason")
            // Rescheduled by the app itself: the replacement job carries on with the same queue.
            if (reason == JobParameters.STOP_REASON_CANCELLED_BY_APP) return false
            byUser = reason == JobParameters.STOP_REASON_USER
        } else {
            Log.i(TAG, "Download job stopped")
        }
        val anotherHost = container.isVisible || DownloadForegroundService.isRunning
        if (byUser || !anotherHost) {
            container.scope.launch {
                container.transferAccounts.value?.downloads?.pause(interrupted = byUser)
            }
        }
        // The person stopped it: don't come back on our own.
        return !byUser
    }

    private companion object {
        const val TAG = "ShelfarrTransfers"
    }
}
