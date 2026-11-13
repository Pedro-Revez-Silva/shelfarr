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
import org.shelfarr.app.core.ServerAddress

/** Where the in-app updater is. Every state but [Disabled] and [Idle] concerns one [release]. */
sealed interface UpdateState {
    val release: UpdateRelease? get() = null

    /** This build has no update feed and doesn't ask servers for one. */
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

/** The feed updates come from right now, and the server context it was chosen for. */
data class UpdateBinding(
    val source: UpdateSource,
    /** The [ServerAddress.identity] this was chosen for; null when no server was connected. */
    val context: String?,
    /** The consumer API generations the server said it speaks; null when it didn't say. */
    val serverApiVersions: Set<Int>?,
)

/**
 * Finds, downloads and installs newer builds of this app.
 *
 * The connected Shelfarr server comes first: it is asked, without any credential,
 * which feed it offers for this build's channel ([ServerDiscovery]). A server from
 * before discovery (404 or 410), or no server at all, falls back to the feed fixed
 * when the app was built, if any. A server that can't be reached or answers
 * something unusable never moves updates to another publisher: the feed chosen
 * earlier for that same server is used again, or the check fails.
 *
 * What is offered, downloaded or being verified belongs to the feed it came from
 * ([UpdateBinding]); a new server, or a new feed for it, discards it.
 *
 * Checks happen at most every [autoCheckIntervalMs] while the app is in use, or when
 * asked. Downloads start because the person asked, or, if they turned on [autoDownload],
 * after a successful check. Installing only ever starts because the person asked. A
 * download must match the feed's size and SHA-256, and be this app — same package,
 * same signing certificates — at exactly the announced, strictly newer version.
 * Those checks are repeated just before Android's installer takes the file; Android
 * then verifies the signature itself and asks the person to confirm.
 *
 * Public methods are meant for the main thread; work runs on [scope].
 */
class AppUpdater(
    /** The feed fixed at build time, for servers that predate discovery; null if none. */
    private val builtIn: UpdateSource?,
    private val channel: String,
    private val fetcherFor: (UpdateSource) -> UpdateFetcher,
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
    /** Null leaves servers out: only [builtIn] is ever used. */
    private val discovery: ServerDiscovery? = null,
    /** The Shelfarr server to ask, signed in or last signed in to; null when there is none. */
    private val server: () -> ServerAddress? = { null },
    /** Whether a successful check may start downloading a new release on its own. */
    private val autoDownload: () -> Boolean = { false },
) {
    private val packageName: String by lazy { inspector.installed().packageName }
    private val store = UpdateStore(File(directory, STATE_FILE))

    val enabled: Boolean = builtIn != null || discovery != null

    private val mutableState = MutableStateFlow<UpdateState>(if (enabled) UpdateState.Idle() else UpdateState.Disabled)
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

    /** The feed the current state belongs to. Guarded by [lock]. */
    private var binding: UpdateBinding? = null

    /** Which feed the current state belongs to, for display and tests. */
    val currentBinding: UpdateBinding? get() = synchronized(lock) { binding }

    private fun expectation(source: UpdateSource) = FeedExpectation(source, channel, packageName)

    private fun context(): String? = server()?.identity

    /** Restores what an earlier process left: a verified download, an open session, a finished update. */
    fun start(): Job? {
        if (!enabled) return null
        return synchronized(lock) {
            restoring ?: scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) { restore() }.also {
                restoring = it
                it.start()
            }
        }
    }

    /** The binding an earlier process saved. State from before discovery belongs to the built-in feed. */
    private fun savedBinding(saved: SavedUpdate): UpdateBinding? {
        if (saved.feedKind == null && saved.feedUrl == null) {
            return builtIn?.let { UpdateBinding(it, saved.feedServer, null) }
        }
        val kind = when (saved.feedKind) {
            KIND_BUILT_IN -> UpdateSource.Kind.BUILT_IN
            KIND_SERVER -> UpdateSource.Kind.SERVER
            else -> return null
        }
        val feed = saved.feedUrl ?: return null
        val source = UpdateSource.restore(kind, feed, saved.feedServer?.let(ServerAddress::restore)) ?: return null
        // The built-in feed may only be the one this build has.
        if (kind == UpdateSource.Kind.BUILT_IN && source != builtIn) return null
        return UpdateBinding(source, saved.feedServer, saved.serverApiVersions?.toSet())
    }

