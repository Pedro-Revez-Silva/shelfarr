package org.shelfarr.app

import android.content.Context
import android.content.SharedPreferences
import coil3.ImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import java.io.File
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import org.shelfarr.app.core.AccountPublications
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.LibraryCache
import org.shelfarr.app.core.LibraryPage
import org.shelfarr.app.core.LibraryQuery
import org.shelfarr.app.core.NetworkMonitor
import org.shelfarr.app.core.OfflineLibraryResult
import org.shelfarr.app.core.SessionState
import org.shelfarr.app.core.ConsumerApi
import org.shelfarr.app.core.Credential
import org.shelfarr.app.core.DeviceAuthorizer
import org.shelfarr.app.core.DownloadManager
import org.shelfarr.app.core.Publication
import org.shelfarr.app.core.ReadingStatus
import org.shelfarr.app.core.EpubCache
import org.shelfarr.app.core.FileProgressStore
import org.shelfarr.app.core.KeystoreSecureStore
import org.shelfarr.app.core.ProgressRegistry
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionManager
import org.shelfarr.app.core.buildHttpClient
import org.shelfarr.app.playback.PlaybackController
import org.shelfarr.app.reader.ReaderSettingsStore
import org.shelfarr.app.transfer.DownloadActionReceiver
import org.shelfarr.app.transfer.TransferAccount
import org.shelfarr.app.transfer.TransferNotifications
import org.shelfarr.app.transfer.TransferScheduler
import org.shelfarr.app.ui.theme.AppearanceMode

/** Everything tied to one signed-in account. Replaced wholesale when the account changes. */
class AccountServices(
    val session: Session,
    val api: ConsumerApi,
    val progress: ProgressRegistry,
    override val downloads: DownloadManager,
    val directory: File,
    /** Metadata this device has seen, for browsing the library offline. */
    val titles: LibraryCache,
    private val store: FileProgressStore,
    private val scope: CoroutineScope,
    /** Completes once downloads are loaded and reconciled with the OS hosts. */
    val ready: Job,
    private val clock: () -> Long = System::currentTimeMillis,
) : TransferAccount {
    override val accountKey: String get() = session.accountKey

    /**
     * Stops transfers, timers and writes; the caller may then delete [directory].
     * [signedOut] keeps unfinished downloads ready to resume on the same account.
     */
    suspend fun close(signedOut: Boolean = false) {
        downloads.close(signedOut)
        titles.close()
        scope.cancel()
        store.close()
    }

    /** One library page, remembered for offline browsing. */
    suspend fun libraryPage(query: LibraryQuery, cursor: String?): LibraryPage {
        val observedAt = clock()
        return api.library(session.server, query, cursor).also { titles.recordPage(query, cursor, it, observedAt) }
    }

    suspend fun publication(id: String): Publication {
        val observedAt = clock()
        return api.publication(session.server, id).also { titles.remember(it, observedAt) }
    }

    suspend fun continueReading(limit: Int): List<Publication> {
        val observedAt = clock()
        return api.continueReading(session.server, limit).also { titles.rememberAll(it, observedAt) }
    }

    /** Needs the server; the cached copy changes only once it has accepted the status. */
    suspend fun setReadingStatus(id: String, status: ReadingStatus): Publication {
        val observedAt = clock()
        return api.setReadingStatus(session.server, id, status).also { titles.remember(it, observedAt) }
    }

    /** What this device can show for [query] without a connection, downloads included. */
    suspend fun offlineLibrary(query: LibraryQuery): OfflineLibraryResult =
        titles.query(query, downloads.records.value.values.map { it.publication })

    /** Last details seen for [id]: the download's pinned copy if newer data is missing. */
    suspend fun recall(id: String): Publication? = titles.recall(id) ?: downloads.find(id)?.publication

    /**
     * Best effort: an explicit Read or Listen marks an unread publication in progress.
     * It never blocks opening, and never changes a finished status.
     */
    fun markStarted(publication: Publication) {
        if (publication.status != ReadingStatus.UNREAD) return
        scope.launch {
            try {
                setReadingStatus(publication.id, ReadingStatus.IN_PROGRESS)
            } catch (error: ApiException) {
                // Offline or refused: the saved place still records the reading.
                Log.i("ShelfarrAccount", "Could not mark a title in progress: ${error.message}")
            }
        }
    }
}

