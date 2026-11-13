package org.shelfarr.app.transfer

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.util.Log
import androidx.annotation.ChecksSdkIntAtLeast
import androidx.core.content.ContextCompat

/** How the OS was asked to keep transfers going, for diagnostics and tests. */
enum class TransferHostKind { NONE, USER_INITIATED_JOB, JOB, JOB_AND_SERVICE }

/**
 * Asks Android to keep user-requested downloads going outside the app's screens.
 *
 * - Android 14+: a user-initiated data transfer job, which must be scheduled while the
 *   app is visible, shows a notification and is listed in the Task Manager. If that is
 *   refused (for example the request came from the background), a regular job with a
 *   network constraint is the fallback.
 * - Android 8–13: a `dataSync` foreground service started while the app is visible,
 *   plus a regular network-constrained job that survives process death and restarts
 *   the queue in bounded slices (the OS stops ordinary jobs after about 10 minutes).
 *
 * Both are persisted, so the OS may restore them after a reboot. A force stop cancels
 * them; nothing here can or tries to undo that.
 */
class TransferScheduler(
    private val context: Context,
    private val isVisible: () -> Boolean,
    private val preferences: SharedPreferences,
    /** The device's API level; injectable so each version's choice can be tested on one runtime. */
    private val sdkInt: Int = Build.VERSION.SDK_INT,
) : RetryBudget {
    private val jobs: JobScheduler = context.getSystemService(JobScheduler::class.java)

    /** True when a job is scheduled or running that will drive the queue. */
    fun hasScheduledWork(): Boolean = jobs.getPendingJob(JOB_ID) != null

    /** Call after the queue is persisted. Safe to call repeatedly. */
    @Synchronized
    fun request(estimatedBytes: Long): TransferHostKind {
        val visible = isVisible()
        if (visible) reset()
        val pending = jobs.getPendingJob(JOB_ID)
        if (atLeast(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)) {
            if (pending != null && pending.isUserInitiated) return TransferHostKind.USER_INITIATED_JOB
            // Replacing a pending regular job is fine; the replaced one is told it was cancelled by the app.
            if (visible && schedule(userInitiated = true, estimatedBytes)) return TransferHostKind.USER_INITIATED_JOB
            if (pending != null) return TransferHostKind.JOB
            return if (schedule(userInitiated = false, estimatedBytes)) TransferHostKind.JOB else TransferHostKind.NONE
        }
        val scheduled = pending != null || schedule(userInitiated = false, estimatedBytes)
        val serviceStarted = visible && startService()
        return when {
            serviceStarted -> TransferHostKind.JOB_AND_SERVICE
            scheduled -> TransferHostKind.JOB
            else -> TransferHostKind.NONE
        }
    }

    /** Stops asking the OS for time, for sign-out. Running hosts notice no account and finish. */
    fun cancel() {
        jobs.cancel(JOB_ID)
        context.stopService(Intent(context, DownloadForegroundService::class.java))
    }

    private fun schedule(userInitiated: Boolean, estimatedBytes: Long): Boolean {
        val builder = JobInfo.Builder(JOB_ID, ComponentName(context, DownloadJobService::class.java))
            .setPersisted(true)
            .setBackoffCriteria(BACKOFF_MS, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
        if (atLeast(Build.VERSION_CODES.P)) {
            // NETWORK_TYPE_ANY also requires validated Internet. A reachable Shelfarr
            // server may instead be on a LAN or VPN without public connectivity.
            builder.setRequiredNetwork(NetworkRequest.Builder()
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build())
        } else {
            // Older APIs cannot express that network request. A delayed regular job
            // attempts the transfer and uses the same bounded retry budget if offline.
            builder.setMinimumLatency(1_000)
        }
        if (estimatedBytes > 0 && atLeast(Build.VERSION_CODES.P)) {
            builder.setEstimatedNetworkBytes(estimatedBytes, 0)
        }
        if (userInitiated && atLeast(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)) builder.setUserInitiated(true)
        return try {
            val result = jobs.schedule(builder.build())
            if (result != JobScheduler.RESULT_SUCCESS) Log.w(TAG, "The system declined the ${if (userInitiated) "user-initiated " else ""}download job")
            result == JobScheduler.RESULT_SUCCESS
        } catch (error: SecurityException) {
            Log.w(TAG, "Not allowed to schedule the download job", error)
            false
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "The download job was rejected", error)
            false
        }
    }

    @ChecksSdkIntAtLeast(parameter = 0)
    private fun atLeast(version: Int): Boolean = sdkInt >= version

    private fun startService(): Boolean = try {
        ContextCompat.startForegroundService(context, Intent(context, DownloadForegroundService::class.java))
        true
    } catch (error: IllegalStateException) {
        // Includes ForegroundServiceStartNotAllowedException: the job still carries on.
        Log.w(TAG, "Could not start the download service", error)
        false
    } catch (error: SecurityException) {
        Log.w(TAG, "Could not start the download service", error)
        false
    }

    @Synchronized
    override fun consume(): Boolean {
        val used = preferences.getInt(KEY_RETRIES, 0) + 1
        preferences.edit().putInt(KEY_RETRIES, used).apply()
        return used <= MAX_RETRIES
    }

    @Synchronized
    override fun reset() {
        if (preferences.getInt(KEY_RETRIES, 0) != 0) preferences.edit().putInt(KEY_RETRIES, 0).apply()
    }

    companion object {
        private const val TAG = "ShelfarrTransfers"
        const val JOB_ID = 4_100
        private const val BACKOFF_MS = 30_000L
        private const val KEY_RETRIES = "transfer_retries"

        /** About half an hour of exponential backoff, then it waits for the person to come back. */
        const val MAX_RETRIES = 6
    }
}
