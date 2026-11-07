package org.shelfarr.app

import android.content.Context
import android.content.SharedPreferences
import coil3.ImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import org.shelfarr.app.core.ApiException
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
import org.shelfarr.app.ui.theme.AppearanceMode

/** Everything tied to one signed-in account. Replaced wholesale when the account changes. */
class AccountServices(
    val session: Session,
    val api: ConsumerApi,
    val progress: ProgressRegistry,
    val downloads: DownloadManager,
    val directory: File,
    private val store: FileProgressStore,
    private val scope: CoroutineScope,
) {
    /** Stops transfers, timers and writes; the caller may then delete [directory]. */
    suspend fun close() {
        downloads.close()
        scope.cancel()
        store.close()
    }

    /**
     * Best effort: an explicit Read or Listen marks an unread publication in progress.
     * It never blocks opening, and never changes a finished status.
     */
    fun markStarted(publication: Publication) {
        if (publication.status != ReadingStatus.UNREAD) return
        scope.launch {
            try {
                api.setReadingStatus(session.server, publication.id, ReadingStatus.IN_PROGRESS)
            } catch (_: ApiException) {
                // Offline or refused: the saved place still records the reading.
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
            sessions.session.collect {
                val live = sessions.signedIn
                val previous = synchronized(this@AppContainer) {
                    account?.takeIf { !it.session.hasSameAccountAndToken(live) }?.also { account = null }
                }
                if (previous != null) previous.close()
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
        val downloads = DownloadManager(
            root = File(directory, "downloads"),
            client = accountClient,
            server = session.server,
            fetchPublication = { id ->
                if (!session.hasSameAccountAndToken(sessions.signedIn)) throw ApiException.Unauthorized()
                accountApi.publication(session.server, id)
            },
            scope = accountScope,
        )
        accountScope.launch {
            closing?.join()
            downloads.start()
        }
        return AccountServices(session, accountApi, registry, downloads, directory, store, accountScope).also { account = it }
    }

    fun currentAccount(): AccountServices? = sessions.signedIn?.let(::account)

    fun setAppearance(mode: AppearanceMode) {
        preferences.edit().putInt(KEY_APPEARANCE, mode.ordinal).apply()
        appearanceState.value = mode
    }

    fun onForeground() {
        val current = currentAccount() ?: return
        scope.launch {
            current.progress.flushAll()
            current.downloads.retryInterrupted()
            try {
                sessions.refreshUser(current.api.me(current.session.server), current.session)
            } catch (_: ApiException) {
                // Offline is fine and a 401 was already handled by the HTTP stack.
            }
        }
    }

    fun onBackground() {
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
        sessions.clear()
        if (session != null) {
            epubCache.clear(session.accountKey)
            current?.directory?.deleteRecursively()
        }
        synchronized(this) { account = null }
        imageLoader.memoryCache?.clear()
        imageLoader.diskCache?.clear()
    }

    private companion object {
        const val KEY_APPEARANCE = "appearance"
        const val NETWORK_GRACE_MS = 5_000L
    }
}
