package org.shelfarr.app.core

import android.util.Log
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

@Serializable
enum class DownloadState { QUEUED, DOWNLOADING, READY, FAILED, CANCELLED }

/** Why a download stopped. Each needs different words and a different fix. */
@Serializable
enum class DownloadProblem {
    /** No connection. Retried automatically when the app returns to the foreground. */
    OFFLINE,

    /** The server's certificate could not be trusted. Never retried silently. */
    CERTIFICATE,

    /** The sign-in ended. Resumes after signing in to the same account again. */
    SIGN_IN,
    FORBIDDEN,
    NOT_FOUND,
    SERVER,
    REDIRECT,

    /** The file on the server changed under the pinned edition. Nothing was overwritten. */
    CHANGED,

    /** The server sent something that isn't the expected file. */
    INVALID,

    /** Not enough space, or the device refused the write. */
    STORAGE,

    /** Files that were complete are no longer on the device. */
    MISSING,

    /** The publication has no file this app can download and open. */
    UNSUPPORTED,

    /**
     * The app stopped before it finished and nothing was scheduled to continue it, for
     * example after a force stop or a Task Manager stop. Kept bytes resume on request.
     */
    INTERRUPTED,
}

/** One pinned asset of a managed download. */
@Serializable
data class DownloadedFile(
    val assetId: String,
    /** Local file name inside the publication's folder. */
    val name: String,
    val sizeBytes: Long,
    /** The strong validator the first response carried, used for safe resumption. */
    val etag: String? = null,
    val complete: Boolean = false,
    /** Bytes on disk, kept current in memory; recomputed from disk on load. */
    val bytesDone: Long = 0,
)

/** Where a book's read-along narration download is. The book itself is tracked by [DownloadRecord.state]. */
@Serializable
enum class NarrationState { QUEUED, DOWNLOADING, READY, FAILED }

/**
 * Read-along narration kept with a book: one manifest generation, its exact manifest
 * bytes and every narration file it names. Usable only once all of them are complete.
 */
@Serializable
data class NarrationDownload(
    val generation: String,
    val source: String,
    /** The stored manifest's file name in the publication's folder. */
    val manifest: String,
    /** In the manifest's audio order. [DownloadedFile.assetId] is this download's own track id. */
    val tracks: List<DownloadedFile>,
    val state: NarrationState = NarrationState.QUEUED,
    val problem: DownloadProblem? = null,
) {
    val isReady: Boolean get() = state == NarrationState.READY && tracks.isNotEmpty() && tracks.all { it.complete }
    val isActive: Boolean get() = state == NarrationState.QUEUED || state == NarrationState.DOWNLOADING
    val bytesTotal: Long get() = tracks.sumOf { it.sizeBytes.coerceAtLeast(0) }
    val bytesDone: Long get() = tracks.sumOf { if (it.complete) it.sizeBytes.coerceAtLeast(it.bytesDone) else it.bytesDone }
}

/** A ready narration download's files, checked on disk, for playing offline. */
data class LocalNarration(val generation: String, val manifest: File, val tracks: List<File>)

/**
 * A publication kept on this device by the user's choice. It pins one edition: the
 * exact asset ids it was started with. It is only [DownloadState.READY] once every
 * pinned file is complete and verified.
 *
 * A book with read-along may also keep its narration ([narration]). That never changes
 * whether the book itself is ready: the EPUB reads offline as soon as it is complete, and a
 * failed or updating narration download leaves the book, and any complete earlier
 * narration, exactly as usable as before.
 */
@Serializable
data class DownloadRecord(
    val publicationId: String,
    val publication: Publication,
    val files: List<DownloadedFile>,
    val state: DownloadState,
    val problem: DownloadProblem? = null,
    val updatedAtEpochMs: Long = 0,
    /**
     * The reading format a book's download keeps (`epub`, `pdf` or `cbz`). Absent from
     * records written before PDF and CBZ, which are worked out from the pinned file.
     */
    val format: String? = null,
    /** The person asked to keep this book's read-along narration too. */
    val withNarration: Boolean = false,
    /** Narration for one generation: ready, or being fetched for the first time. */
    val narration: NarrationDownload? = null,
    /** A newer generation being fetched while a complete [narration] stays in use. */
    val narrationUpdate: NarrationDownload? = null,
    /**
     * Narration was asked for and the server's current generation hasn't been checked yet.
     * It stays set until that check settles it, so the request survives a stop, a restart or
     * an expired sign-in before any narration work exists.
     */
    val narrationPending: Boolean = false,
    /**
     * Why a pending narration request stopped before its manifest was pinned (interrupted,
     * signed out, offline, …), so it can be resumed like any other download. Null while it
     * waits or runs. Once work is pinned, its own [NarrationDownload.problem] says why instead.
     */
    val narrationProblem: DownloadProblem? = null,
) {
    val pinnedAssetIds: List<String> get() = files.map { it.assetId }

    /** The narration download that is being worked on, if any. */
    val narrationWork: NarrationDownload?
        get() = narrationUpdate ?: narration?.takeUnless { it.isReady }

    /** Narration was asked for but nothing is pinned yet: the server's generation is still to be checked. */
    val narrationRequested: Boolean get() = narrationPending && narrationWork == null

    val narrationActive: Boolean get() = narrationWork?.isActive == true || (narrationRequested && narrationProblem == null)

    /** The book format this download follows across editions. Null for audiobooks. */
    val pinnedFormat: ReadingFormat?
        get() {
            if (publication.bookType != BookType.EBOOK) return null
            ReadingFormat.fromWire(format)?.let { return it }
            val first = files.firstOrNull()?.assetId
            return publication.assets.firstOrNull { it.id == first }?.declaredFormat ?: ReadingFormat.EPUB
        }

    /** Null when the server didn't state every size, so no honest total exists. */
    val bytesTotal: Long?
        get() = if (files.any { it.sizeBytes <= 0 }) null else files.sumOf { it.sizeBytes } + narrationBytes { it.bytesTotal }

    val bytesDone: Long
        get() = files.sumOf { if (it.complete) it.sizeBytes.coerceAtLeast(it.bytesDone) else it.bytesDone } + narrationBytes { it.bytesDone }

    private inline fun narrationBytes(measure: (NarrationDownload) -> Long): Long =
        (narration?.let(measure) ?: 0L) + (narrationUpdate?.let(measure) ?: 0L)

    val fraction: Float? get() = bytesTotal?.takeIf { it > 0 }?.let { (bytesDone.toFloat() / it).coerceIn(0f, 1f) }

    val isReady: Boolean get() = state == DownloadState.READY

    /** Transferring or waiting to: the book's files, or its narration after the book is ready. */
    val isActive: Boolean
        get() = state == DownloadState.QUEUED || state == DownloadState.DOWNLOADING || (state == DownloadState.READY && narrationActive)

    /** Stops whatever is active for [problem]: the book when it isn't ready, otherwise only its narration. */
    internal fun stopped(problem: DownloadProblem, at: Long): DownloadRecord = when {
        state == DownloadState.QUEUED || state == DownloadState.DOWNLOADING ->
            copy(state = DownloadState.FAILED, problem = problem, updatedAtEpochMs = at)
        // Stopped before its manifest was pinned: the request and why it stopped are kept.
        narrationActive && narrationWork == null -> copy(narrationProblem = problem, updatedAtEpochMs = at)
        narrationActive -> withNarrationWork { it.copy(state = NarrationState.FAILED, problem = problem) }
            .copy(updatedAtEpochMs = at, narrationPending = false, narrationProblem = null)
        else -> this
    }

    /** Back to waiting for a host, keeping every byte. */
    internal fun requeued(): DownloadRecord = when {
        state == DownloadState.DOWNLOADING || state == DownloadState.QUEUED -> copy(state = DownloadState.QUEUED)
        narrationActive -> withNarrationWork { it.copy(state = NarrationState.QUEUED) }
        else -> this
    }

    /** True when narration stopped for [problems], so it may be resumed like the book's own files. */
    internal fun narrationFailedFor(problems: Set<DownloadProblem>): Boolean =
        state == DownloadState.READY && (
            narrationWork?.let { it.state == NarrationState.FAILED && it.problem in problems } == true ||
                (narrationRequested && narrationProblem in problems)
            )

    /** Narration stopped (pinned work failed, or a request stopped before pinning), with why. */
    val narrationStopProblem: DownloadProblem?
        get() = when {
            state != DownloadState.READY -> null
            narrationRequested -> narrationProblem
            else -> narrationWork?.takeIf { it.state == NarrationState.FAILED }?.let { it.problem ?: DownloadProblem.INVALID }
        }

    /** Narration asked for again: stopped work and a stopped request both go back to waiting. */
    internal fun narrationRetried(): DownloadRecord =
        withNarrationWork { it.copy(state = NarrationState.QUEUED, problem = null) }.copy(narrationProblem = null)

    internal fun withNarrationWork(transform: (NarrationDownload) -> NarrationDownload): DownloadRecord = when {
        narrationUpdate != null -> copy(narrationUpdate = transform(narrationUpdate))
        narration != null && !narration.isReady -> copy(narration = transform(narration))
        else -> this
    }

    /** True when [current] is the same edition, in the same format, as this download pinned. */
    fun matches(current: Publication): Boolean = downloadableAssets(current, pinnedFormat).map { it.id } == pinnedAssetIds
}

