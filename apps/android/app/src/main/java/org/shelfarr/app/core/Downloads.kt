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

/**
 * A publication kept on this device by the user's choice. It pins one edition: the
 * exact asset ids it was started with. It is only [DownloadState.READY] once every
 * pinned file is complete and verified.
 */
@Serializable
data class DownloadRecord(
    val publicationId: String,
    val publication: Publication,
    val files: List<DownloadedFile>,
    val state: DownloadState,
    val problem: DownloadProblem? = null,
    val updatedAtEpochMs: Long = 0,
) {
    val pinnedAssetIds: List<String> get() = files.map { it.assetId }

    /** Null when the server didn't state every size, so no honest total exists. */
    val bytesTotal: Long? get() = if (files.any { it.sizeBytes <= 0 }) null else files.sumOf { it.sizeBytes }

    val bytesDone: Long get() = files.sumOf { if (it.complete) it.sizeBytes.coerceAtLeast(it.bytesDone) else it.bytesDone }

    val fraction: Float? get() = bytesTotal?.takeIf { it > 0 }?.let { (bytesDone.toFloat() / it).coerceIn(0f, 1f) }

    val isReady: Boolean get() = state == DownloadState.READY

    val isActive: Boolean get() = state == DownloadState.QUEUED || state == DownloadState.DOWNLOADING

    /** True when [current] is the same edition this download pinned. */
    fun matches(current: Publication): Boolean = downloadableAssets(current).map { it.id } == pinnedAssetIds
}

