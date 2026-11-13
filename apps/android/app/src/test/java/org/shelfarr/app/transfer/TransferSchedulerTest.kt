package org.shelfarr.app.transfer

import android.app.Application
import android.app.job.JobScheduler
import android.content.Context
import android.app.job.JobInfo
import android.net.NetworkCapabilities
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Which OS host each Android version gets, against Robolectric's JobScheduler. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class TransferSchedulerTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val jobs = context.getSystemService(JobScheduler::class.java)
    private val preferences = context.getSharedPreferences("test", Context.MODE_PRIVATE)
    private var visible = true
    private fun scheduler(sdk: Int) = TransferScheduler(context, { visible }, preferences, sdk)

    @Test
    fun `Android 14 schedules a persisted user-initiated transfer while visible`() {
        val scheduler = scheduler(34)
        assertEquals(TransferHostKind.USER_INITIATED_JOB, scheduler.request(5_000_000))
        val job = jobs.getPendingJob(TransferScheduler.JOB_ID)!!
        assertTrue(job.isUserInitiated)
        assertTrue(job.isPersisted)
        assertEquals(5_000_000L, job.estimatedNetworkDownloadBytes)
        assertTrue(scheduler.hasScheduledWork())
        // Asking again keeps the running transfer instead of replacing it.
        assertEquals(TransferHostKind.USER_INITIATED_JOB, scheduler.request(1))
        assertEquals(5_000_000L, jobs.getPendingJob(TransferScheduler.JOB_ID)!!.estimatedNetworkDownloadBytes)
        assertNull("No foreground service on 14+", shadowOf(context as Application).nextStartedService)
    }

    @Test
    fun `Android 14 in the background falls back to a regular job, then upgrades when visible`() {
        val scheduler = scheduler(34)
        visible = false
        assertEquals(TransferHostKind.JOB, scheduler.request(10))
        assertFalse(jobs.getPendingJob(TransferScheduler.JOB_ID)!!.isUserInitiated)
        visible = true
        assertEquals(TransferHostKind.USER_INITIATED_JOB, scheduler.request(10))
        assertTrue(jobs.getPendingJob(TransferScheduler.JOB_ID)!!.isUserInitiated)
    }

    @Test
    fun `Android 13 uses a foreground service while visible plus a job that survives the process`() {
        val scheduler = scheduler(33)
        assertEquals(TransferHostKind.JOB_AND_SERVICE, scheduler.request(10))
        val job = jobs.getPendingJob(TransferScheduler.JOB_ID)!!
        assertTrue(job.isPersisted)
        val started = shadowOf(context as Application).nextStartedService
        assertEquals(DownloadForegroundService::class.java.name, started.component!!.className)
        visible = false
        assertEquals(TransferHostKind.JOB, scheduler.request(10))
        assertNull(shadowOf(context).nextStartedService)
    }

    @Test
    fun `the oldest supported version still gets a job`() {
        val scheduler = scheduler(26)
        visible = false
        assertEquals(TransferHostKind.JOB, scheduler.request(0))
        assertTrue(scheduler.hasScheduledWork())
        scheduler.cancel()
        assertFalse(scheduler.hasScheduledWork())
    }

    @Test
    fun `LAN and VPN jobs do not require validated public Internet`() {
        val scheduler = scheduler(34)
        scheduler.request(100)
        val request = jobs.getPendingJob(TransferScheduler.JOB_ID)!!.requiredNetwork!!
        assertFalse(request.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
        assertFalse(request.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
        assertFalse(request.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN))
    }

    @Test
    @Suppress("DEPRECATION")
    fun `old Android retries LAN transfers without an Internet-only constraint`() {
        visible = false
        scheduler(26).request(100)
        val job = jobs.getPendingJob(TransferScheduler.JOB_ID)!!
        assertEquals(JobInfo.NETWORK_TYPE_NONE, job.networkType)
        assertTrue(job.minLatencyMillis > 0)
    }

    @Test
    fun `the retry budget is bounded and resets when the person is back`() {
        val scheduler = scheduler(34)
        repeat(TransferScheduler.MAX_RETRIES) { assertTrue(scheduler.consume()) }
        assertFalse(scheduler.consume())
        visible = true
        scheduler.request(1)
        assertTrue(scheduler.consume())
    }
}