/**
 * Every file a download needs: one reading file for a book, all audio files in order
 * for an audiobook. A book keeps [format] when its edition has it; without one, the
 * format of the saved place, then EPUB (as before PDF and CBZ), then the first file.
 */
fun downloadableAssets(publication: Publication, format: ReadingFormat? = null): List<Asset> {
    if (publication.bookType != BookType.EBOOK) return publication.audioAssets
    val readable = publication.readingAssets
    if (format != null) return listOfNotNull(readable.firstOrNull { it.readingFormat == format })
    return listOfNotNull(defaultReadingAsset(publication))
}

/** The file a book opens or downloads when nothing more specific was chosen. */
fun defaultReadingAsset(publication: Publication): Asset? {
    val readable = publication.readingAssets
    return readable.firstOrNull { it.id == publication.progress?.assetId }
        ?: readable.firstOrNull { it.readingFormat == ReadingFormat.EPUB }
        ?: readable.firstOrNull()
}

private class EditionChanged : Exception("The pinned file changed on the server")
private class StorageFailure(cause: IOException) : Exception("Could not write the download", cause)
private class Unsupported : Exception("Nothing to download")

/**
 * Managed downloads for one account: durable files in app storage, never the
 * evictable cache. This is the only code that writes download files; OS hosts
 * (a user-initiated job, or a foreground service on older Android) only keep the
 * process alive and tell it when to [pause] and [resumeQueued].
 *
 * The queue is persisted before [onQueued] asks for a host, so a host that starts
 * in a fresh process always finds the work it was scheduled for.
 *
 * Every request goes through [client], which carries only this account's
 * credential. Closing stops every transfer before the caller deletes [root].
 */