    private fun restore() {
        val saved = store.read()
        val installed = inspector.installed()
        val savedBinding = savedBinding(saved)
        val release = savedBinding?.let { bound ->
            saved.release?.let { text ->
                try {
                    UpdateManifest.parse(text, expectation(bound.source))
                } catch (_: UpdateException) {
                    null
                }
            }
        }
        val artifact = saved.artifact?.let { File(directory, it) }?.takeIf { it.parentFile == directory }
        val sessionOpen = saved.sessionId?.let(installer::isOpen) == true
        installer.abandonOthers(keep = saved.sessionId.takeIf { sessionOpen })
        // Only state chosen for the server in use now carries on.
        val current = savedBinding != null && savedBinding.context == context()
        synchronized(lock) {
            lastAttemptAtMs = saved.lastAttemptAtMs.takeIf { current }
            lastCheckedAtMs = saved.lastCheckedAtMs.takeIf { current }
            binding = savedBinding.takeIf { current }
            val next: UpdateState = when {
                release == null || release.versionCode <= installed.versionCode -> {
                    val updated = release != null && (saved.artifact != null || saved.sessionId != null)
                    if (sessionOpen) installer.abandon(saved.sessionId)
                    UpdateState.Idle(
                        lastCheckedAtMs = lastCheckedAtMs,
                        notice = if (updated) "Updated to ${installed.versionName ?: "the new version"}" else null,
                    )
                }
                // Android is installing it already: leave that alone, whichever server is in use.
                sessionOpen -> {
                    binding = savedBinding
                    activeSession = saved.sessionId
                    UpdateState.Installing(release)
                }
                !current -> UpdateState.Idle()
                artifact != null && artifact.isFile && artifact.length() == release.sizeBytes -> UpdateState.Ready(
                    release,
                    notice = if (saved.sessionId != null) "The last installation didn't finish" else null,
                )
                else -> UpdateState.Available(release)
            }
            persistBinding()
            persist(next, lastCheckedAtMs)
            mutableState.value = next
            sweep()
        }
    }

    /** A check when one is due. Call as the app comes to the foreground. */
    fun onForeground() {
        if (!enabled) return
        scope.launch {
            restoring?.join()
            reconcileInstalling()
            if (isCheckDue()) check(manual = false)
        }
    }

    /**
     * The signed-in server changed, or the app signed out. Whatever was offered or
     * downloading for the previous one is dropped and the new one is asked, unless
     * Android is installing an update already.
     */
    fun onServerChanged() {
        if (!enabled) return
        scope.launch {
            restoring?.join()
            val context = context()
            synchronized(lock) {
                val bound = binding
                if (bound != null && bound.context == context) return@launch
                if (bound == null && mutableState.value.release == null && checkJob?.isActive != true) {
                    lastCheckedAtMs = null
                    lastAttemptAtMs = null
                } else {
                    if (mutableState.value is UpdateState.Installing) return@launch
                    unbind()
                }
            }
            check(manual = false)
        }
    }

    /** Drops the state of the current feed. Holds [lock]. */
    private fun unbind() {
        checkJob?.cancel()
        checkJob = null
        downloadJob?.cancel()
        downloadJob = null
        downloadPartial = null
        binding = null
        lastCheckedAtMs = null
        lastAttemptAtMs = null
        val next = UpdateState.Idle()
        persistBinding()
        persist(next)
        store.update { it.copy(lastCheckedAtMs = null, lastAttemptAtMs = null) }
        mutableState.value = next
        sweep()
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
        if (!enabled) return
        scope.launch {
            restoring?.join()
            check(manual = true)
        }
    }

    private sealed interface Choice {
        data class Bound(val binding: UpdateBinding) : Choice
        data class Unavailable(val reason: String) : Choice
    }

    private sealed interface Outcome {
        data class Offered(val binding: UpdateBinding, val release: UpdateRelease) : Outcome
        data class Unavailable(val reason: String) : Outcome
        data class Failed(val message: String) : Outcome
    }

    /**
     * Which feed to check for [server]. Throws when the server couldn't say and no feed
     * was chosen for it before; never falls back to another publisher on an error.
     */
    private suspend fun choose(server: ServerAddress?, previous: UpdateBinding?): Choice {
        val context = server?.identity
        fun builtInOr(reason: String) = builtIn?.let { Choice.Bound(UpdateBinding(it, context, null)) } ?: Choice.Unavailable(reason)
        val ask = discovery
        if (ask == null || server == null) return builtInOr("Connect to your Shelfarr server to check for updates")
        if (server.isCleartext) return builtInOr("${server.host} can only offer updates over https://")
        val described = try {
            ask.discover(server, channel)
        } catch (error: UpdateException) {
            val earlier = previous?.takeIf { it.context == context } ?: throw error
            Log.i(TAG, "Server discovery failed, keeping the feed chosen before: ${error.message}")
            return Choice.Bound(earlier)
        }
        return when (described) {
            ServerUpdates.NotOffered -> builtInOr("${server.host} doesn't offer app updates yet")
            is ServerUpdates.Described -> described.source?.let { Choice.Bound(UpdateBinding(it, context, described.apiVersions)) }
                ?: Choice.Unavailable("${server.host} doesn't offer ${channelLabel()} updates")
        }
    }

    private fun channelLabel(): String = if (channel == "release") "release" else "$channel build"

