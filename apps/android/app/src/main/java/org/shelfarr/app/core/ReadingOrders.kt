package org.shelfarr.app.core

import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Fetches a CBZ generation's reading order. The URL must resolve inside the configured
 * server (origin and subpath), the scoped HTTP stack refuses redirects that leave it,
 * and the body is read only up to 8 MiB.
 */
class ReadingOrderClient(private val client: OkHttpClient) {
    suspend fun fetch(server: ServerAddress, asset: Asset): ReadingOrder = withContext(Dispatchers.IO) {
        val reference = asset.readingOrderUrl?.takeIf(String::isNotBlank) ?: throw UnreadableFile("This comic has no page list")
        val url = server.resolve(reference)?.takeIf(server::contains) ?: throw ApiException.Protocol()
        val request = Request.Builder().url(url).get().header("Accept", "application/json").build()
        val response = try {
            client.newCall(request).await()
        } catch (error: BlockedRedirectIOException) {
            throw ApiException.RedirectBlocked(error.location)
        } catch (error: IOException) {
            throw ApiException.Offline(error)
        }
        response.use {
            when (it.code) {
                200 -> Unit
                401 -> throw ApiException.Unauthorized()
                403 -> throw ApiException.Forbidden()
                404 -> throw ApiException.NotFound()
                410 -> throw GenerationGone()
                in 500..599 -> throw ApiException.Server(it.code)
                else -> throw ApiException.Protocol()
            }
            val declared = it.body.contentLength()
            if (declared > ComicLimits.MAX_ORDER_RESPONSE_BYTES) throw ApiException.Protocol()
            val bytes = try {
                it.body.byteStream().use { input -> readBounded(input, ComicLimits.MAX_ORDER_RESPONSE_BYTES) }
            } catch (error: IOException) {
                throw ApiException.Offline(error)
            } ?: throw ApiException.Protocol()
            decode(bytes.decodeToString()) ?: throw ApiException.Protocol()
        }
    }

    private fun readBounded(input: java.io.InputStream, limit: Long): ByteArray? {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return output.toByteArray()
            total += count
            if (total > limit) return null
            output.write(buffer, 0, count)
        }
    }

    companion object {
        fun decode(text: String): ReadingOrder? = try {
            ApiJson.decodeFromString<ReadingOrder>(text)
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}

/** A verified reading order kept beside its archive, so the comic opens offline. */
object ReadingOrderFile {
    /** Atomic: an interrupted write never leaves a half-written order beside a ready archive. */
    fun write(file: File, order: ReadingOrder) {
        val temporary = File(file.path + ".tmp")
        temporary.writeText(ApiJson.encodeToString(order))
        if (!temporary.renameTo(file)) {
            temporary.delete()
            throw IOException("Could not save the comic's page list")
        }
    }

    fun read(file: File): ReadingOrder? {
        if (!file.isFile || file.length() > ComicLimits.MAX_ORDER_RESPONSE_BYTES) return null
        return try {
            ReadingOrderClient.decode(file.readText())
        } catch (_: IOException) {
            null
        }
    }
}

/** True when a PDF header appears within the first KiB, as the server requires. */
internal fun hasPdfHeader(file: File): Boolean {
    val head = ByteArray(1024)
    val count = file.inputStream().use { input ->
        var read = 0
        while (read < head.size) {
            val n = input.read(head, read, head.size - read)
            if (n < 0) break
            read += n
        }
        read
    }
    val text = String(head, 0, count, Charsets.ISO_8859_1)
    val at = text.indexOf("%PDF-")
    return at >= 0 && at + 8 <= count && text[at + 5].isDigit() && text[at + 6] == '.' && text[at + 7].isDigit()
}

/** Cheap format check before a file may be called complete. */
internal fun looksLike(format: ReadingFormat?, file: File): Boolean = when (format) {
    ReadingFormat.EPUB, ReadingFormat.CBZ -> file.inputStream().use { it.read() == 'P'.code && it.read() == 'K'.code }
    ReadingFormat.PDF -> hasPdfHeader(file)
    null -> true
}