class DownloadManager(
    private val root: File,
    private val client: OkHttpClient,
    private val server: ServerAddress,
    private val fetchPublication: suspend (String) -> Publication,
    private val scope: CoroutineScope,
    maxConcurrent: Int = 2,
    private val clock: () -> Long = System::currentTimeMillis,
    private val usableSpace: () -> Long = { root.apply { mkdirs() }.usableSpace },
    /** Called after a queued download is on disk, to ask the OS to keep transferring it. */
    private val onQueued: suspend () -> Unit = {},
) {
    private val manifestFile = File(root, "manifest.json")
    private val orders = ReadingOrderClient(client)
    private val api = ConsumerApi(client)
    private val manifestMutex = Mutex()
    private val permits = Semaphore(maxConcurrent)
    private val jobs = HashMap<String, Job>()
    private val jobsLock = Any()

    /**
     * Bumped whenever a book's narration is removed, or the book cancelled or removed. A
     * narration fetch started under an earlier epoch may no longer save, pin or promote
     * anything, even if it was suspended (fetching its manifest) when that happened.
     */
    private val narrationEpochs = HashMap<String, Int>()

    private fun narrationEpoch(publicationId: String): Int = synchronized(jobsLock) { narrationEpochs[publicationId] ?: 0 }

    private fun invalidateNarration(publicationId: String) = synchronized(jobsLock) {
        narrationEpochs[publicationId] = (narrationEpochs[publicationId] ?: 0) + 1
    }

    @Volatile
    private var closed = false

    private val mutableRecords = MutableStateFlow<Map<String, DownloadRecord>>(emptyMap())
    val records: StateFlow<Map<String, DownloadRecord>> = mutableRecords.asStateFlow()

    private var loaded = false

    /** Set when the manifest exists but couldn't be read, so it must not be replaced. */
    @Volatile
    private var manifestUnreadable = false

    /** Downloads that were unfinished when the manifest was loaded, from an earlier process. */
    private val inherited = HashSet<String>()

    /** Loads the manifest and checks finished files are still there. Nothing transfers yet. */
    suspend fun start() {
        load()
    }

    /** True once any download is queued or transferring. */
    val hasActiveWork: Boolean get() = mutableRecords.value.values.any { it.isActive }

    /** Bytes still to fetch for queued and running downloads, for the OS's transfer estimate. */
    val remainingBytes: Long
        get() = mutableRecords.value.values.filter { it.isActive }.sumOf { record ->
            (record.files + record.narrationWork?.tracks.orEmpty()).filterNot { it.complete }
                .sumOf { (it.sizeBytes - it.bytesDone).coerceAtLeast(0) }
        }

    /**
     * Starts every queued download, for a host that may now transfer. Downloads that
     * stopped for a sign-in resume too: this account's services only exist while it is
     * signed in. Already running transfers are left alone.
     */
    suspend fun resumeQueued() {
        load()
        mutableRecords.value.values
            .filter { it.isActive || it.stoppedForSignIn }
            .forEach { launch(it.publicationId) }
    }

    /** Re-queues downloads that stopped because the account was signed out, now that it is back. */
    suspend fun resumeAfterSignIn() {
        load()
        mutableRecords.value.values
            .filter { it.stoppedForSignIn }
            .forEach { retry(it.publicationId) }
    }

    /**
     * Marks downloads left unfinished by an earlier process as interrupted, for when no
     * OS host is scheduled to continue them. Without a host, starting them silently
     * would undo a user's force stop; with one, the host resumes them instead.
     */
    suspend fun interruptInherited() {
        load()
        manifestMutex.withLock {
            val running = synchronized(jobsLock) { jobs.keys.toSet() }
            val stale = inherited.filter { id -> id !in running && mutableRecords.value[id]?.isActive == true }
            inherited.clear()
            if (stale.isEmpty()) return@withLock
            mutableRecords.update { records ->
                records + stale.associateWith { id -> records.getValue(id).stopped(DownloadProblem.INTERRUPTED, clock()) }
            }
            if (!persistLocked()) Log.w(TAG, "Could not record interrupted downloads")
        }
    }

    /**
     * Stops every transfer without discarding anything: partial files and their
     * validators stay, and each download goes back to the queue for the next host.
     * With [interrupted], nothing will come back for them, so they are marked
     * [DownloadProblem.INTERRUPTED] for the person to resume.
     */
    suspend fun pause(interrupted: Boolean = false) {
        val running = synchronized(jobsLock) { jobs.values.toList().also { jobs.clear() } }
        running.forEach { it.cancel() }
        running.forEach { it.join() }
        manifestMutex.withLock {
            if (closed) return@withLock
            mutableRecords.update { records ->
                records.mapValues { (_, record) ->
                    when {
                        !record.isActive -> record
                        interrupted -> record.stopped(DownloadProblem.INTERRUPTED, clock())
                        else -> record.requeued()
                    }
                }
            }
            if (!persistLocked()) Log.w(TAG, "Could not record paused downloads")
        }
    }

    private suspend fun load() = manifestMutex.withLock {
        if (loaded) return@withLock
        loaded = true
        val stored = withContext(Dispatchers.IO) { readManifest() }
        val checked = stored.mapValues { (_, record) -> withContext(Dispatchers.IO) { reconcile(record) } }
        inherited += checked.values.filter { it.isActive }.map { it.publicationId }
        mutableRecords.value = checked
        if (checked != stored && !persistLocked()) {
            mutableRecords.update { records -> records.mapValues { (_, record) ->
                if (record.isActive) record.stopped(DownloadProblem.STORAGE, record.updatedAtEpochMs) else record
            } }
        }
    }

    /** Recomputes sizes from disk and refuses to call missing or short files ready. */
    private fun reconcile(record: DownloadRecord): DownloadRecord {
        val folder = folder(record.publicationId)
        val files = record.files.map { file ->
            val final = File(folder, file.name)
            val partial = File(folder, file.name + PART)
            // A comic is only readable offline with its verified page order beside it.
            val orderPresent = !file.name.endsWith(".cbz") || File(folder, file.name + ORDER).isFile
            when {
                file.complete && final.isFile && (file.sizeBytes <= 0 || final.length() == file.sizeBytes) && orderPresent ->
                    file.copy(bytesDone = final.length())
                file.complete -> file.copy(complete = false, bytesDone = 0)
                else -> file.copy(bytesDone = if (partial.isFile) partial.length() else 0)
            }
        }
        val allComplete = files.isNotEmpty() && files.all { it.complete }
        val state = when {
            record.state == DownloadState.READY && !allComplete -> DownloadState.FAILED
            record.state == DownloadState.DOWNLOADING -> DownloadState.QUEUED
            else -> record.state
        }
        val problem = if (record.state == DownloadState.READY && !allComplete) DownloadProblem.MISSING else record.problem
        return record.copy(
            files = files,
            state = state,
            problem = problem,
            narration = record.narration?.let { reconcile(folder, it) },
            narrationUpdate = record.narrationUpdate?.let { reconcile(folder, it) },
        )
    }

    /** Narration is ready only while its manifest and every file are still on disk at their sizes. */
    private fun reconcile(folder: File, narration: NarrationDownload): NarrationDownload {
        val tracks = narration.tracks.map { file ->
            val final = File(folder, file.name)
            val partial = File(folder, file.name + PART)
            when {
                file.complete && final.isFile && final.length() == file.sizeBytes -> file.copy(bytesDone = final.length())
                file.complete -> file.copy(complete = false, bytesDone = 0)
                else -> file.copy(bytesDone = if (partial.isFile) partial.length() else 0)
            }
        }
        val manifestPresent = File(folder, narration.manifest).isFile
        val whole = manifestPresent && tracks.isNotEmpty() && tracks.all { it.complete }
        val state = when {
            narration.state == NarrationState.READY && !whole -> NarrationState.FAILED
            narration.state == NarrationState.DOWNLOADING -> NarrationState.QUEUED
            else -> narration.state
        }
        val problem = if (narration.state == NarrationState.READY && !whole) DownloadProblem.MISSING else narration.problem
        return narration.copy(tracks = tracks, state = state, problem = problem)
    }

    fun record(publicationId: String): DownloadRecord? = mutableRecords.value[publicationId]

    private val DownloadRecord.stoppedForSignIn: Boolean
        get() = (state == DownloadState.FAILED && problem == DownloadProblem.SIGN_IN) ||
            narrationFailedFor(setOf(DownloadProblem.SIGN_IN))

    /** Like [record], but waits for the manifest to load, for use straight after launch. */
    suspend fun find(publicationId: String): DownloadRecord? {
        load()
        return record(publicationId)
    }

    /** A finished download, or null. Partial downloads are never offered for reading. */
    fun ready(publicationId: String): DownloadRecord? = record(publicationId)?.takeIf { it.isReady }

    /** The verified local file for one pinned asset of a ready download. */
    fun fileFor(record: DownloadRecord, assetId: String): File? {
        if (!record.isReady) return null
        val pinned = record.files.firstOrNull { it.assetId == assetId && it.complete } ?: return null
        return File(folder(record.publicationId), pinned.name).takeIf { it.isFile }
    }

    /** The verified page order kept with a ready CBZ download, or null. */
    fun readingOrderFor(record: DownloadRecord, assetId: String): ReadingOrder? {
        val file = fileFor(record, assetId) ?: return null
        return ReadingOrderFile.read(File(file.path + ORDER))
    }

    /**
     * The book's complete narration, checked on disk: its manifest and every file, for one
     * generation. Null unless the book itself is ready too. A partial or missing set is never offered.
     */
    fun narrationFor(record: DownloadRecord): LocalNarration? {
        if (!record.isReady) return null
        val narration = record.narration?.takeIf { it.isReady } ?: return null
        val folder = folder(record.publicationId)
        val manifest = File(folder, narration.manifest).takeIf { it.isFile } ?: return null
        val tracks = narration.tracks.map { track ->
            File(folder, track.name).takeIf { it.isFile && it.length() == track.sizeBytes } ?: return null
        }
        return LocalNarration(narration.generation, manifest, tracks)
    }

    /** Local files for every pinned asset, in order, or null unless the whole download is ready. */
    fun filesFor(record: DownloadRecord): Map<String, File>? {
        val found = record.files.associate { it.assetId to fileFor(record, it.assetId) }
        if (found.values.any { it == null }) return null
        @Suppress("UNCHECKED_CAST")
        return found as Map<String, File>
    }

    /**
     * Queues [publication]. The job fetches the current edition before transferring,
     * so a download never pins details that were already stale on screen.
     */
    suspend fun enqueue(publication: Publication, format: ReadingFormat? = null, narration: Boolean? = null) {
        if (closed) return
        load()
        val existing = record(publication.id)
        // A cancelled download's earlier narration choice was cancelled with it.
        val withNarration = narration ?: existing?.takeIf { it.state != DownloadState.CANCELLED }?.withNarration ?: false
        if (existing != null && existing.isActive) {
            if (withNarration != existing.withNarration) save(existing.copy(withNarration = withNarration))
            // Already queued; make sure something will run it.
            onQueued()
            return
        }
        // A ready book that only needs its narration stays readable while that is fetched.
        if (existing != null && existing.isReady && existing.matches(publication) && (format == null || existing.pinnedFormat == format)) {
            if (!withNarration) return
            val queued = existing.copy(withNarration = true, narrationPending = true, publication = publication, updatedAtEpochMs = clock())
                .narrationRetried()
            // Whether anything is new is settled by the job, against the server's current generation.
            if (!save(queued)) return
            onQueued()
            launch(publication.id)
            return
        }
        // An explicit choice, else the format this download already keeps while the edition has it.
        val keep = format ?: existing?.pinnedFormat?.takeIf { kept -> publication.readingAssets.any { it.readingFormat == kept } }
        val chosen = if (publication.bookType == BookType.EBOOK) keep ?: defaultReadingAsset(publication)?.readingFormat else null
        val assets = downloadableAssets(publication, chosen)
        val sameFormat = format == null || existing?.pinnedFormat == format
        val record = if (existing != null && sameFormat && existing.matches(publication) && existing.state != DownloadState.CANCELLED) {
            existing.copy(
                state = DownloadState.QUEUED, problem = null, publication = publication, updatedAtEpochMs = clock(),
                withNarration = withNarration, narrationPending = withNarration, narrationProblem = null,
            )
        } else {
            if (existing != null) withContext(Dispatchers.IO) { folder(publication.id).deleteRecursively() }
            DownloadRecord(
                publication.id, publication, pin(assets), DownloadState.QUEUED, updatedAtEpochMs = clock(), format = chosen?.wire,
                withNarration = withNarration && chosen == ReadingFormat.EPUB,
                narrationPending = withNarration && chosen == ReadingFormat.EPUB,
            )
        }
        if (!save(record)) return
        onQueued()
        launch(publication.id)
    }

    /** Retries a failed or cancelled download with the details it already has. */
    suspend fun retry(publicationId: String) {
        val record = record(publicationId) ?: return
        enqueue(record.publication)
    }

    /** Resumes downloads that stopped for a reason that may have passed, such as the connection or the app stopping. */
    suspend fun retryInterrupted() {
        load()
        mutableRecords.value.values
            .filter { (it.state == DownloadState.FAILED && it.problem in TRANSIENT) || it.narrationFailedFor(TRANSIENT) }
            .forEach { retry(it.publicationId) }
    }

    /** Downloads that stopped for a reason that may pass by itself, so a host may retry them later. */
    val hasTransientFailures: Boolean
        get() = mutableRecords.value.values.any { (it.state == DownloadState.FAILED && it.problem in TRANSIENT) || it.narrationFailedFor(TRANSIENT) }

    /** Re-queues and starts downloads that stopped for a transient reason. For a running host only. */
    suspend fun resumeTransient() {
        load()
        mutableRecords.value.values
            .filter { (it.state == DownloadState.FAILED && it.problem in TRANSIENT) || it.narrationFailedFor(TRANSIENT) }
            .forEach { failed ->
                val queued = if (failed.state == DownloadState.READY) {
                    failed.narrationRetried()
                } else {
                    failed.copy(state = DownloadState.QUEUED, problem = null, updatedAtEpochMs = clock())
                }
                if (save(queued)) launch(failed.publicationId)
            }
    }

    /** Stops a transfer and deletes what it wrote. The entry stays, marked cancelled. */
    suspend fun cancel(publicationId: String) {
        // A Stop narration action can arrive after that transfer has finished. A ready
        // book is never deleted by Cancel; removing it is a separate, explicit action.
        record(publicationId)?.takeIf { it.isReady }?.let {
            removeNarration(publicationId, removeAll = false)
            return
        }
        invalidateNarration(publicationId)
        stopJob(publicationId)
        val record = record(publicationId) ?: return
        withContext(Dispatchers.IO) { folder(publicationId).deleteRecursively() }
        save(
            record.copy(
                state = DownloadState.CANCELLED,
                problem = null,
                files = record.files.map { it.copy(complete = false, bytesDone = 0, etag = null) },
                updatedAtEpochMs = clock(),
                narration = null,
                narrationUpdate = null,
            ),
        )
    }

    /**
     * Stops fetching narration and deletes what that fetch wrote. A complete earlier
     * narration is kept when only an update is being fetched; [removeAll] deletes that too.
     * The book itself is never touched.
     */
    suspend fun removeNarration(publicationId: String, removeAll: Boolean = true) {
        record(publicationId) ?: return
        // Whatever fetch is under way, even one still waiting for its manifest, ends here.
        invalidateNarration(publicationId)
        val wasRunning = synchronized(jobsLock) { jobs[publicationId]?.isActive == true }
        stopJob(publicationId)
        val record = record(publicationId) ?: return
        val keep = record.narration?.takeIf { !removeAll && it.isReady }
        withContext(Dispatchers.IO) {
            // Every narration file but the kept set: also bytes a stopped fetch wrote before recording them.
            val kept = keep?.let { set -> set.tracks.map { it.name }.toSet() + set.manifest }.orEmpty()
            folder(publicationId).listFiles().orEmpty()
                .filter { it.name.startsWith(NARRATION_PREFIX) && it.name.substringBefore(PART) !in kept && it.name.removeSuffix(".tmp") !in kept }
                .forEach { it.delete() }
        }
        save(
            record.copy(
                withNarration = keep != null, narration = keep, narrationUpdate = null,
                narrationPending = false, narrationProblem = null, updatedAtEpochMs = clock(),
            ),
        )
        // The book's own files may have been transferring in the stopped job.
        if (wasRunning && record.state != DownloadState.READY) launch(publicationId)
    }

    /** Stops any transfer and deletes the download and its entry. */
    suspend fun remove(publicationId: String) {
        invalidateNarration(publicationId)
        stopJob(publicationId)
        withContext(Dispatchers.IO) { folder(publicationId).deleteRecursively() }
        manifestMutex.withLock {
            val removed = mutableRecords.value[publicationId]
            mutableRecords.update { it - publicationId }
            if (!persistLocked() && removed != null) {
                mutableRecords.update { it + (publicationId to removed.copy(
                    state = DownloadState.FAILED, problem = DownloadProblem.STORAGE,
                    files = removed.files.map { file -> file.copy(complete = false, bytesDone = 0, etag = null) },
                )) }
            }
        }
    }

    /**
     * Stops every transfer and all further writes. The caller may then delete [root].
     * With [signedOut], unfinished downloads are first recorded as stopped by the
     * sign-in, so they resume when this same account signs in again.
     */
    suspend fun close(signedOut: Boolean = false) {
        if (signedOut) {
            pause()
            manifestMutex.withLock {
                if (closed) return@withLock
                mutableRecords.update { records ->
                    records.mapValues { (_, record) ->
                        if (record.isActive) record.stopped(DownloadProblem.SIGN_IN, clock()) else record
                    }
                }
                if (!persistLocked()) Log.w(TAG, "Could not record downloads stopped by sign-in")
            }
        }
        closed = true
        val running = synchronized(jobsLock) { jobs.values.toList().also { jobs.clear() } }
        running.forEach { it.cancel() }
        running.forEach { it.join() }
    }

    private suspend fun stopJob(publicationId: String) {
        val job = synchronized(jobsLock) { jobs.remove(publicationId) } ?: return
        job.cancel()
        job.join()
    }

    private fun launch(publicationId: String) {
        if (closed) return
        synchronized(jobsLock) {
            if (jobs[publicationId]?.isActive == true) return
            val job = scope.launch(Dispatchers.IO) {
                permits.withPermit { run(publicationId) }
            }
            jobs[publicationId] = job
            job.invokeOnCompletion {
                synchronized(jobsLock) {
                    if (jobs[publicationId] === job) {
                        jobs.remove(publicationId)
                        // Ready/Failed can be observed before this worker finishes.
                        // A retry or narration update queued during that window must
                        // reach a new worker, even when the book itself stays READY.
                        // Stop/pause remove ownership first and never restart it here.
                        val queued = record(publicationId)?.let {
                            it.state == DownloadState.QUEUED || (it.isReady && it.narrationActive)
                        } == true
                        if (!closed && scope.isActive && queued) {
                            launch(publicationId)
                        }
                    }
                }
            }
        }
    }

    private suspend fun run(publicationId: String) {
        var record = record(publicationId) ?: return
        if (!record.isActive && !record.stoppedForSignIn) return
        var readyFilesRetained = record.isReady
        val current: Publication
        try {
            // Re-pin against the server's current edition before moving any bytes.
            current = fetchPublication(publicationId)
            if (!record.matches(current)) {
                readyFilesRetained = false
                folder(publicationId).deleteRecursively()
                record = record.copy(files = pin(downloadableAssets(current, record.pinnedFormat)), narration = null, narrationUpdate = null)
            }
            if (record.files.isEmpty()) throw Unsupported()
            // Complete, verified files stay readable while anything else is fetched.
            val bookDone = record.files.all { it.complete } && record.state != DownloadState.CANCELLED
            record = if (bookDone) {
                record.copy(publication = current, state = DownloadState.READY, problem = null)
            } else {
                record.copy(publication = current, state = DownloadState.DOWNLOADING, problem = null, updatedAtEpochMs = clock())
            }
            if (!save(record)) return

            val remaining = record.files.filterNot { it.complete }.sumOf { (it.sizeBytes - it.bytesDone).coerceAtLeast(0) }
            if (usableSpace() < remaining + SPACE_MARGIN_BYTES) throw StorageFailure(IOException("Not enough space"))

            val assets = downloadableAssets(current, record.pinnedFormat).associateBy { it.id }
            // In order, one file at a time, so a long audiobook fills from the start.
            for (pinned in record.files) {
                coroutineContextActive()
                if (pinned.complete) continue
                val asset = assets[pinned.assetId] ?: throw EditionChanged()
                transfer(publicationId, asset)
            }
            val finished = record(publicationId) ?: return
            if (finished.files.isEmpty() || !finished.files.all { it.complete }) throw ApiException.Protocol()
            if (finished.state != DownloadState.READY) {
                save(finished.copy(state = DownloadState.READY, problem = null, updatedAtEpochMs = clock()))
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val problem = classify(error)
            withContext(NonCancellable) {
                if (problem == DownloadProblem.CHANGED) folder(publicationId).deleteRecursively()
                val latest = record(publicationId) ?: return@withContext
                if (readyFilesRetained && latest.isReady && problem != DownloadProblem.CHANGED) {
                    save(latest.stopped(problem, clock()))
                    return@withContext
                }
                val files = if (problem == DownloadProblem.CHANGED) {
                    latest.files.map { it.copy(complete = false, bytesDone = 0, etag = null) }
                } else {
                    latest.files
                }
                save(latest.copy(state = DownloadState.FAILED, problem = problem, files = files, updatedAtEpochMs = clock()))
            }
            return
        }
        narrate(publicationId, current)
    }

    /**
     * Fetches a ready book's read-along narration, when it was asked for and the server has a
     * current generation: the exact manifest bytes first, then every narration file. EPUB
     * Media Overlay audio is copied out of the verified EPUB on this device; an imported
     * alignment's audiobook files are fetched with this account's normal transfer.
     *
     * A newer generation is fetched beside a complete earlier one, which stays in use until
     * the new set is whole. Failing never touches the book or the earlier narration.
     */
    private suspend fun narrate(publicationId: String, current: Publication) {
        val epoch = narrationEpoch(publicationId)
        val record = record(publicationId) ?: return
        if (!record.isReady || !record.withNarration) {
            if (record.narrationPending) save(record.copy(narrationPending = false, narrationProblem = null))
            return
        }
        val pinned = record.files.singleOrNull() ?: return
        val asset = current.assets.firstOrNull { it.id == pinned.assetId && it.isEpub }
        val summary = asset?.readAlong?.takeIf { it.isAvailable }
        if (asset == null || summary == null) {
            // Nothing current to fetch. A complete copy is still a coherent set for this EPUB and stays.
            save(
                when {
                    record.narrationWork != null -> record.withNarrationWork { it.copy(state = NarrationState.FAILED, problem = DownloadProblem.UNSUPPORTED) }
                        .copy(narrationPending = false, narrationProblem = null)
                    record.narration?.isReady == true -> record.copy(narrationPending = false, narrationProblem = null)
                    // Asked for, and none here: say why rather than drop the request silently.
                    else -> record.copy(narrationPending = true, narrationProblem = DownloadProblem.UNSUPPORTED)
                },
            )
            return
        }
        val generation = requireNotNull(summary.generation)
        if (record.narration?.let { it.isReady && it.generation == generation } == true) {
            record.narrationUpdate?.let { stale -> deleteNarration(publicationId, stale) }
            save(record.copy(narrationUpdate = null, narrationPending = false, narrationProblem = null))
            return
        }
        try {
            // A failure recorded before any manifest was stored is no work to resume.
            var work = record.narrationWork?.takeIf { it.generation == generation && it.manifest.isNotEmpty() }
            if (work == null) {
                record.narrationWork?.let { stale -> deleteNarration(publicationId, stale) }
                work = pinNarration(publicationId, asset, summary)
                if (!stillWanted(publicationId, epoch)) {
                    deleteNarration(publicationId, work)
                    return
                }
                val latest = record(publicationId) ?: return
                val placed = if (latest.narration?.isReady == true) {
                    latest.copy(narrationUpdate = work, narrationPending = false, narrationProblem = null)
                } else {
                    latest.copy(narration = work, narrationUpdate = null, narrationPending = false, narrationProblem = null)
                }
                if (!save(placed)) return
            }
            val manifest = readStoredManifest(publicationId, work, asset.id) ?: throw EditionChanged()
            setNarrationWork(publicationId) { it.copy(state = NarrationState.DOWNLOADING, problem = null) }
            val remaining = work.tracks.filterNot { it.complete }.sumOf { (it.sizeBytes - it.bytesDone).coerceAtLeast(0) }
            if (usableSpace() < remaining + SPACE_MARGIN_BYTES) throw StorageFailure(IOException("Not enough space"))
            val epub = File(folder(publicationId), pinned.name)
            for ((index, file) in work.tracks.withIndex()) {
                coroutineContextActive()
                val latest = narrationTrack(publicationId, file.assetId) ?: throw EditionChanged()
                if (latest.complete) continue
                val track = manifest.tracks[index]
                when (track.kind) {
                    NarrationKind.EPUB_RESOURCE -> extractNarration(publicationId, epub, requireNotNull(track.href), latest)
                    NarrationKind.PUBLICATION_ASSET -> transferNarration(publicationId, requireNotNull(track.contentUrl), latest)
                }
            }
            if (!stillWanted(publicationId, epoch)) return
            completeNarration(publicationId, generation, epoch)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val problem = classify(error)
            withContext(NonCancellable) {
                if (!stillWanted(publicationId, epoch)) return@withContext
                val latest = record(publicationId) ?: return@withContext
                val work = latest.narrationWork ?: run {
                    // Failed before any work was pinned (the manifest itself): the request stays, with why.
                    save(latest.copy(narrationPending = true, narrationProblem = problem, updatedAtEpochMs = clock()))
                    return@withContext
                }
                if (problem == DownloadProblem.CHANGED) deleteNarration(publicationId, work)
                save(
                    latest.withNarrationWork {
                        val tracks = if (problem == DownloadProblem.CHANGED) it.tracks.map { file -> file.copy(complete = false, bytesDone = 0, etag = null) } else it.tracks
                        it.copy(state = NarrationState.FAILED, problem = problem, tracks = tracks)
                    }.copy(updatedAtEpochMs = clock(), narrationPending = false, narrationProblem = null),
                )
            }
        }
    }

    /** Fetches and stores the manifest for [summary]'s generation, then pins its narration files. */
    private suspend fun pinNarration(publicationId: String, asset: Asset, summary: ReadAlongSummary): NarrationDownload {
        val generation = requireNotNull(summary.generation)
        val manifestUrl = requireNotNull(summary.manifestUrl)
        val fetched = when (val result = api.readAlong(server, manifestUrl, asset.id, generation)) {
            is ReadAlongFetch.Available -> result
            is ReadAlongFetch.Refused -> throw if (result.kind == ReadAlongRefused.Kind.CHANGED) EditionChanged() else ApiException.Protocol()
            // Unaligned, stale or invalid since the details were read.
            is ReadAlongFetch.Unavailable -> throw EditionChanged()
        }
        val key = generation.take(12)
        val name = "$NARRATION_PREFIX$key.json"
        withContext(Dispatchers.IO) {
            try {
                val folder = folder(publicationId).apply { mkdirs() }
                val temporary = File(folder, "$name.tmp")
                temporary.writeBytes(fetched.body)
                if (!temporary.renameTo(File(folder, name))) throw IOException("Could not save the narration manifest")
            } catch (error: IOException) {
                throw StorageFailure(error)
            }
        }
        val tracks = fetched.readAlong.tracks.map { track ->
            DownloadedFile("narration:$key:${track.index}", "$NARRATION_PREFIX$key-%04d.%s".format(track.index, narrationExtension(track)), track.sizeBytes)
        }
        return NarrationDownload(generation, fetched.readAlong.source.wire, name, tracks)
    }

    /** The stored manifest for [work], read and checked again, or null when it is missing or no longer matches. */
    private suspend fun readStoredManifest(publicationId: String, work: NarrationDownload, ebookAssetId: String): ReadAlong? =
        withContext(Dispatchers.IO) {
            val file = File(folder(publicationId), work.manifest)
            if (!file.isFile) return@withContext null
            val manifest = try {
                file.inputStream().use { ReadAlong.read(it, ebookAssetId, work.generation, server) }
            } catch (_: ReadAlongRefused) {
                return@withContext null
            } catch (error: IOException) {
                throw StorageFailure(error)
            }
            manifest.takeIf { it.tracks.size == work.tracks.size && it.tracks.zip(work.tracks).all { (track, file) -> track.sizeBytes == file.sizeBytes } }
        }

    /** Copies one Media Overlay audio entry out of the verified EPUB, checking it is exactly the size the manifest states. */
    private suspend fun extractNarration(publicationId: String, epub: File, href: String, pinned: DownloadedFile) {
        val folder = folder(publicationId)
        val partial = File(folder, pinned.name + PART)
        val final = File(folder, pinned.name)
        val context = kotlin.coroutines.coroutineContext
        withContext(Dispatchers.IO) {
            try {
                java.util.zip.ZipFile(epub).use { zip ->
                    val entry = zip.getEntry(href)?.takeUnless { it.isDirectory } ?: throw ApiException.Protocol()
                    if (entry.size >= 0 && entry.size != pinned.sizeBytes) throw ApiException.Protocol()
                    zip.getInputStream(entry).use { input ->
                        partial.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var written = 0L
                            while (true) {
                                context.ensureActive()
                                val count = input.read(buffer)
                                if (count < 0) break
                                written += count
                                if (written > pinned.sizeBytes) throw ApiException.Protocol()
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                }
            } catch (error: java.util.zip.ZipException) {
                partial.delete()
                throw ApiException.Protocol(error)
            } catch (error: IOException) {
                partial.delete()
                throw StorageFailure(error)
            }
        }
        if (partial.length() != pinned.sizeBytes) {
            partial.delete()
            throw ApiException.Protocol()
        }
        final.delete()
        if (!partial.renameTo(final)) throw StorageFailure(IOException("Could not finish the narration file"))
        updateFile(publicationId, pinned.assetId, persist = true) { it.copy(complete = true, bytesDone = pinned.sizeBytes) }
    }

    /** Downloads one audiobook file of an imported alignment, resuming with Range + If-Range when provably safe. */
    private suspend fun transferNarration(publicationId: String, contentUrl: String, pinned: DownloadedFile) {
        val url = server.resolve(contentUrl)?.takeIf(server::contains) ?: throw ApiException.Protocol()
        val folder = folder(publicationId).apply { mkdirs() }
        val partial = File(folder, pinned.name + PART)
        val final = File(folder, pinned.name)
        val strongTag = pinned.etag?.takeUnless { it.startsWith("W/") }
        val offset = if (partial.isFile && strongTag != null) partial.length() else 0L
        if (offset == 0L) partial.delete()
        if (offset < pinned.sizeBytes || offset == 0L) {
            val request = Request.Builder().url(url).apply {
                if (offset > 0) {
                    header("Range", "bytes=$offset-")
                    header("If-Range", strongTag.orEmpty())
                }
            }.build()
            call(request).use { response ->
                val tag = response.header("ETag")
                val append = when {
                    response.code == 206 && offset > 0 && contentRangeStart(response) == offset -> true
                    response.code == 200 -> {
                        if (pinned.etag != null && tag != pinned.etag) throw EditionChanged()
                        false
                    }
                    response.code == 412 || response.code == 416 -> throw EditionChanged()
                    else -> fail(response)
                }
                if (!append) updateFile(publicationId, pinned.assetId) { it.copy(etag = tag, bytesDone = 0) }
                write(publicationId, pinned.assetId, response, partial, append, pinned.sizeBytes)
            }
        }
        if (partial.length() != pinned.sizeBytes) {
            partial.delete()
            updateFile(publicationId, pinned.assetId) { it.copy(bytesDone = 0, etag = null) }
            throw ApiException.Protocol()
        }
        final.delete()
        if (!partial.renameTo(final)) throw StorageFailure(IOException("Could not finish the narration file"))
        updateFile(publicationId, pinned.assetId, persist = true) { it.copy(complete = true, bytesDone = pinned.sizeBytes) }
    }

    /** Marks [generation]'s narration whole, replacing (and only then deleting) an earlier complete one. */
    private suspend fun completeNarration(publicationId: String, generation: String, epoch: Int) {
        if (!stillWanted(publicationId, epoch)) return
        val latest = record(publicationId) ?: return
        val work = latest.narrationWork?.takeIf { it.generation == generation } ?: return
        if (!work.tracks.all { it.complete }) throw ApiException.Protocol()
        val done = work.copy(state = NarrationState.READY, problem = null)
        val previous = latest.narration?.takeIf { latest.narrationUpdate != null }
        if (!save(latest.copy(narration = done, narrationUpdate = null, updatedAtEpochMs = clock()))) return
        previous?.let { deleteNarration(publicationId, it) }
    }

    /** The narration fetch started under [epoch] may still change anything. */
    private fun stillWanted(publicationId: String, epoch: Int): Boolean =
        narrationEpoch(publicationId) == epoch && record(publicationId)?.withNarration == true

    private suspend fun setNarrationWork(publicationId: String, transform: (NarrationDownload) -> NarrationDownload) {
        val latest = record(publicationId) ?: return
        save(latest.withNarrationWork(transform))
    }

    private fun narrationTrack(publicationId: String, trackId: String): DownloadedFile? =
        record(publicationId)?.narrationWork?.tracks?.firstOrNull { it.assetId == trackId }

    private suspend fun deleteNarration(publicationId: String, narration: NarrationDownload) = withContext(Dispatchers.IO) {
        val folder = folder(publicationId)
        if (narration.manifest.startsWith(NARRATION_PREFIX)) File(folder, narration.manifest).delete()
        narration.tracks.forEach { track ->
            File(folder, track.name).delete()
            File(folder, track.name + PART).delete()
        }
    }

    private fun narrationExtension(track: NarrationTrack): String {
        NARRATION_EXTENSIONS[track.mediaType]?.let { return it }
        val name = track.filename ?: track.href.orEmpty()
        return name.substringAfterLast('.', "").lowercase().takeIf { it.matches(Regex("[a-z0-9]{1,5}")) } ?: "bin"
    }

    private suspend fun coroutineContextActive() = kotlin.coroutines.coroutineContext.ensureActive()

    /** Downloads one asset to `<name>.part`, resuming with Range + If-Range when that is provably safe. */
    private suspend fun transfer(publicationId: String, asset: Asset) {
        val url = server.resolve(asset.contentUrl)?.takeIf(server::contains) ?: throw ApiException.Protocol()
        val pinned = record(publicationId)?.files?.firstOrNull { it.assetId == asset.id } ?: throw EditionChanged()
        val folder = folder(publicationId).apply { mkdirs() }
        val partial = File(folder, pinned.name + PART)
        val final = File(folder, pinned.name)

        val strongTag = pinned.etag?.takeUnless { it.startsWith("W/") }
        val offset = if (partial.isFile && strongTag != null) partial.length() else 0L
        if (offset == 0L) partial.delete()
        if (pinned.sizeBytes in 1..offset) {
            // A part as long as the whole file: verify it rather than ask for nothing.
            finish(publicationId, asset, partial, final)
            return
        }

        val request = Request.Builder().url(url).apply {
            if (offset > 0) {
                header("Range", "bytes=$offset-")
                header("If-Range", strongTag.orEmpty())
            }
        }.build()

        call(request).use { response ->
            val tag = response.header("ETag")
            val append = when {
                response.code == 206 && offset > 0 && contentRangeStart(response) == offset -> true
                response.code == 200 -> {
                    // A full body: either the server ignored the range, or the file changed.
                    if (pinned.etag != null && tag != pinned.etag) throw EditionChanged()
                    false
                }
                response.code == 412 || response.code == 416 -> throw EditionChanged()
                else -> fail(response)
            }
            if (!append) updateFile(publicationId, asset.id) { it.copy(etag = tag, bytesDone = 0) }
            write(publicationId, asset.id, response, partial, append, limitFor(asset))
        }
        finish(publicationId, asset, partial, final)
    }

    /** PDF and CBZ only: bytes past the announced size are refused as they arrive. */
    private fun limitFor(asset: Asset): Long? {
        val format = asset.declaredFormat?.takeIf { it.isPaged } ?: return null
        return if (asset.sizeBytes > 0) minOf(asset.sizeBytes, format.maxBytes) else format.maxBytes
    }

    private suspend fun finish(publicationId: String, asset: Asset, partial: File, final: File) {
        val length = partial.length()
        val lengthOk = asset.sizeBytes <= 0 || length == asset.sizeBytes
        val format = asset.declaredFormat
        if (!lengthOk || length == 0L || !looksLike(format, partial)) discard(publicationId, asset, partial)
        if (format == ReadingFormat.CBZ) {
            // Complete means the archive and its verified page order, so it opens offline.
            val order = try {
                orders.fetch(server, asset)
            } catch (_: GenerationGone) {
                throw EditionChanged()
            } catch (_: UnreadableFile) {
                discard(publicationId, asset, partial)
            }
            try {
                ComicArchive.open(partial, order.validate(asset), asset.sizeBytes).close()
            } catch (_: UnreadableFile) {
                discard(publicationId, asset, partial)
            }
            try {
                ReadingOrderFile.write(File(final.path + ORDER), order)
            } catch (error: IOException) {
                throw StorageFailure(error)
            }
        }
        final.delete()
        if (!partial.renameTo(final)) throw StorageFailure(IOException("Could not finish the file"))
        updateFile(publicationId, asset.id, persist = true) { it.copy(complete = true, bytesDone = length) }
    }

    private suspend fun discard(publicationId: String, asset: Asset, partial: File): Nothing {
        partial.delete()
        updateFile(publicationId, asset.id) { it.copy(bytesDone = 0, etag = null) }
        throw ApiException.Protocol()
    }

    private suspend fun write(publicationId: String, assetId: String, response: Response, target: File, append: Boolean, limit: Long? = null) {
        val context = kotlin.coroutines.coroutineContext
        val output = try {
            RandomAccessFile(target, "rw").apply {
                if (!append) setLength(0)
                seek(length())
            }
        } catch (error: IOException) {
            throw StorageFailure(error)
        }
        var written = output.length()
        try {
            output.use { writeBody(publicationId, assetId, response, output, context, limit) { written = it } }
        } finally {
            // Keep the on-screen size honest even when the connection dropped mid-file.
            val done = written
            withContext(NonCancellable) { updateFile(publicationId, assetId) { it.copy(bytesDone = done) } }
        }
    }

    private suspend fun writeBody(
        publicationId: String,
        assetId: String,
        response: Response,
        output: RandomAccessFile,
        context: kotlin.coroutines.CoroutineContext,
        limit: Long?,
        onWritten: (Long) -> Unit,
    ) {
        var written = output.length()
        var reported = written
        val buffer = ByteArray(64 * 1024)
        response.body.byteStream().use { input ->
            while (true) {
                context.ensureActive()
                val count = try {
                    input.read(buffer)
                } catch (error: IOException) {
                    throw ApiException.Offline(error)
                }
                if (count < 0) break
                if (limit != null && written + count > limit) throw ApiException.Protocol()
                try {
                    output.write(buffer, 0, count)
                } catch (error: IOException) {
                    throw StorageFailure(error)
                }
                written += count
                onWritten(written)
                if (written - reported >= REPORT_EVERY_BYTES) {
                    reported = written
                    val done = written
                    updateFile(publicationId, assetId) { it.copy(bytesDone = done) }
                }
            }
        }
    }

    private suspend fun call(request: Request): Response = try {
        client.newCall(request).await()
    } catch (error: BlockedRedirectIOException) {
        throw ApiException.RedirectBlocked(error.location)
    } catch (error: IOException) {
        throw ApiException.Offline(error)
    }

    private fun fail(response: Response): Nothing = throw when (response.code) {
        401 -> ApiException.Unauthorized()
        403 -> ApiException.Forbidden()
        404 -> ApiException.NotFound()
        in 500..599 -> ApiException.Server(response.code)
        else -> ApiException.Protocol()
    }

    private fun contentRangeStart(response: Response): Long? =
        response.header("Content-Range")?.substringAfter("bytes ", "")?.substringBefore('-')?.toLongOrNull()

    private fun classify(error: Throwable): DownloadProblem = when (error) {
        is EditionChanged -> DownloadProblem.CHANGED
        is StorageFailure -> DownloadProblem.STORAGE
        is Unsupported -> DownloadProblem.UNSUPPORTED
        is ApiException.Offline -> if (error.certificate) DownloadProblem.CERTIFICATE else DownloadProblem.OFFLINE
        is ApiException.Unauthorized -> DownloadProblem.SIGN_IN
        is ApiException.Forbidden -> DownloadProblem.FORBIDDEN
        is ApiException.NotFound -> DownloadProblem.NOT_FOUND
        is ApiException.Server -> DownloadProblem.SERVER
        is ApiException.RedirectBlocked -> DownloadProblem.REDIRECT
        else -> DownloadProblem.INVALID
    }

    private fun pin(assets: List<Asset>): List<DownloadedFile> = assets.mapIndexed { index, asset ->
        DownloadedFile(asset.id, fileName(index, asset), asset.sizeBytes)
    }

    private fun fileName(index: Int, asset: Asset): String {
        val extension = asset.format.lowercase().takeIf { it.matches(Regex("[a-z0-9]{1,5}")) }
            ?: asset.filename.substringAfterLast('.', "").lowercase().takeIf { it.matches(Regex("[a-z0-9]{1,5}")) }
            ?: "bin"
        return "%03d-%s.%s".format(index, hash(asset.id), extension)
    }

    private fun folder(publicationId: String): File = File(root, hash(publicationId))

    private suspend fun updateFile(
        publicationId: String,
        assetId: String,
        persist: Boolean = false,
        transform: (DownloadedFile) -> DownloadedFile,
    ) = manifestMutex.withLock {
        val record = mutableRecords.value[publicationId] ?: return@withLock
        fun List<DownloadedFile>.changed() = map { if (it.assetId == assetId) transform(it) else it }
        val updated = record.copy(
            files = record.files.changed(),
            narration = record.narration?.let { it.copy(tracks = it.tracks.changed()) },
            narrationUpdate = record.narrationUpdate?.let { it.copy(tracks = it.tracks.changed()) },
        )
        mutableRecords.update { it + (publicationId to updated) }
        // Validators must be on disk before the body, so an interrupted transfer can resume.
        fun DownloadRecord.validators() = files.map { it.etag } + narration?.tracks.orEmpty().map { it.etag } +
            narrationUpdate?.tracks.orEmpty().map { it.etag }
        val validatorChanged = updated.validators() != record.validators()
        if ((persist || validatorChanged) && !persistLocked()) throw StorageFailure(IOException("Could not save downloads"))
    }

    private suspend fun save(record: DownloadRecord): Boolean = manifestMutex.withLock {
        if (closed) return@withLock false
        val snapshot = mutableRecords.value + (record.publicationId to record)
        // An observer may close this manager as soon as it sees Ready or Failed.
        // Publish only after that state is durable, so closing cannot discard it.
        if (persistLocked(snapshot)) {
            mutableRecords.value = snapshot
            return@withLock true
        }
        // Keep the error visible even when the disk cannot persist the failure itself.
        mutableRecords.update { it + (record.publicationId to record.copy(state = DownloadState.FAILED, problem = DownloadProblem.STORAGE)) }
        false
    }

    private suspend fun persistLocked(snapshot: Map<String, DownloadRecord> = mutableRecords.value): Boolean {
        if (closed) return false
        if (manifestUnreadable) {
            Log.w(TAG, "Not saving downloads over a manifest that couldn't be read")
            return false
        }
        return withContext(Dispatchers.IO + NonCancellable) {
            try {
                root.mkdirs()
                val temporary = File(manifestFile.path + ".tmp")
                temporary.writeText(ApiJson.encodeToString(snapshot))
                if (!temporary.renameTo(manifestFile)) throw IOException("Could not save downloads")
                true
            } catch (error: IOException) {
                Log.w(TAG, "Could not save the download manifest", error)
                false
            } catch (error: SecurityException) {
                Log.w(TAG, "Could not save the download manifest", error)
                false
            }
        }
    }

    private fun readManifest(): Map<String, DownloadRecord> {
        if (!manifestFile.isFile) return emptyMap()
        val text = try {
            manifestFile.readText()
        } catch (error: IOException) {
            // Unreadable right now: start empty, and never overwrite the file this session.
            Log.w(TAG, "Could not read the download manifest", error)
            manifestUnreadable = true
            return emptyMap()
        } catch (error: SecurityException) {
            Log.w(TAG, "Could not read the download manifest", error)
            manifestUnreadable = true
            return emptyMap()
        }
        return try {
            ApiJson.decodeFromString(text)
        } catch (error: SerializationException) {
            quarantine(error)
        } catch (error: IllegalArgumentException) {
            quarantine(error)
        }
    }

    /**
     * Keeps an unreadable manifest aside instead of overwriting it with an empty one,
     * so nothing that could explain or recover it is lost. Folders stay on disk.
     */
    private fun quarantine(error: Exception): Map<String, DownloadRecord> {
        Log.e(TAG, "The download manifest is unreadable; keeping a copy", error)
        val aside = File(root, "manifest.unreadable-${clock()}.json")
        if (!manifestFile.renameTo(aside)) Log.e(TAG, "Could not keep the unreadable download manifest")
        return emptyMap()
    }

    private fun hash(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).take(16).joinToString("") { "%02x".format(it) }

    private companion object {
        const val TAG = "ShelfarrDownloads"
        const val PART = ".part"
        /** Every narration file of a book's folder starts with this, and nothing else does. */
        const val NARRATION_PREFIX = "ra-"
        /** Beside a CBZ: its verified reading order. */
        const val ORDER = ".order.json"
        const val REPORT_EVERY_BYTES = 256L * 1024
        const val SPACE_MARGIN_BYTES = 64L * 1024 * 1024
        val TRANSIENT = setOf(DownloadProblem.OFFLINE, DownloadProblem.SERVER)
        val NARRATION_EXTENSIONS = mapOf(
            "audio/mpeg" to "mp3", "audio/mp4" to "m4a", "audio/aac" to "aac", "audio/ogg" to "ogg", "audio/opus" to "opus",
            "audio/flac" to "flac", "audio/wav" to "wav", "audio/x-wav" to "wav", "audio/wave" to "wav",
        )
    }
}
