package org.shelfarr.app.update

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Context
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Checks the real PackageManager reading on a device: this app's own APK must read
 * back as exactly the installed identity, and a damaged copy must not read at all.
 */
@RunWith(AndroidJUnit4::class)
class PackageInspectorTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val inspector = AndroidPackageInspector(context)

    @Test
    fun ownApkReadsAsTheInstalledApp() {
        val installed = inspector.installed()
        assertEquals(context.packageName, installed.packageName)
        assertTrue(installed.signers.isNotEmpty())
        val copy = File(context.cacheDir, "self-copy.apk")
        File(context.packageCodePath).copyTo(copy, overwrite = true)
        try {
            val archive = inspector.archive(copy)!!
            assertEquals(installed.packageName, archive.packageName)
            assertEquals(installed.versionCode, archive.versionCode)
            assertEquals(installed.versionName, archive.versionName)
            assertEquals(installed.signers, archive.signers)
        } finally {
            copy.delete()
        }
    }

    @Test
    fun aTruncatedApkIsUnreadable() {
        val copy = File(context.cacheDir, "self-truncated.apk")
        val bytes = File(context.packageCodePath).readBytes()
        copy.writeBytes(bytes.copyOf(bytes.size / 2))
        try {
            assertNull(inspector.archive(copy))
        } finally {
            copy.delete()
        }
    }
}
