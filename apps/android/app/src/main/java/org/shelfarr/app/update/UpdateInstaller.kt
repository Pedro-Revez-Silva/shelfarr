package org.shelfarr.app.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.shelfarr.app.ShelfarrApplication

/** What Android reported for a committed session. [code] is a `PackageInstaller.STATUS_*` value. */
data class InstallStatus(
    val sessionId: Int,
    val code: Int,
    /** Android's confirmation screen, for [PackageInstaller.STATUS_PENDING_USER_ACTION]. */
    val confirmation: Intent? = null,
)

/** Android's installer, behind an interface so the updater's decisions can be tested. */
interface PackageSessionInstaller {
    /** Whether the person has allowed this app to install apps (Android 8+ "unknown apps"). */
    fun canRequestInstalls(): Boolean

    /**
     * Copies [apk] into a new session and commits it. [onCreated] receives the session
     * before it is committed, so a fast status can't arrive for an unknown session.
     * Android reports the outcome through [UpdateInstallReceiver].
     */
    suspend fun commit(apk: File, onCreated: (Int) -> Unit)

    /** Whether [sessionId] still exists, i.e. Android hasn't finished or dropped it. */
    fun isOpen(sessionId: Int): Boolean

    fun abandon(sessionId: Int)

    /** Abandons this app's sessions other than [keep], left behind by an earlier process. */
    fun abandonOthers(keep: Int?)
}

class AndroidSessionInstaller(private val context: Context) : PackageSessionInstaller {
    private val installer: PackageInstaller get() = context.packageManager.packageInstaller

    override fun canRequestInstalls(): Boolean = context.packageManager.canRequestPackageInstalls()

    override suspend fun commit(apk: File, onCreated: (Int) -> Unit) = withContext(Dispatchers.IO) {
        val operation = currentCoroutineContext()
        operation.ensureActive()
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            setInstallReason(PackageManager.INSTALL_REASON_USER)
            // Always show Android's confirmation. Without this, a self-update can be silent
            // on Android 12+, closing the app the moment the person taps Install.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
        }
        val sessionId = try {
            installer.createSession(params)
        } catch (error: Exception) {
            when (error) {
                is IOException, is SecurityException, is IllegalStateException, is IllegalArgumentException ->
                    throw UpdateException(UpdateProblem.INSTALL_FAILED, "Android couldn't start the installation", error)
                else -> throw error
            }
        }
        try {
            // Binder calls and file copies are blocking. Cancellation while Android
            // creates a session must abandon that new session before it can be committed.
            operation.ensureActive()
            onCreated(sessionId)
            installer.openSession(sessionId).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("shelfarr.apk", 0, apk.length()).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            operation.ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                        operation.ensureActive()
                        session.fsync(output)
                    }
                }
                operation.ensureActive()
                session.commit(statusReceiver(sessionId).intentSender)
            }
        } catch (error: Exception) {
            runCatching { installer.abandonSession(sessionId) }
            when (error) {
                is CancellationException -> throw error
                is IOException, is SecurityException, is IllegalStateException, is IllegalArgumentException ->
                    throw UpdateException(UpdateProblem.INSTALL_FAILED, "Android couldn't take the update file", error)
                else -> throw error
            }
        }
    }

    /** Must be mutable: Android adds the status extras. It names our receiver explicitly. */
    private fun statusReceiver(sessionId: Int): PendingIntent {
        val intent = Intent(context, UpdateInstallReceiver::class.java)
            .setAction(UpdateInstallReceiver.ACTION_STATUS)
            .setPackage(context.packageName)
        val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        return PendingIntent.getBroadcast(context, sessionId, intent, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
    }

    override fun isOpen(sessionId: Int): Boolean = installer.getSessionInfo(sessionId) != null

    override fun abandon(sessionId: Int) {
        try {
            installer.abandonSession(sessionId)
        } catch (_: SecurityException) {
            // Already finished or no longer ours.
        }
    }

    override fun abandonOthers(keep: Int?) {
        installer.mySessions.filter { it.sessionId != keep }.forEach { abandon(it.sessionId) }
    }
}

/** Receives Android's installer status for sessions this app committed. Not exported. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_STATUS) return
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val code = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        // Android's detail is for diagnosis only; the person sees the updater's own wording.
        Log.i(TAG, "Install session $sessionId status $code: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
        val confirmation = if (code == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
        } else {
            null
        }
        val application = context.applicationContext as? ShelfarrApplication ?: return
        val pending = goAsync()
        application.container.updater.onInstallStatus(InstallStatus(sessionId, code, confirmation))
            .invokeOnCompletion { pending.finish() }
    }

    companion object {
        const val ACTION_STATUS = "org.shelfarr.app.action.UPDATE_INSTALL_STATUS"
        private const val TAG = "ShelfarrUpdater"
    }
}
