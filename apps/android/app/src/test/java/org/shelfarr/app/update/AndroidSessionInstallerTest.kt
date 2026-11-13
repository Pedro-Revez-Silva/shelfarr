package org.shelfarr.app.update

import android.app.Application
import android.content.Context
import android.content.pm.PackageInstaller
import androidx.test.core.app.ApplicationProvider
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/** Exercises the production adapter; only Android's blocking framework endpoint is replaced. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class, shadows = [BlockingPackageInstaller::class])
class AndroidSessionInstallerTest {
    @get:Rule val folder = TemporaryFolder()

    @Before
    fun resetFramework() {
        BlockingPackageInstaller.entered = CountDownLatch(1)
        BlockingPackageInstaller.finish = CountDownLatch(1)
        BlockingPackageInstaller.abandoned.set(0)
        BlockingPackageInstaller.refused = false
    }

    @Test
    fun `cancellation during Android session creation abandons it before copying or committing`() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val adapter = AndroidSessionInstaller(context)
        val apk = folder.newFile("update.apk").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val created = AtomicInteger()
        try {
            val job = scope.launch { adapter.commit(apk) { created.incrementAndGet() } }
            assertTrue(BlockingPackageInstaller.entered.await(10, TimeUnit.SECONDS))
            job.cancel()
            BlockingPackageInstaller.finish.countDown()
            withTimeout(10_000) { job.join() }
            assertEquals("Cancelled session was never handed to the updater", 0, created.get())
            assertEquals(1, BlockingPackageInstaller.abandoned.get())
        } finally {
            BlockingPackageInstaller.finish.countDown()
            scope.cancel()
        }
    }

    @Test
    fun `a restricted Android user gets an installation error instead of an uncaught exception`() = runBlocking {
        BlockingPackageInstaller.refused = true
        val adapter = AndroidSessionInstaller(ApplicationProvider.getApplicationContext())
        val apk = folder.newFile("update.apk").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        try {
            adapter.commit(apk) { fail("No session should be created") }
            fail("Expected installation error")
        } catch (error: UpdateException) {
            assertEquals(UpdateProblem.INSTALL_FAILED, error.problem)
        }
    }
}

@Implements(PackageInstaller::class)
class BlockingPackageInstaller {
    @Implementation
    protected fun createSession(params: PackageInstaller.SessionParams): Int {
        if (refused) throw SecurityException("Restricted test user")
        entered.countDown()
        check(finish.await(10, TimeUnit.SECONDS))
        return 77
    }

    @Implementation
    protected fun abandonSession(sessionId: Int) {
        check(sessionId == 77)
        abandoned.incrementAndGet()
    }

    companion object {
        @JvmField var entered = CountDownLatch(1)
        @JvmField var finish = CountDownLatch(1)
        @JvmField val abandoned = AtomicInteger()
        @JvmField var refused = false
    }
}
