package org.shelfarr.app.update

import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where the in-app updater is. Every state but [Disabled] and [Idle] concerns one [release]. */
sealed interface UpdateState {
    val release: UpdateRelease? get() = null

    /** This build has no update feed. */
    data object Disabled : UpdateState

    /** Nothing to offer. [lastCheckedAtMs] is null until the first successful check. */
    data class Idle(
        val lastCheckedAtMs: Long? = null,
        val checking: Boolean = false,
        /** Why the last check the person asked for failed, or why the newest release can't be offered. */
        val problem: String? = null,
        /** A one-off outcome, such as having just updated. */
        val notice: String? = null,
    ) : UpdateState

    data class Available(override val release: UpdateRelease, val problem: String? = null) : UpdateState

    data class Downloading(override val release: UpdateRelease, val bytesDone: Long = 0) : UpdateState

    /** Downloaded and verified; installing waits for the person. */
    data class Ready(override val release: UpdateRelease, val notice: String? = null) : UpdateState

    /** Android needs the person to allow this app to install apps. */
    data class NeedsPermission(override val release: UpdateRelease) : UpdateState

    /** Handed to Android. [canShowPrompt] when its confirmation can be shown again. */
    data class Installing(
        override val release: UpdateRelease,
        val awaitingConfirmation: Boolean = false,
        val canShowPrompt: Boolean = false,
    ) : UpdateState
}

/** Whether there is an update the person might act on, for a quiet badge. */
val UpdateState.hasUpdate: Boolean get() = release != null

enum class InstallRequest {
    STARTED,

    /** Audio is playing. Ask the person; call again with `pausePlayback = true` to pause first. */
    PLAYBACK_ACTIVE,

    /** The person must allow installs first; see [UpdateState.NeedsPermission]. */
    NEEDS_PERMISSION,

    /** Nothing ready to install, or an installation is already under way. */
    IGNORED,
}

/** Android's confirmation screen for [sessionId], to be started from a visible activity. */
data class PendingConfirmation(val sessionId: Int, val intent: Intent)

/** Lets the updater see and pause audio. Called on the main thread. */
interface PlaybackGuard {
    val isPlaying: Boolean
    fun pause()
}

/**
 * Finds, downloads and installs newer builds of this app from its build-time feed.
 *
 * Checks happen at most every [autoCheckIntervalMs] while the app is in use, or when
 * asked. Downloading and installing only ever start because the person asked. A
 * download must match the feed's size and SHA-256, and be this app — same package,
 * same signing certificates — at exactly the announced, strictly newer version.
 * Those checks are repeated just before Android's installer takes the file; Android
 * then verifies the signature itself and asks the person to confirm.
 *
 * Public methods are meant for the main thread; work runs on [scope].
 */