/** Every file a download needs: the EPUB for a book, all audio files in order for an audiobook. */
fun downloadableAssets(publication: Publication): List<Asset> = publication.playableAssets

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
    private val manifestMutex = Mutex()
    private val permits = Semaphore(maxConcurrent)
    private val jobs = HashMap<String, Job>()
    private val jobsLock = Any()

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
            record.files.filterNot { it.complete }.sumOf { (it.sizeBytes - it.bytesDone).coerceAtLeast(0) }
        }

    /**
     * Starts every queued download, for a host that may now transfer. Downloads that
     * stopped for a sign-in resume too: this account's services only exist while it is
     * signed in. Already running transfers are left alone.
     */
    suspend fun resumeQueued() {
        load()
        mutableRecords.value.values
            .filter { it.isActive || (it.state == DownloadState.FAILED && it.problem == DownloadProblem.SIGN_IN) }
            .forEach { launch(it.publicationId) }
    }

    /** Re-queues downloads that stopped because the account was signed out, now that it is back. */
    suspend fun resumeAfterSignIn() {
        load()
        mutableRecords.value.values
            .filter { it.state == DownloadState.FAILED && it.problem == DownloadProblem.SIGN_IN }
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
                records + stale.associateWith { id ->
                    records.getValue(id).copy(state = DownloadState.FAILED, problem = DownloadProblem.INTERRUPTED, updatedAtEpochMs = clock())
                }
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
                        interrupted -> record.copy(state = DownloadState.FAILED, problem = DownloadProblem.INTERRUPTED, updatedAtEpochMs = clock())
                        else -> record.copy(state = DownloadState.QUEUED)
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
                if (record.isActive) record.copy(state = DownloadState.FAILED, problem = DownloadProblem.STORAGE) else record
            } }
        }
    }

    /** Recomputes sizes from disk and refuses to call missing or short files ready. */
    private fun reconcile(record: DownloadRecord): DownloadRecord {
        val folder = folder(record.publicationId)
        val files = record.files.map { file ->
            val final = File(folder, file.name)
            val partial = File(folder, file.name + PART)
            when {
                file.complete && final.isFile && (file.sizeBytes <= 0 || final.length() == file.sizeBytes) ->
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
        return record.copy(files = files, state = state, problem = problem)
    }

    fun record(publicationId: String): DownloadRecord? = mutableRecords.value[publicationId]

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
    suspend fun enqueue(publication: Publication) {
        if (closed) return
        load()
        val assets = downloadableAssets(publication)
        val existing = record(publication.id)
        if (existing != null && existing.isActive) {
            // Already queued; make sure something will run it.
            onQueued()
            return
        }
        val record = if (existing != null && existing.matches(publication) && existing.state != DownloadState.CANCELLED) {
            existing.copy(state = DownloadState.QUEUED, problem = null, publication = publication, updatedAtEpochMs = clock())
        } else {
            if (existing != null) withContext(Dispatchers.IO) { folder(publication.id).deleteRecursively() }
            DownloadRecord(publication.id, publication, pin(assets), DownloadState.QUEUED, updatedAtEpochMs = clock())
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
            .filter { it.state == DownloadState.FAILED && it.problem in TRANSIENT }
            .forEach { retry(it.publicationId) }
    }

    /** Downloads that stopped for a reason that may pass by itself, so a host may retry them later. */
    val hasTransientFailures: Boolean
        get() = mutableRecords.value.values.any { it.state == DownloadState.FAILED && it.problem in TRANSIENT }

    /** Re-queues and starts downloads that stopped for a transient reason. For a running host only. */
    suspend fun resumeTransient() {
        load()
        mutableRecords.value.values
            .filter { it.state == DownloadState.FAILED && it.problem in TRANSIENT }
            .forEach { failed ->
                val queued = failed.copy(state = DownloadState.QUEUED, problem = null, updatedAtEpochMs = clock())
                if (save(queued)) launch(failed.publicationId)
            }
    }

    /** Stops a transfer and deletes what it wrote. The entry stays, marked cancelled. */
    suspend fun cancel(publicationId: String) {
        stopJob(publicationId)
        val record = record(publicationId) ?: return
        withContext(Dispatchers.IO) { folder(publicationId).deleteRecursively() }
        save(
            record.copy(
                state = DownloadState.CANCELLED,
                problem = null,
                files = record.files.map { it.copy(complete = false, bytesDone = 0, etag = null) },
                updatedAtEpochMs = clock(),
            ),
        )
    }

    /** Stops any transfer and deletes the download and its entry. */
    suspend fun remove(publicationId: String) {
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
                        if (record.isActive) record.copy(state = DownloadState.FAILED, problem = DownloadProblem.SIGN_IN) else record
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
                synchronized(jobsLock) { if (jobs[publicationId] === job) jobs.remove(publicationId) }
            }
        }
    }

    private suspend fun run(publicationId: String) {
        var record = record(publicationId) ?: return
        if (!record.isActive && !(record.state == DownloadState.FAILED && record.problem == DownloadProblem.SIGN_IN)) return
        try {
            // Re-pin against the server's current edition before moving any bytes.
            val current = fetchPublication(publicationId)
            if (!record.matches(current)) {
                folder(publicationId).deleteRecursively()
                record = record.copy(files = pin(downloadableAssets(current)))
            }
            if (record.files.isEmpty()) throw Unsupported()
            record = record.copy(publication = current, state = DownloadState.DOWNLOADING, problem = null, updatedAtEpochMs = clock())
            if (!save(record)) return

            val remaining = record.files.filterNot { it.complete }.sumOf { (it.sizeBytes - it.bytesDone).coerceAtLeast(0) }
            if (usableSpace() < remaining + SPACE_MARGIN_BYTES) throw StorageFailure(IOException("Not enough space"))

            val assets = downloadableAssets(current).associateBy { it.id }
            // In order, one file at a time, so a long audiobook fills from the start.
            for (pinned in record.files) {
                coroutineContextActive()
                if (pinned.complete) continue
                val asset = assets[pinned.assetId] ?: throw EditionChanged()
                transfer(publicationId, asset)
            }
            val finished = record(publicationId) ?: return
            if (finished.files.isEmpty() || !finished.files.all { it.complete }) throw ApiException.Protocol()
            save(finished.copy(state = DownloadState.READY, problem = null, updatedAtEpochMs = clock()))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val problem = classify(error)
            withContext(NonCancellable) {
                if (problem == DownloadProblem.CHANGED) folder(publicationId).deleteRecursively()
                val latest = record(publicationId) ?: return@withContext
                val files = if (problem == DownloadProblem.CHANGED) {
                    latest.files.map { it.copy(complete = false, bytesDone = 0, etag = null) }
                } else {
                    latest.files
                }
                save(latest.copy(state = DownloadState.FAILED, problem = problem, files = files, updatedAtEpochMs = clock()))
            }
        }
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
            write(publicationId, asset.id, response, partial, append)
        }
        finish(publicationId, asset, partial, final)
    }

    private suspend fun finish(publicationId: String, asset: Asset, partial: File, final: File) {
        val length = partial.length()
        val lengthOk = asset.sizeBytes <= 0 || length == asset.sizeBytes
        val epubOk = !asset.isEpub || partial.inputStream().use { it.read() == 'P'.code && it.read() == 'K'.code }
        if (!lengthOk || !epubOk || length == 0L) {
            partial.delete()
            updateFile(publicationId, asset.id) { it.copy(bytesDone = 0, etag = null) }
            throw ApiException.Protocol()
        }
        final.delete()
        if (!partial.renameTo(final)) throw StorageFailure(IOException("Could not finish the file"))
        updateFile(publicationId, asset.id, persist = true) { it.copy(complete = true, bytesDone = length) }
    }

    private suspend fun write(publicationId: String, assetId: String, response: Response, target: File, append: Boolean) {
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
            output.use { writeBody(publicationId, assetId, response, output, context) { written = it } }
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
        val updated = record.copy(files = record.files.map { if (it.assetId == assetId) transform(it) else it })
        mutableRecords.update { it + (publicationId to updated) }
        // Validators must be on disk before the body, so an interrupted transfer can resume.
        val validatorChanged = updated.files.zip(record.files).any { (after, before) -> after.etag != before.etag }
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
        const val REPORT_EVERY_BYTES = 256L * 1024
        const val SPACE_MARGIN_BYTES = 64L * 1024 * 1024
        val TRANSIENT = setOf(DownloadProblem.OFFLINE, DownloadProblem.SERVER)
    }
}