/** Hand-rolled dependency graph; the app is small enough not to need a framework. */
class AppContainer(context: Context) {
    private val appContext = context.applicationContext
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val sessions = SessionManager(KeystoreSecureStore(appContext))
    val httpClient: OkHttpClient = buildHttpClient(sessions) { rejected -> sessions.markExpired(rejected) }
    val api = ConsumerApi(httpClient)
    val authorizer = DeviceAuthorizer(api)
    val epubCache = EpubCache(File(appContext.cacheDir, "epub"), httpClient)
    val playback = PlaybackController(appContext, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))

    // Display preferences only. No credential or identifier belongs here.
    private val preferences: SharedPreferences = appContext.getSharedPreferences("preferences", Context.MODE_PRIVATE)
    val readerSettings = ReaderSettingsStore(preferences)

    /** True while one of the app's screens is visible, which is when Android lets it start user-initiated work. */
    @Volatile
    var isVisible: Boolean = false
        private set

    val network = NetworkMonitor(appContext)
    val transferNotifications = TransferNotifications(appContext).apply { ensureChannel() }
    val transfers = TransferScheduler(appContext, { isVisible }, preferences)

    private val accountState = MutableStateFlow<AccountServices?>(null)

    /** The live account's services, for OS hosts that must follow account changes. */
    val transferAccounts: StateFlow<TransferAccount?> = accountState

    /** Whether the first download prompt for notifications has been shown. */
    var askedForNotifications: Boolean
        get() = preferences.getBoolean(KEY_ASKED_NOTIFICATIONS, false)
        set(value) = preferences.edit().putBoolean(KEY_ASKED_NOTIFICATIONS, value).apply()

    private val appearanceState = MutableStateFlow(
        AppearanceMode.entries.getOrElse(preferences.getInt(KEY_APPEARANCE, 0)) { AppearanceMode.SYSTEM },
    )
    val appearance: StateFlow<AppearanceMode> = appearanceState.asStateFlow()

    val imageLoader: ImageLoader by lazy {
        ImageLoader.Builder(appContext)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { httpClient })) }
            .diskCache {
                DiskCache.Builder()
                    .directory(File(appContext.cacheDir, "covers"))
                    .maxSizeBytes(128L * 1024 * 1024)
                    .build()
            }
            .crossfade(true)
            .build()
    }

    private var account: AccountServices? = null

    init {
        // Streams can't continue without a session, so don't leave a dead player behind.
        scope.launch {
            sessions.session.collect { state ->
                val live = sessions.signedIn
                val previous = synchronized(this@AppContainer) {
                    account?.takeIf { !it.session.hasSameAccountAndToken(live) }?.also {
                        account = null
                        accountState.value = null
                    }
                }
                // An expired sign-in keeps this account's downloads, recorded so they resume after signing in again.
                val expired = state is SessionState.Expired && previous != null && state.server == previous.session.server
                if (previous != null) previous.close(signedOut = expired)
                if (live == null || previous != null) playback.stop()
                // Resume this account's unfinished downloads as soon as it is signed in.
                if (live != null) account(live)
            }
        }
    }

    /** The services for the live session, built on first use. */
    @Synchronized
    fun account(session: Session): AccountServices {
        account?.takeIf { it.session.hasSameAccountAndToken(session) }?.let { return it }
        // The next account's downloads wait until the previous transfers have stopped.
        val closing = account?.let { previous -> scope.launch { previous.close() } }
        val accountScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val directory = File(appContext.filesDir, "accounts/${session.accountKey}")
        val store = FileProgressStore(File(directory, "progress.json"))
        // Bound to this account's credential, so its retries and downloads can't borrow another token.
        val accountClient = buildHttpClient({ Credential(session.server, session.accessToken) }) { sessions.markExpired(it) }
        val accountApi = ConsumerApi(accountClient)
        val registry = ProgressRegistry(
            store = store,
            remote = { id, update ->
                if (!session.hasSameAccountAndToken(sessions.signedIn)) throw ApiException.Unauthorized()
                accountApi.saveProgress(session.server, id, update)
            },
            scope = accountScope,
        )
        lateinit var downloads: DownloadManager
        downloads = DownloadManager(
            root = File(directory, "downloads"),
            client = accountClient,
            server = session.server,
            fetchPublication = { id ->
                if (!session.hasSameAccountAndToken(sessions.signedIn)) throw ApiException.Unauthorized()
                accountApi.publication(session.server, id)
            },
            scope = accountScope,
            // The record is on disk by now, so a host started in a new process finds it.
            onQueued = { transfers.request(downloads.remainingBytes) },
        )
        val titles = LibraryCache(
            file = File(directory, "library.json"),
            scope = accountScope,
            protectedIds = { downloads.records.value.keys },
            legacy = AccountPublications(directory),
        )
        val ready = accountScope.launch {
            closing?.join()
            downloads.start()
            // Nothing will continue an earlier process's downloads: say so rather than restart them unasked.
            if (!transfers.hasScheduledWork()) downloads.interruptInherited()
            downloads.resumeAfterSignIn()
        }
        return AccountServices(session, accountApi, registry, downloads, directory, titles, store, accountScope, ready)
            .also {
                account = it
                accountState.value = it
            }
    }

    fun currentAccount(): AccountServices? = sessions.signedIn?.let(::account)

    fun setAppearance(mode: AppearanceMode) {
        preferences.edit().putInt(KEY_APPEARANCE, mode.ordinal).apply()
        appearanceState.value = mode
    }

    /**
     * Cancels downloads from a notification, only if [accountKey] is still the signed-in
     * account. Cancelling never needs the network or the token.
     */
    suspend fun cancelDownloads(accountKey: String?, ids: List<String>) {
        val current = currentAccount()
        if (current == null || current.accountKey != accountKey) {
            DownloadActionReceiver.logIgnored()
            return
        }
        ids.forEach { current.downloads.cancel(it) }
    }

    fun onForeground() {
        isVisible = true
        val current = currentAccount() ?: return
        scope.launch {
            current.progress.flushAll()
            // Let a cold start decide what an earlier process left behind before asking for a host.
            current.ready.join()
            current.downloads.retryInterrupted()
            // Visible now, so Android allows upgrading to a user-initiated transfer.
            if (current.downloads.hasActiveWork) transfers.request(current.downloads.remainingBytes)
            try {
                sessions.refreshUser(current.api.me(current.session.server), current.session)
            } catch (_: ApiException) {
                // Offline is fine and a 401 was already handled by the HTTP stack.
            }
        }
    }

    fun onBackground() {
        isVisible = false
        val current = currentAccount() ?: return
        scope.launch { current.progress.flushAll() }
    }

    /**
     * Disconnects this device: last sync, server-side revoke, then every local trace.
     * Local cleanup happens whether or not the server could be reached. This runs on
     * the app scope because signing out tears down the screen that asked for it.
     */
    fun disconnect() {
        scope.launch { forgetAccount() }
    }

    private suspend fun forgetAccount() {
        val session = sessions.signedIn
        val current = session?.let(::account)
        withTimeoutOrNull(NETWORK_GRACE_MS) {
            playback.stop()
            try {
                current?.progress?.flushAll()
                session?.let { api.revoke(it.server) }
            } catch (_: ApiException) {
                // The token is deleted below regardless; expiry covers the rest.
            }
        }
        current?.close()
        transfers.cancel()
        transferNotifications.cancelProgress()
        sessions.clear()
        if (session != null) {
            epubCache.clear(session.accountKey)
            current?.directory?.deleteRecursively()
        }
        synchronized(this) {
            account = null
            accountState.value = null
        }
        imageLoader.memoryCache?.clear()
        imageLoader.diskCache?.clear()
    }

    private companion object {
        const val KEY_APPEARANCE = "appearance"
        const val KEY_ASKED_NOTIFICATIONS = "asked_notifications"
        const val NETWORK_GRACE_MS = 5_000L
    }
}