    private fun check(manual: Boolean) {
        synchronized(lock) {
            if (checkJob?.isActive == true || downloadJob?.isActive == true || installJob?.isActive == true) return
            if (mutableState.value is UpdateState.Installing) return
            val now = clock()
            lastAttemptAtMs = now
            store.update { it.copy(lastAttemptAtMs = now) }
            (mutableState.value as? UpdateState.Idle)?.let {
                mutableState.value = it.copy(checking = true, problem = null, notice = if (manual) null else it.notice)
            }
            val previous = binding
            val job = scope.launch(start = CoroutineStart.LAZY) {
                val asked = server()
                val outcome: Outcome = try {
                    when (val choice = choose(asked, previous)) {
                        is Choice.Unavailable -> Outcome.Unavailable(choice.reason)
                        is Choice.Bound -> {
                            val source = choice.binding.source
                            Outcome.Offered(choice.binding, UpdateManifest.parse(fetcherFor(source).fetchFeed(), expectation(source)))
                        }
                    }
                } catch (error: UpdateException) {
                    Log.i(TAG, "Update check failed: ${error.message}")
                    Outcome.Failed(error.message ?: "Couldn't check for updates")
                }
                synchronized(lock) {
                    if (checkJob != coroutineContext[Job]) return@launch
                    checkJob = null
                    // The account changed while this check ran: its answer is for the wrong server.
                    if (server()?.identity != asked?.identity) {
                        (mutableState.value as? UpdateState.Idle)?.let { mutableState.value = it.copy(checking = false) }
                        return@launch
                    }
                    when (outcome) {
                        is Outcome.Offered -> {
                            val earlier = binding
                            // A different feed, or the same feed chosen for another server: start afresh.
                            if (earlier != null && (earlier.source != outcome.binding.source || earlier.context != outcome.binding.context)) unbind()
                            if (outcome.binding != binding) {
                                binding = outcome.binding
                                persistBinding()
                            }
                            offer(outcome.release, outcome.binding)
                        }
                        is Outcome.Unavailable -> {
                            if (binding != null || mutableState.value.release != null) unbind()
                            val checkedAt = clock()
                            lastCheckedAtMs = checkedAt
                            val next = UpdateState.Idle(lastCheckedAtMs = checkedAt, problem = outcome.reason.takeIf { manual })
                            persist(next, checkedAt)
                            mutableState.value = next
                        }
                        is Outcome.Failed -> failed(outcome.message, manual)
                    }
                    sweep()
                }
            }
            checkJob = job
            job.start()
        }
    }

    /** Applies a freshly checked release from [bound]. Holds [lock]. */
    private fun offer(release: UpdateRelease, bound: UpdateBinding) {
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
            !release.worksWith(bound.serverApiVersions ?: setOf(ConsumerApiGenerations.ORIGINAL)) -> UpdateState.Idle(
                lastCheckedAtMs = now,
                problem = "Version ${release.versionName} needs a newer Shelfarr server",
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
        if (next is UpdateState.Available && autoDownload()) {
            Log.i(TAG, "Downloading version ${release.versionName} automatically")
            download()
        }
    }

    /** Holds [lock]. Automatic checks fail quietly; only an asked-for check reports. */
    private fun failed(message: String, manual: Boolean) {
        val current = mutableState.value
        if (current is UpdateState.Idle) {
            mutableState.value = current.copy(checking = false, problem = if (manual) message else current.problem)
        }
    }

    /** Downloads the available release, because the person asked or allowed it ([autoDownload]). */
    fun download() {
        synchronized(lock) {
            val current = mutableState.value as? UpdateState.Available ?: return
            if (downloadJob?.isActive == true) return
            val fetch = binding?.source?.let(fetcherFor) ?: return
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
            // A committed Android session may finish after the server changed.
            // Its old release must never become actionable for that new server.
            if (discardStaleOffer(release)) return InstallRequest.IGNORED
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
                settleInstallation(next)
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
            settleInstallation(next)
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
            settleInstallation(next)
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
            settleInstallation(next)
        }
    }

    /** An installer may have deferred a server change. Holds [lock]. */
    private fun settleInstallation(next: UpdateState) {
        if (discardStaleOffer(next.release)) return
        persist(next)
        mutableState.value = next
    }

    /** Drops a previous server's offer and immediately asks the current one. Holds [lock]. */
    private fun discardStaleOffer(release: UpdateRelease?): Boolean {
        val bound = binding
        if (bound != null && bound.context == context() &&
            (release == null || release.worksWith(bound.serverApiVersions ?: setOf(ConsumerApiGenerations.ORIGINAL)))
        ) return false
        unbind()
        check(manual = false)
        return true
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

    /** Saves which feed the state belongs to. Holds [lock] or runs before others can. */
    private fun persistBinding() {
        val bound = binding
        store.update { saved ->
            saved.copy(
                feedKind = bound?.source?.kind?.let { if (it == UpdateSource.Kind.SERVER) KIND_SERVER else KIND_BUILT_IN } ?: KIND_NONE,
                feedUrl = bound?.source?.feed?.toString(),
                feedServer = bound?.context,
                serverApiVersions = bound?.serverApiVersions?.sorted(),
            )
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
        private const val KIND_BUILT_IN = "built_in"
        private const val KIND_SERVER = "server"
        private const val KIND_NONE = "none"
        const val AUTO_CHECK_INTERVAL_MS = 6L * 60 * 60 * 1_000
        const val RETRY_INTERVAL_MS = 30L * 60 * 1_000
        private const val SPACE_MARGIN_BYTES = 32L * 1024 * 1024
    }
}
