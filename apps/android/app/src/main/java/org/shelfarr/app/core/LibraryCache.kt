package org.shelfarr.app.core

import android.util.Log
import java.io.File
import java.io.IOException
import java.text.Collator
import java.text.Normalizer
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString

/** One title as this device last saw it from the server. */
@Serializable
data class CachedTitle(
    val publication: Publication,
    /** When the request that returned these details started, so a slow old reply can't win. */
    val seenAtEpochMs: Long,
    /** The start time of the unfiltered "recent" listing pass this title was ranked in. */
    val rankPassEpochMs: Long? = null,
    /** Its position in that pass, which is the server's recently-added order. */
    val rankOffset: Int? = null,
)

@Serializable
private data class StoredLibrary(
    val version: Int = 1,
    val titles: List<CachedTitle> = emptyList(),
    val lastOnlineAtEpochMs: Long? = null,
    val completeAsOfEpochMs: Long? = null,
)

/**
 * How much of the library this device knows, so offline screens can say so honestly.
 * [completeAsOfEpochMs] is set only after the whole unfiltered library was paged
 * through in one pass and nothing was evicted since.
 */
data class LibraryCoverage(
    val titles: Int = 0,
    val lastOnlineAtEpochMs: Long? = null,
    val completeAsOfEpochMs: Long? = null,
) {
    val isComplete: Boolean get() = completeAsOfEpochMs != null
}

/** Local results for one query, and how much of the library they were drawn from. */
data class OfflineLibraryResult(val items: List<Publication>, val coverage: LibraryCoverage)

/**
 * Canonical publication metadata from every page, details view and status change this
 * account has seen, so the library can be browsed without a connection. It is not a
 * synced catalog: [LibraryCoverage] says how much of the library it holds.
 *
 * Titles in [protectedIds] (downloads) are never evicted. Other titles are bounded by
 * [maxTitles], least recently seen first. Writes are debounced, atomic, and stop for
 * good at [close], so a sign-out wipe can't be followed by a late write.
 */