class AppUpdater(
    source: UpdateSource?,
    channel: String,
    private val fetcher: UpdateFetcher?,
    private val inspector: PackageInspector,
    private val installer: PackageSessionInstaller,
    private val directory: File,
    private val playback: PlaybackGuard,
    private val scope: CoroutineScope,
    /** Saves listening and reading places; runs before Android may replace this process. */
    private val beforeInstall: suspend () -> Unit = {},
    private val clock: () -> Long = System::currentTimeMillis,
    private val sdkInt: Int = android.os.Build.VERSION.SDK_INT,
    private val autoCheckIntervalMs: Long = AUTO_CHECK_INTERVAL_MS,
) {
    private val expectation: FeedExpectation? = source?.let { FeedExpectation(it, channel, inspector.installed().packageName) }
    private val store = UpdateStore(File(directory, STATE_FILE))

    private val mutableState = MutableStateFlow<UpdateState>(if (expectation == null) UpdateState.Disabled else UpdateState.Idle())
    val state: StateFlow<UpdateState> = mutableState.asStateFlow()

    private val pendingConfirmation = MutableStateFlow<PendingConfirmation?>(null)

    /** Android's confirmation, waiting for a visible activity to show it. */
    val confirmation: StateFlow<PendingConfirmation?> = pendingConfirmation.asStateFlow()

    private val lock = Any()
    private var restoring: Job? = null
    private var checkJob: Job? = null
    private var downloadJob: Job? = null
    private var downloadPartial: File? = null
    private var installJob: Job? = null
    private var activeSession: Int? = null
    private var lastPrompt: PendingConfirmation? = null
    private var lastAttemptAtMs: Long? = null
    private var lastCheckedAtMs: Long? = null

    val enabled: Boolean get() = expectation != null

    /** Restores what an earlier process left: a verified download, an open session, a finished update. */
    fun start(): Job? {
        if (expectation == null) return null
        return synchronized(lock) {
            restoring ?: scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) { restore(expectation) }.also {
                restoring = it
                it.start()
            }
        }
    }

    private fun restore(expected: FeedExpectation) {
        val saved = store.read()
        val installed = inspector.installed()
        val release = saved.release?.let { text ->
            try {
                UpdateManifest.parse(text, expected)
            } catch (_: UpdateException) {
                null
            }
        }
        val artifact = saved.artifact?.let { File(directory, it) }?.takeIf { it.parentFile == directory }
        val sessionOpen = saved.sessionId?.let(installer::isOpen) == true
        installer.abandonOthers(keep = saved.sessionId.takeIf { sessionOpen })
        synchronized(lock) {
            lastAttemptAtMs = saved.lastAttemptAtMs
            lastCheckedAtMs = saved.lastCheckedAtMs
            val next: UpdateState = when {
                release == null || release.versionCode <= installed.versionCode -> {
                    val updated = release != null && (saved.artifact != null || saved.sessionId != null)
                    if (sessionOpen) installer.abandon(saved.sessionId)
                    UpdateState.Idle(
                        lastCheckedAtMs = saved.lastCheckedAtMs,
                        notice = if (updated) "Updated to ${installed.versionName ?: "the new version"}" else null,
                    )
                }
                sessionOpen -> {
                    activeSession = saved.sessionId
                    UpdateState.Installing(release)
                }
                artifact != null && artifact.isFile && artifact.length() == release.sizeBytes -> UpdateState.Ready(
                    release,
                    notice = if (saved.sessionId != null) "The last installation didn't finish" else null,
                )
                else -> UpdateState.Available(release)
            }
            persist(next, saved.lastCheckedAtMs)
            mutableState.value = next
            sweep()
        }
    }

    /** A check when one is due. Call as the app comes to the foreground. */
    fun onForeground() {
        if (expectation == null) return
        scope.launch {
            restoring?.join()
            reconcileInstalling()
            if (isCheckDue()) check(manual = false)
        }
    }

    /**
     * Due every [autoCheckIntervalMs] after the last successful check, but no sooner than
     * [RETRY_INTERVAL_MS] after any attempt, so an offline launch doesn't wait a whole interval.
     */
    private fun isCheckDue(): Boolean = synchronized(lock) {
        val now = clock()
        fun elapsed(since: Long?, interval: Long) = since == null || now < since || now - since >= interval
        elapsed(lastCheckedAtMs, autoCheckIntervalMs) && elapsed(lastAttemptAtMs, minOf(RETRY_INTERVAL_MS, autoCheckIntervalMs))
    }

    /** Checks now, because the person asked. */
    fun checkNow() {
        if (expectation == null) return
        scope.launch {
            restoring?.join()
            check(manual = true)
        }
    }

    private fun check(manual: Boolean) {
        val expected = expectation ?: return
        val fetch = fetcher ?: return
        synchronized(lock) {
            if (checkJob?.isActive == true || downloadJob?.isActive == true || installJob?.isActive == true) return
            if (mutableState.value is UpdateState.Installing) return
            val now = clock()
            lastAttemptAtMs = now
            store.update { it.copy(lastAttemptAtMs = now) }
            (mutableState.value as? UpdateState.Idle)?.let {
                mutableState.value = it.copy(checking = true, problem = null, notice = if (manual) null else it.notice)
            }
            val job = scope.launch(start = CoroutineStart.LAZY) {
                val outcome = try {
                    Result.success(UpdateManifest.parse(fetch.fetchFeed(), expected))
                } catch (error: UpdateException) {
                    Log.i(TAG, "Update check failed: ${error.message}")
                    Result.failure(error)
                }
                synchronized(lock) {
                    if (checkJob != coroutineContext[Job]) return@launch
                    checkJob = null
                    outcome.fold(
                        onSuccess = { offer(it) },
                        onFailure = { failed(it.message ?: "Couldn't check for updates", manual) },
                    )
                    sweep()
                }
            }
            checkJob = job
            job.start()
        }
    }

    /** Applies a freshly checked release. Holds [lock]. */
    private fun offer(release: UpdateRelease) {
        val now = clock()
        lastCheckedAtMs = now
        val installed = inspector.installed()
        val current = mutableState.value
        val next: UpdateState = when {
            release.versionCode <= installed.versionCode -> UpdateState.Idle(lastCheckedAtMs = now)
            (release.minSdk ?: 0) > sdkInt -> UpdateState.Idle(
                lastCheckedAtMs = now,
                problem = "Version ${release.versionName} needs a newer version of Android",
            )
            // The same release: keep whatever progress has been made with it.
            current.release == release -> when (current) {
                is UpdateState.Available -> current.copy(problem = null)
                else -> current
            }
            else -> UpdateState.Available(release)
        }
        persist(next, now)
        mutableState.value = next
    }

    /** Holds [lock]. Automatic checks fail quietly; only an asked-for check reports. */
    private fun failed(message: String, manual: Boolean) {
        val current = mutableState.value
        if (current is UpdateState.Idle) {
            mutableState.value = current.copy(checking = false, problem = if (manual) message else current.problem)
        }
    }

    /** Downloads the available release, because the person asked. */
    fun download() {
        val fetch = fetcher ?: return
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.Available ?: return
            if (downloadJob?.isActive == true) return
            // A foreground check may still be fetching a new offer. It must not
            // replace or sweep the release the person has just chosen to download.
            checkJob?.cancel()
            checkJob = null
            val release = current.release
            val needed = release.sizeBytes + SPACE_MARGIN_BYTES
            directory.mkdirs()
            if (directory.usableSpace in 0 until needed) {
                mutableState.value = current.copy(problem = "Free up some space on this device to download the update")
                return
            }
            mutableState.value = UpdateState.Downloading(release)
            // Cancellation cannot interrupt PackageManager's archive inspection.
            // Give each attempt its own file so its eventual cleanup cannot touch a retry.
            val partial = File(directory, "update-${release.versionCode}-${UUID.randomUUID()}.apk.part")
            downloadPartial = partial
            downloadJob = scope.launch(start = CoroutineStart.LAZY) { download(fetch, release, partial) }.also { it.start() }
        }
    }

    private suspend fun download(fetch: UpdateFetcher, release: UpdateRelease, partial: File) {
        val final = File(directory, "update-${release.versionCode}.apk")
        val self = kotlin.coroutines.coroutineContext[Job]
        try {
            fetch.download(release, partial) { bytes ->
                synchronized(lock) {
                    if (downloadJob == self) mutableState.value = UpdateState.Downloading(release, bytes)
                }
            }
            withContext(Dispatchers.IO) { verify(partial, release) }
            synchronized(lock) {
                if (downloadJob != self) {
                    partial.delete()
                    return
                }
                final.delete()
                if (!partial.renameTo(final)) throw UpdateException(UpdateProblem.STORAGE, "Couldn't save the update")
                downloadJob = null
                downloadPartial = null
                val next = UpdateState.Ready(release)
                persist(next)
                mutableState.value = next
            }
        } catch (cancelled: CancellationException) {
            partial.delete()
            throw cancelled
        } catch (error: UpdateException) {
            partial.delete()
            Log.i(TAG, "Update download failed: ${error.message}")
            synchronized(lock) {
                if (downloadJob != self) return
                downloadJob = null
                downloadPartial = null
                mutableState.value = UpdateState.Available(release, problem = error.message)
            }
        }
    }

    fun cancelDownload() {
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.Downloading ?: return
            downloadJob?.cancel()
            downloadJob = null
            downloadPartial = null
            mutableState.value = UpdateState.Available(current.release)
        }
    }

    /**
     * Hands the verified download to Android, because the person asked. Never
     * interrupts audio on its own: with audio playing it returns
     * [InstallRequest.PLAYBACK_ACTIVE] unless [pausePlayback] says the person agreed.
     */
    fun install(pausePlayback: Boolean = false): InstallRequest {
        synchronized(lock) {
            val release = when (val current = mutableState.value) {
                is UpdateState.Ready -> current.release
                is UpdateState.NeedsPermission -> current.release
                else -> return InstallRequest.IGNORED
            }
            if (installJob?.isActive == true) return InstallRequest.IGNORED
            if (playback.isPlaying) {
                if (!pausePlayback) return InstallRequest.PLAYBACK_ACTIVE
                playback.pause()
            }
            if (!installer.canRequestInstalls()) {
                mutableState.value = UpdateState.NeedsPermission(release)
                return InstallRequest.NEEDS_PERMISSION
            }
            mutableState.value = UpdateState.Installing(release)
            installJob = scope.launch(start = CoroutineStart.LAZY) { install(release) }.also { it.start() }
            return InstallRequest.STARTED
        }
    }

    private suspend fun install(release: UpdateRelease) {
        val self = kotlin.coroutines.coroutineContext[Job]
        val file = File(directory, "update-${release.versionCode}.apk")
        try {
            withContext(Dispatchers.IO) {
                if (!file.isFile) throw UpdateException(UpdateProblem.INCOMPLETE, "The downloaded update is missing")
                if (file.length() != release.sizeBytes) throw UpdateException(UpdateProblem.INCOMPLETE, "The downloaded update is incomplete")
                if (sha256Of(file) != release.sha256) throw UpdateException(UpdateProblem.CHECKSUM, "The downloaded update has changed")
                verify(file, release)
            }
            beforeInstall()
            installer.commit(file) { sessionId ->
                synchronized(lock) {
                    if (installJob != self || self?.isActive != true) {
                        installer.abandon(sessionId)
                        throw CancellationException("Installation cancelled")
                    }
                    activeSession = sessionId
                    store.update { it.copy(sessionId = sessionId) }
                }
            }
            synchronized(lock) { if (installJob == self) installJob = null }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: UpdateException) {
            Log.i(TAG, "Update installation didn't start: ${error.message}")
            synchronized(lock) {
                if (installJob != self) return
                installJob = null
                activeSession = null
                val next = if (error.problem == UpdateProblem.INSTALL_FAILED || error.problem == UpdateProblem.STORAGE) {
                    UpdateState.Ready(release, notice = error.message)
                } else {
                    // The file is no longer the one that was verified: fetch it again.
                    file.delete()
                    UpdateState.Available(release, problem = "${error.message}. Download it again.")
                }
                persist(next)
                mutableState.value = next
            }
        }
    }

    /** Android reported on a session; see [UpdateInstallReceiver]. */
    fun onInstallStatus(status: InstallStatus): Job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
        // A status broadcast can be what starts this process. Its session must be
        // restored before deciding whether the callback belongs to this installation.
        restoring?.join()
        acceptInstallStatus(status)
    }

    private fun acceptInstallStatus(status: InstallStatus) {
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.Installing ?: return
            if (activeSession != status.sessionId) return
            val release = current.release
            val file = File(directory, "update-${release.versionCode}.apk")
            val next: UpdateState = when (status.code) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val prompt = status.confirmation?.let { PendingConfirmation(status.sessionId, it) }
                    lastPrompt = prompt
                    pendingConfirmation.value = prompt
                    mutableState.value = current.copy(awaitingConfirmation = true, canShowPrompt = prompt != null)
                    return
                }
                PackageInstaller.STATUS_SUCCESS -> {
                    file.delete()
                    UpdateState.Idle(lastCheckedAtMs = clock(), notice = "Updated to ${release.versionName}")
                }
                PackageInstaller.STATUS_FAILURE_ABORTED -> UpdateState.Ready(release, notice = "Installation cancelled")
                PackageInstaller.STATUS_FAILURE_STORAGE ->
                    UpdateState.Ready(release, notice = "There isn't enough space to install the update")
                PackageInstaller.STATUS_FAILURE_BLOCKED ->
                    UpdateState.Ready(release, notice = "Android blocked the installation")
                PackageInstaller.STATUS_FAILURE_CONFLICT,
                PackageInstaller.STATUS_FAILURE_INVALID,
                PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
                -> {
                    // Android rejected this file itself; it won't install on a retry.
                    file.delete()
                    UpdateState.Available(release, problem = "Android couldn't install this update file")
                }
                else -> UpdateState.Ready(release, notice = "Android couldn't install the update")
            }
            activeSession = null
            lastPrompt = null
            pendingConfirmation.value = null
            persist(next)
            mutableState.value = next
        }
    }

    /** A visible activity has started [confirmation]'s screen. */
    fun confirmationShown(sessionId: Int) {
        pendingConfirmation.update { if (it?.sessionId == sessionId) null else it }
    }

    /** Shows Android's confirmation again, if this process still has it. */
    fun showPromptAgain() {
        synchronized(lock) {
            if (mutableState.value !is UpdateState.Installing) return
            lastPrompt?.let { pendingConfirmation.value = it }
        }
    }

    /** Gives up on the installation in progress; the verified download stays. */
    fun cancelInstall() {
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.Installing ?: return
            installJob?.cancel()
            installJob = null
            activeSession?.let(installer::abandon)
            activeSession = null
            lastPrompt = null
            pendingConfirmation.value = null
            val next = UpdateState.Ready(current.release)
            persist(next)
            mutableState.value = next
        }
    }

    /**
     * Back from Android's "install unknown apps" setting. Continues the installation
     * the person asked for if it was allowed; otherwise it keeps explaining.
     */
    fun onPermissionReturned(): InstallRequest {
        synchronized(lock) {
            if (mutableState.value !is UpdateState.NeedsPermission) return InstallRequest.IGNORED
            if (!installer.canRequestInstalls()) return InstallRequest.NEEDS_PERMISSION
        }
        return install().also { result ->
            // Allowed now, but audio started meanwhile: the person chooses again from Install.
            if (result == InstallRequest.PLAYBACK_ACTIVE) dismissPermission()
        }
    }

    fun dismissPermission() {
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.NeedsPermission ?: return
            mutableState.value = UpdateState.Ready(current.release)
        }
    }

    /**
     * Android sometimes drops a session without reporting, for example when its
     * confirmation is dismissed on some versions. Notices that once the app is back.
     */
    fun reconcileInstalling() {
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.Installing ?: return
            if (installJob?.isActive == true) return
            val session = activeSession
            if (session != null && installer.isOpen(session)) return
            activeSession = null
            lastPrompt = null
            pendingConfirmation.value = null
            val next = UpdateState.Ready(current.release, notice = "The installation didn't finish")
            persist(next)
            mutableState.value = next
        }
    }

    /** The announced release's file, checked against the installed app. Throws if it isn't the update. */
    private fun verify(file: File, release: UpdateRelease) {
        val installed = inspector.installed()
        val candidate = inspector.archive(file)
            ?: throw UpdateException(UpdateProblem.IDENTITY, "Android can't read the update file")
        if (candidate.packageName != installed.packageName) {
            throw UpdateException(UpdateProblem.WRONG_APP, "The update file is for a different app")
        }
        if (candidate.versionCode != release.versionCode.toLong() || candidate.versionName != release.versionName) {
            throw UpdateException(UpdateProblem.IDENTITY, "The update file isn't the announced version")
        }
        if (candidate.versionCode <= installed.versionCode) {
            throw UpdateException(UpdateProblem.IDENTITY, "The update file isn't newer than this version")
        }
        if (candidate.signers.isEmpty() || candidate.signers != installed.signers) {
            throw UpdateException(UpdateProblem.IDENTITY, "The update file isn't signed by this app's publisher")
        }
        if ((candidate.minSdk ?: 0) > sdkInt) {
            throw UpdateException(UpdateProblem.INCOMPATIBLE, "The update needs a newer version of Android")
        }
    }

    /** Saves what a relaunch needs for [state]. Holds [lock] or runs before others can. */
    private fun persist(state: UpdateState, checkedAtMs: Long? = null) {
        val release = state.release
        store.update { saved ->
            saved.copy(
                lastCheckedAtMs = checkedAtMs ?: saved.lastCheckedAtMs,
                release = release?.toJson(),
                artifact = when (state) {
                    is UpdateState.Ready, is UpdateState.NeedsPermission, is UpdateState.Installing ->
                        "update-${release?.versionCode}.apk"
                    else -> null
                },
                sessionId = activeSession.takeIf { state is UpdateState.Installing },
            )
        }
    }

    /** Deletes files no state refers to: abandoned partial downloads and superseded releases. Holds [lock]. */
    private fun sweep() {
        val release = mutableState.value.release
        val keep = setOfNotNull(
            STATE_FILE,
            release?.let { "update-${it.versionCode}.apk" },
            downloadPartial?.takeIf { mutableState.value is UpdateState.Downloading }?.name,
        )
        directory.listFiles()?.filter { it.name !in keep }?.forEach { it.delete() }
    }

    companion object {
        private const val TAG = "ShelfarrUpdater"
        private const val STATE_FILE = "state.json"
        const val AUTO_CHECK_INTERVAL_MS = 6L * 60 * 60 * 1_000
        const val RETRY_INTERVAL_MS = 30L * 60 * 1_000
        private const val SPACE_MARGIN_BYTES = 32L * 1024 * 1024
    }
}
