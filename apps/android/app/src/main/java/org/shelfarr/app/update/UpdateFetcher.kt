package org.shelfarr.app.update

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import okhttp3.Call
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * The updater's own HTTP stack. It has no interceptors, cookies or cache and is never
 * given the Shelfarr server's credential, so nothing the account holds can reach the
 * publisher. OkHttp's redirects are off; [UpdateFetcher] checks each hop itself.
 */
fun buildUpdateHttpClient(): OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .writeTimeout(30, TimeUnit.SECONDS)
    .followRedirects(false)
    .followSslRedirects(false)
    .retryOnConnectionFailure(true)
    .build()

/** Fetches the feed and APK from the trusted [source] only. */
class UpdateFetcher(
    private val client: OkHttpClient,
    private val source: UpdateSource,
) {
    /** The feed body, at most [UpdateManifest.MAX_FEED_BYTES]. */
    suspend fun fetchFeed(): String = get(
        raw = source.feed.toString(),
        url = source.feed,
        allowed = source::allowsFeed,
        headers = {
            header("Accept", "application/json")
            header("Cache-Control", "no-cache")
        },
    ) { response ->
        val body = response.body
        if (body.contentLength() > UpdateManifest.MAX_FEED_BYTES) tooLargeFeed()
        val stream = body.source()
        if (stream.request(UpdateManifest.MAX_FEED_BYTES + 1)) tooLargeFeed()
        stream.buffer.readUtf8()
    }

    /**
     * Streams [release]'s APK into [destination], refusing more bytes than announced
     * and checking length and SHA-256 before returning. On any failure, cancellation
     * included, [destination] is deleted.
     */
    suspend fun download(release: UpdateRelease, destination: File, onProgress: (Long) -> Unit) {
        var complete = false
        try {
            get(
                raw = release.apkUrl.toString(),
                url = release.apkUrl,
                allowed = source::allowsArtifact,
                headers = {
                    // Byte-for-byte: a transparently decompressed body couldn't be checked against the feed.
                    header("Accept-Encoding", "identity")
                    header("Accept", "application/vnd.android.package-archive, application/octet-stream")
                },
            ) { response -> save(response, release, destination, onProgress) }
            complete = true
        } finally {
            if (!complete) destination.delete()
        }
    }

    /** Runs on an IO thread; a cancelled download closes its call, which ends this read. */
    private fun save(response: Response, release: UpdateRelease, destination: File, onProgress: (Long) -> Unit) {
        val body = response.body
        if (body.contentLength() > release.sizeBytes) {
            throw UpdateException(UpdateProblem.TOO_LARGE, "The update file is larger than announced")
        }
        val encoding = response.header("Content-Encoding")
        if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
            throw UpdateException(UpdateProblem.BAD_FEED, "The update server changed the file's encoding")
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BUFFER_BYTES)
        var total = 0L
        var reported = 0L
        try {
            FileOutputStream(destination).use { out ->
                body.byteStream().use { input ->
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > release.sizeBytes) {
                            throw UpdateException(UpdateProblem.TOO_LARGE, "The update file is larger than announced")
                        }
                        digest.update(buffer, 0, read)
                        out.write(buffer, 0, read)
                        if (total - reported >= PROGRESS_STEP_BYTES) {
                            reported = total
                            onProgress(total)
                        }
                    }
                }
                out.flush()
                out.fd.sync()
            }
        } catch (error: IOException) {
            if ((destination.parentFile?.usableSpace ?: Long.MAX_VALUE) < BUFFER_BYTES) {
                throw UpdateException(UpdateProblem.STORAGE, "There isn't enough space for the update", error)
            }
            throw offline(error, "The download stopped before it finished")
        }
        onProgress(total)
        if (total != release.sizeBytes) throw UpdateException(UpdateProblem.INCOMPLETE, "The update file ended early")
        if (digest.digest().toHex() != release.sha256) {
            throw UpdateException(UpdateProblem.CHECKSUM, "The update file doesn't match its published checksum")
        }
    }

    private sealed interface Hop<out T> {
        data class Done<T>(val value: T) : Hop<T>
        data class Redirect(val location: String) : Hop<Nothing>
    }

    /**
     * GETs [url], following up to [MAX_REDIRECTS] redirects, each of which [allowed]
     * must accept before anything is sent to it, then hands the 200 response to [read].
     */
    private suspend fun <T> get(
        raw: String,
        url: HttpUrl,
        allowed: (String, HttpUrl) -> Boolean,
        headers: Request.Builder.() -> Unit,
        read: (Response) -> T,
    ): T {
        var rawTarget = raw
        var target = url
        for (hop in 0..MAX_REDIRECTS) {
            if (!allowed(rawTarget, target)) throw untrusted()
            val call = client.newCall(Request.Builder().url(target).get().apply(headers).build())
            val outcome = cancellable(call) {
                val response = try {
                    call.execute()
                } catch (error: IOException) {
                    throw offline(error)
                }
                response.use {
                    when (it.code) {
                        200 -> try {
                            Hop.Done(read(it))
                        } catch (error: UpdateException) {
                            throw error
                        } catch (error: IOException) {
                            throw offline(error)
                        }
                        301, 302, 303, 307, 308 -> Hop.Redirect(
                            it.header("Location") ?: throw UpdateException(UpdateProblem.SERVER, "The update server sent a broken redirect"),
                        )
                        else -> throw UpdateException(UpdateProblem.SERVER, "The update server answered ${it.code}")
                    }
                }
            }
            when (outcome) {
                is Hop.Done -> return outcome.value
                is Hop.Redirect -> {
                    rawTarget = outcome.location
                    target = target.resolve(outcome.location) ?: throw untrusted()
                }
            }
        }
        throw UpdateException(UpdateProblem.UNTRUSTED_LOCATION, "The update server redirected too many times")
    }

    /** Runs blocking [work] on an IO thread; cancelling the caller cancels [call], unblocking it. */
    private suspend fun <T> cancellable(call: Call, work: () -> T): T = coroutineScope {
        val running = async(Dispatchers.IO) { work() }
        try {
            running.await()
        } catch (cancelled: CancellationException) {
            call.cancel()
            throw cancelled
        }
    }

    private fun untrusted() =
        UpdateException(UpdateProblem.UNTRUSTED_LOCATION, "The update server pointed somewhere this app doesn't trust")

    private fun offline(error: IOException, message: String = "Couldn't reach the update server"): UpdateException {
        // OkHttp reports the first route's failure and keeps later ones as suppressed: a
        // refused IPv6 address can hide the IPv4 address's certificate failure.
        fun Throwable.chain(): Sequence<Throwable> =
            generateSequence(this) { it.cause }.flatMap { sequenceOf(it) + it.suppressed.asSequence().flatMap { s -> s.chain() } }
        val untrusted = error.chain().any { it is SSLException }
        return UpdateException(
            UpdateProblem.OFFLINE,
            if (untrusted) "The update server's certificate couldn't be trusted" else message,
            error,
        )
    }

    private fun tooLargeFeed(): Nothing = throw UpdateException(UpdateProblem.BAD_FEED, "The update feed is too large")

    private companion object {
        const val MAX_REDIRECTS = 3
        const val BUFFER_BYTES = 64 * 1024
        const val PROGRESS_STEP_BYTES = 256L * 1024
    }
}

internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

/** Lowercase hex SHA-256 of [file]. */
internal fun sha256Of(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().toHex()
}