class LibraryCache(
    private val file: File,
    private val scope: CoroutineScope,
    private val protectedIds: () -> Set<String> = { emptySet() },
    private val legacy: AccountPublications? = null,
    private val maxTitles: Int = DEFAULT_MAX_TITLES,
    private val clock: () -> Long = System::currentTimeMillis,
    private val writeDelayMs: Long = 400,
) {
    private val mutex = Mutex()
    private var loaded = false
    private var closed = false
    private val titles = LinkedHashMap<String, CachedTitle>()
    private var lastOnlineAt: Long? = null
    private var completeAsOf: Long? = null
    private var pendingWrite: Job? = null

    /** Unfiltered passes in progress, keyed by the cursor that continues them. Most are abandoned. */
    private val passes = LinkedHashMap<String, Pass>()

    private class Pass(val startedAt: Long, val offset: Int, val ids: MutableSet<String>)

    private val mutableCoverage = MutableStateFlow(LibraryCoverage())
    val coverage: StateFlow<LibraryCoverage> = mutableCoverage.asStateFlow()

    /** Records a library page. [observedAt] is when its request started. */
    suspend fun recordPage(query: LibraryQuery, cursor: String?, page: LibraryPage, observedAt: Long = clock()) = mutate {
        val unfiltered = query.filter == LibraryFilter.ALL && query.text.isBlank() && query.status == null
        val pass = when {
            !unfiltered -> null
            cursor == null -> Pass(observedAt, 0, HashSet())
            else -> passes.remove(cursor)
        }
        val ranked = pass != null && query.sort == LibrarySort.RECENT
        page.items.forEachIndexed { index, publication ->
            upsert(
                publication,
                observedAt,
                rank = if (ranked) pass!!.startedAt to pass.offset + index else null,
            )
        }
        lastOnlineAt = maxOf(lastOnlineAt ?: 0, observedAt)
        if (pass != null) {
            pass.ids += page.items.map { it.id }
            val next = page.nextCursor
            if (next == null) {
                completePass(pass)
            } else {
                passes[next] = Pass(pass.startedAt, pass.offset + page.items.size, pass.ids)
                // Every Home refresh starts a pass that is never finished: keep only the latest few.
                while (passes.size > MAX_OPEN_PASSES) passes.remove(passes.keys.first())
            }
        }
        trim()
    }

    /** Records details from a publication page, Continue or a status change. */
    suspend fun remember(publication: Publication, observedAt: Long = clock()) = mutate {
        upsert(publication, observedAt, rank = null)
        lastOnlineAt = maxOf(lastOnlineAt ?: 0, observedAt)
        trim()
    }

    suspend fun rememberAll(publications: List<Publication>, observedAt: Long = clock()) = mutate {
        publications.forEach { upsert(it, observedAt, rank = null) }
        if (publications.isNotEmpty()) lastOnlineAt = maxOf(lastOnlineAt ?: 0, observedAt)
        trim()
    }

    /** The last details seen for [id], including from the single-title store older versions kept. */
    suspend fun recall(id: String): Publication? {
        val cached = mutex.withLock {
            loadLocked()
            titles[id]?.publication
        }
        return cached ?: legacy?.recall(id)
    }

    /**
     * Filters and orders what this device knows. [extra] adds titles known from other
     * local records (downloads); a cached entry wins because it is canonical server data.
     */
    suspend fun query(query: LibraryQuery, extra: Collection<Publication> = emptyList()): OfflineLibraryResult = mutex.withLock {
        loadLocked()
        val merged = LinkedHashMap<String, CachedTitle>(titles)
        extra.forEach { publication -> merged.putIfAbsent(publication.id, CachedTitle(publication, 0)) }
        val tokens = normalize(query.text).split(' ').filter(String::isNotEmpty)
        val matching = merged.values.filter { entry ->
            val publication = entry.publication
            val typeOk = when (query.filter) {
                LibraryFilter.ALL -> true
                LibraryFilter.EBOOK -> publication.bookType == BookType.EBOOK
                LibraryFilter.AUDIOBOOK -> publication.bookType == BookType.AUDIOBOOK
            }
            val statusOk = query.status == null || publication.status == query.status
            val haystack by lazy { normalize(publication.title + " " + publication.author.orEmpty()) }
            typeOk && statusOk && tokens.all { haystack.contains(it) }
        }
        val ordered = when (query.sort) {
            LibrarySort.TITLE -> {
                val collator = Collator.getInstance(Locale.getDefault()).apply { strength = Collator.PRIMARY }
                matching.sortedWith { a, b ->
                    collator.compare(a.publication.title, b.publication.title).takeIf { it != 0 }
                        ?: collator.compare(a.publication.author.orEmpty(), b.publication.author.orEmpty()).takeIf { it != 0 }
                        ?: a.publication.id.compareTo(b.publication.id)
                }
            }
            // Ranked titles in the server's order, newest pass first; the rest by when they were seen.
            LibrarySort.RECENT -> matching.sortedWith(
                compareByDescending<CachedTitle> { it.rankPassEpochMs ?: Long.MIN_VALUE }
                    .thenBy { it.rankOffset ?: Int.MAX_VALUE }
                    .thenByDescending { it.seenAtEpochMs }
                    .thenBy { it.publication.id },
            )
        }
        OfflineLibraryResult(ordered.map { it.publication }, coverageLocked(merged.size))
    }

    /** Writes anything pending now. */
    suspend fun flush() {
        mutex.withLock {
            pendingWrite?.cancel()
            pendingWrite = null
            writeLocked()
        }
    }

    /** Writes pending changes, then refuses every later write. */
    suspend fun close() {
        withContext(NonCancellable) {
            mutex.withLock {
                pendingWrite?.cancel()
                pendingWrite = null
                writeLocked()
                closed = true
            }
        }
    }

    private suspend fun mutate(block: () -> Unit) {
        mutex.withLock {
            if (closed) return@withLock
            loadLocked()
            block()
            mutableCoverage.value = coverageLocked(titles.size)
            scheduleWriteLocked()
        }
    }

    private fun upsert(publication: Publication, observedAt: Long, rank: Pair<Long, Int>?) {
        val existing = titles[publication.id]
        if (existing != null && existing.seenAtEpochMs > observedAt) {
            // A newer answer is already here; an older page may still carry a rank.
            if (rank != null && (existing.rankPassEpochMs ?: Long.MIN_VALUE) <= rank.first) {
                titles[publication.id] = existing.copy(rankPassEpochMs = rank.first, rankOffset = rank.second)
            }
            return
        }
        titles.remove(publication.id)
        titles[publication.id] = CachedTitle(
            publication = publication,
            seenAtEpochMs = observedAt,
            rankPassEpochMs = rank?.first ?: existing?.rankPassEpochMs,
            rankOffset = rank?.second ?: existing?.rankOffset,
        )
    }

    /** The whole unfiltered library was seen: forget titles the server no longer lists. */
    private fun completePass(pass: Pass) {
        val keep = protectedIds()
        titles.values.removeAll { it.publication.id !in pass.ids && it.seenAtEpochMs < pass.startedAt && it.publication.id !in keep }
        completeAsOf = maxOf(completeAsOf ?: 0, pass.startedAt)
    }

    private fun trim() {
        if (titles.size <= maxTitles) return
        val keep = protectedIds()
        val evictable = titles.values.filter { it.publication.id !in keep }.sortedBy { it.seenAtEpochMs }
        val excess = titles.size - maxTitles
        evictable.take(excess).forEach { titles.remove(it.publication.id) }
        // Some of the library is no longer here, so it can't be called complete.
        if (excess > 0 && evictable.isNotEmpty()) completeAsOf = null
    }

    private fun coverageLocked(count: Int) = LibraryCoverage(count, lastOnlineAt, completeAsOf)

    private fun scheduleWriteLocked() {
        if (pendingWrite?.isActive == true) return
        pendingWrite = scope.launch(Dispatchers.IO) {
            delay(writeDelayMs)
            mutex.withLock {
                pendingWrite = null
                writeLocked()
            }
        }
    }

    private suspend fun writeLocked() {
        if (closed || !loaded) return
        val snapshot = StoredLibrary(titles = titles.values.toList(), lastOnlineAtEpochMs = lastOnlineAt, completeAsOfEpochMs = completeAsOf)
        withContext(Dispatchers.IO + NonCancellable) {
            try {
                file.parentFile?.mkdirs()
                val temporary = File(file.path + ".tmp")
                temporary.writeText(ApiJson.encodeToString(snapshot))
                if (!temporary.renameTo(file)) throw IOException("Could not replace ${file.name}")
            } catch (error: IOException) {
                // The in-memory copy still serves this session; the next change tries again.
                Log.w(TAG, "Could not save the offline library", error)
            } catch (error: SecurityException) {
                Log.w(TAG, "Could not save the offline library", error)
            }
        }
    }

    private suspend fun loadLocked() {
        if (loaded) return
        loaded = true
        val stored = withContext(Dispatchers.IO) { read() } ?: return
        stored.titles.forEach { titles[it.publication.id] = it }
        lastOnlineAt = stored.lastOnlineAtEpochMs
        completeAsOf = stored.completeAsOfEpochMs
        mutableCoverage.value = coverageLocked(titles.size)
    }

    private fun read(): StoredLibrary? {
        if (!file.isFile) return null
        return try {
            ApiJson.decodeFromString<StoredLibrary>(file.readText())
        } catch (error: IOException) {
            Log.w(TAG, "Could not read the offline library", error)
            null
        } catch (error: SerializationException) {
            quarantine(error)
        } catch (error: IllegalArgumentException) {
            quarantine(error)
        }
    }

    private fun quarantine(error: Exception): StoredLibrary? {
        // Metadata can always be fetched again; keep the bad copy for diagnosis only.
        Log.e(TAG, "The offline library is unreadable; starting again", error)
        if (!file.renameTo(File(file.path + ".unreadable"))) file.delete()
        return null
    }

    companion object {
        private const val TAG = "ShelfarrLibraryCache"
        const val DEFAULT_MAX_TITLES = 1_500
        private const val MAX_OPEN_PASSES = 8

        /** Case-, accent- and punctuation-insensitive text for local search. */
        fun normalize(text: String): String =
            Normalizer.normalize(text.lowercase(Locale.ROOT), Normalizer.Form.NFD)
                .replace(Regex("\\p{Mn}+"), "")
                .replace(Regex("[^\\p{L}\\p{N}]+"), " ")
                .trim()
    }
}
