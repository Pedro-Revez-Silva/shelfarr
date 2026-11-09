package org.shelfarr.app.core

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

data class CachedEpub(
    val file: File,
    /** True when the copy could not be checked against the server just now. */
    val unverified: Boolean,
    /** CBZ only: the generation's verified reading order, kept beside the copy for offline reopening. */
    val order: ReadingOrder? = null,
)

@Serializable
private data class EntryInfo(val etag: String? = null, val sizeBytes: Long = 0)

/**
 * A working copy of reading files (EPUB, PDF and CBZ) so the readers can open them from
 * disk. It lives in the cache directory: the OS may evict it, so this is not an offline
 * library, and online page streaming here is never reported as a download.
 *
 * Files are scoped by account and asset id. The server's ETag decides when a copy
 * is stale, and the token is only ever sent as a header by the HTTP stack. EPUB copies
 * keep the names earlier versions used. A CBZ copy is usable only with its verified
 * reading order beside it.
 */
class EpubCache(
    private val root: File,
    private val client: OkHttpClient,
    private val maxBytes: Long = 1L shl 30,
) {
    private val mutex = Mutex()
    private val orders = ReadingOrderClient(client)

    private fun entryDirectory(accountKey: String, assetId: String): File =
        File(File(root, accountKey), sha256(assetId))

    suspend fun obtain(
        accountKey: String,
        server: ServerAddress,
        asset: Asset,
        onProgress: (Float?) -> Unit = {},
    ): CachedEpub = mutex.withLock {
        withContext(Dispatchers.IO) {
            val url = server.resolve(asset.contentUrl)
            if (url == null || !server.contains(url)) throw ApiException.Protocol()
            val format = asset.declaredFormat ?: ReadingFormat.EPUB
            if (format.isPaged && asset.sizeBytes > format.maxBytes) throw UnreadableFile("This file is larger than Shelfarr can open")

            val directory = entryDirectory(accountKey, asset.id).apply { mkdirs() }
            val book = File(directory, fileName(format))
            val partial = File(directory, "book.part")
            val infoFile = File(directory, "book.json")
            val partialInfoFile = File(directory, "part.json")
            val info = readInfo(infoFile)

            if (book.exists() && info != null) {
                val check = Request.Builder().url(url).apply {
                    info.etag?.let { header("If-None-Match", it) }
                }.build()
                val response = try {
                    call(check)
                } catch (error: ApiException.Offline) {
                    // An untrusted certificate is not "offline": surface it.
                    if (error.certificate) throw error
                    onProgress(1f)
                    return@withContext CachedEpub(book, unverified = true, order = storedOrder(format, directory, book, asset))
                }
                response.use {
                    // Servers may ignore If-None-Match, so a 200 with the same tag is unchanged too.
                    val sameTag = info.etag != null && it.header("ETag") == info.etag
                    val sameSize = info.etag == null && info.sizeBytes == asset.sizeBytes
                    if (it.code == 304 || (it.isSuccessful && (sameTag || sameSize))) {
                        book.setLastModified(System.currentTimeMillis())
                        onProgress(1f)
                        return@withContext CachedEpub(book, unverified = false, order = currentOrder(format, server, directory, book, asset))
                    }
                    partial.delete()
                    partialInfoFile.delete()
                    if (!it.isSuccessful) failFor(it)
                    write(it, partial, append = false, expected = asset.sizeBytes, onProgress = onProgress, limit = limitFor(format, asset))
                    writeInfo(partialInfoFile, EntryInfo(it.header("ETag"), partial.length()))
                }
            } else {
                download(url, asset, partial, partialInfoFile, onProgress)
            }

            verify(partial, asset, format)
            val finished = readInfo(partialInfoFile) ?: EntryInfo(null, partial.length())
            book.delete()
            File(directory, ORDER_FILE).delete()
            if (!partial.renameTo(book)) throw IOException("Could not finish download")
            writeInfo(infoFile, finished)
            partialInfoFile.delete()
            trim(keep = directory)
            CachedEpub(book, unverified = false, order = currentOrder(format, server, directory, book, asset))
        }
    }

    /**
     * Online: the generation's order, fetched, checked against the copy's own ZIP directory
     * and saved beside it. A lost connection falls back to the saved order.
     */
    private suspend fun currentOrder(format: ReadingFormat, server: ServerAddress, directory: File, book: File, asset: Asset): ReadingOrder? {
        if (format != ReadingFormat.CBZ) return null
        val order = try {
            orders.fetch(server, asset)
        } catch (error: ApiException.Offline) {
            if (error.certificate) throw error
            return storedOrder(format, directory, book, asset) ?: throw error
        }
        ComicArchive.open(book, order.validate(asset), asset.sizeBytes).close()
        ReadingOrderFile.write(File(directory, ORDER_FILE), order)
        return order
    }

    private fun storedOrder(format: ReadingFormat, directory: File, book: File, asset: Asset): ReadingOrder? {
        if (format != ReadingFormat.CBZ) return null
        val order = ReadingOrderFile.read(File(directory, ORDER_FILE)) ?: throw ApiException.Offline()
        ComicArchive.open(book, order.validate(asset), asset.sizeBytes).close()
        return order
    }

    private fun limitFor(format: ReadingFormat, asset: Asset): Long? = when {
        !format.isPaged -> null
        asset.sizeBytes > 0 -> asset.sizeBytes
        else -> format.maxBytes
    }

    private fun fileName(format: ReadingFormat): String = when (format) {
        ReadingFormat.EPUB -> "book.epub"
        ReadingFormat.PDF -> "book.pdf"
        ReadingFormat.CBZ -> "book.cbz"
    }

    private suspend fun download(
        url: okhttp3.HttpUrl,
        asset: Asset,
        partial: File,
        partialInfoFile: File,
        onProgress: (Float?) -> Unit,
    ) {
        val resumeInfo = readInfo(partialInfoFile)
        val offset = if (partial.exists() && resumeInfo?.etag != null) partial.length() else 0L
        if (offset == 0L) partial.delete()
        val format = asset.declaredFormat ?: ReadingFormat.EPUB
        val limit = limitFor(format, asset)

        val request = Request.Builder().url(url).apply {
            if (offset > 0) {
                header("Range", "bytes=$offset-")
                header("If-Range", resumeInfo?.etag.orEmpty())
            }
        }.build()

        call(request).use { response ->
            when {
                response.code == 206 && offset > 0 && contentRangeStart(response) == offset ->
                    write(response, partial, append = true, expected = asset.sizeBytes, onProgress = onProgress, limit = limit)
                response.code == 200 -> {
                    writeInfo(partialInfoFile, EntryInfo(response.header("ETag"), asset.sizeBytes))
                    write(response, partial, append = false, expected = asset.sizeBytes, onProgress = onProgress, limit = limit)
                }
                response.code == 416 -> {
                    partial.delete()
                    partialInfoFile.delete()
                    throw ApiException.Server(416)
                }
                else -> failFor(response)
            }
        }
    }

    private fun contentRangeStart(response: Response): Long? =
        response.header("Content-Range")?.substringAfter("bytes ", "")?.substringBefore('-')?.toLongOrNull()

    private suspend fun write(
        response: Response,
        target: File,
        append: Boolean,
        expected: Long,
        onProgress: (Float?) -> Unit,
        /** PDF and CBZ only: stop at once rather than fill the disk past the announced size. */
        limit: Long? = null,
    ) {
        val context = kotlin.coroutines.coroutineContext
        val total = expected.takeIf { it > 0 } ?: response.body.contentLength().takeIf { it > 0 }
        RandomAccessFile(target, "rw").use { output ->
            if (!append) output.setLength(0)
            output.seek(output.length())
            var written = output.length()
            val buffer = ByteArray(64 * 1024)
            try {
                response.body.byteStream().use { input ->
                    while (true) {
                        context.ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (limit != null && written + count > limit) throw ApiException.Protocol()
                        output.write(buffer, 0, count)
                        written += count
                        onProgress(total?.let { (written.toFloat() / it).coerceIn(0f, 1f) })
                    }
                }
            } catch (error: IOException) {
                throw ApiException.Offline(error)
            }
        }
    }

    private fun verify(file: File, asset: Asset, format: ReadingFormat) {
        val lengthMatches = asset.sizeBytes <= 0 || file.length() == asset.sizeBytes
        if (!lengthMatches || !looksLike(format, file)) {
            file.delete()
            throw ApiException.Protocol()
        }
    }

    private suspend fun call(request: Request): Response = try {
        client.newCall(request).await()
    } catch (error: BlockedRedirectIOException) {
        throw ApiException.RedirectBlocked(error.location)
    } catch (error: IOException) {
        throw ApiException.Offline(error)
    }

    private fun failFor(response: Response): Nothing = throw when (response.code) {
        401 -> ApiException.Unauthorized()
        403 -> ApiException.Forbidden()
        404 -> ApiException.NotFound()
        in 500..599 -> ApiException.Server(response.code)
        else -> ApiException.Protocol()
    }

    /** Removes everything held for one account. */
    suspend fun clear(accountKey: String) = mutex.withLock {
        withContext(Dispatchers.IO) { File(root, accountKey).deleteRecursively() }
        Unit
    }

    private fun trim(keep: File) {
        val entries = root.listFiles().orEmpty()
            .flatMap { it.listFiles().orEmpty().toList() }
            .filter { it.isDirectory && it != keep }
            .sortedBy { entry -> entry.listFiles().orEmpty().maxOfOrNull(File::lastModified) ?: 0L }
        var total = entries.sumOf(::sizeOf) + sizeOf(keep)
        for (entry in entries) {
            if (total <= maxBytes) break
            total -= sizeOf(entry)
            entry.deleteRecursively()
        }
    }

    private fun sizeOf(directory: File): Long = directory.listFiles().orEmpty().sumOf { it.length() }

    private fun readInfo(file: File): EntryInfo? = try {
        if (file.exists()) ApiJson.decodeFromString<EntryInfo>(file.readText()) else null
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    private fun writeInfo(file: File, info: EntryInfo) = file.writeText(ApiJson.encodeToString(info))

    private companion object {
        const val ORDER_FILE = "order.json"
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).take(16).joinToString("") { "%02x".format(it) }
}
