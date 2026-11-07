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
)

@Serializable
private data class EntryInfo(val etag: String? = null, val sizeBytes: Long = 0)

/**
 * A working copy of EPUB files so Readium can open them from disk. It lives in the
 * cache directory: the OS may evict it, so this is not an offline library.
 *
 * Files are scoped by account and asset id. The server's ETag decides when a copy
 * is stale, and the token is only ever sent as a header by the HTTP stack.
 */
class EpubCache(
    private val root: File,
    private val client: OkHttpClient,
    private val maxBytes: Long = 1L shl 30,
) {
    private val mutex = Mutex()

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

            val directory = entryDirectory(accountKey, asset.id).apply { mkdirs() }
            val book = File(directory, "book.epub")
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
                } catch (_: ApiException.Offline) {
                    onProgress(1f)
                    return@withContext CachedEpub(book, unverified = true)
                }
                response.use {
                    if (it.code == 304 || (it.isSuccessful && info.etag == null && info.sizeBytes == asset.sizeBytes)) {
                        book.setLastModified(System.currentTimeMillis())
                        onProgress(1f)
                        return@withContext CachedEpub(book, unverified = false)
                    }
                    partial.delete()
                    partialInfoFile.delete()
                    if (!it.isSuccessful) failFor(it)
                    write(it, partial, append = false, expected = asset.sizeBytes, onProgress = onProgress)
                    writeInfo(partialInfoFile, EntryInfo(it.header("ETag"), partial.length()))
                }
            } else {
                download(url, asset, partial, partialInfoFile, onProgress)
            }

            verify(partial, asset)
            val finished = readInfo(partialInfoFile) ?: EntryInfo(null, partial.length())
            book.delete()
            if (!partial.renameTo(book)) throw IOException("Could not finish download")
            writeInfo(infoFile, finished)
            partialInfoFile.delete()
            trim(keep = directory)
            CachedEpub(book, unverified = false)
        }
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

        val request = Request.Builder().url(url).apply {
            if (offset > 0) {
                header("Range", "bytes=$offset-")
                header("If-Range", resumeInfo?.etag.orEmpty())
            }
        }.build()

        call(request).use { response ->
            when {
                response.code == 206 && offset > 0 && contentRangeStart(response) == offset ->
                    write(response, partial, append = true, expected = asset.sizeBytes, onProgress = onProgress)
                response.code == 200 -> {
                    writeInfo(partialInfoFile, EntryInfo(response.header("ETag"), asset.sizeBytes))
                    write(response, partial, append = false, expected = asset.sizeBytes, onProgress = onProgress)
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

    private fun verify(file: File, asset: Asset) {
        val lengthMatches = asset.sizeBytes <= 0 || file.length() == asset.sizeBytes
        val looksLikeZip = file.inputStream().use { it.read() == 'P'.code && it.read() == 'K'.code }
        if (!lengthMatches || !looksLikeZip) {
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
            .sortedBy { File(it, "book.epub").lastModified() }
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

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).take(16).joinToString("") { "%02x".format(it) }
}
