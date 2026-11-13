package org.shelfarr.app.reader.pages

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.LruCache
import androidx.core.graphics.createBitmap
import java.io.Closeable
import java.io.File
import java.io.IOException
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.shelfarr.app.core.ComicArchive
import org.shelfarr.app.core.ComicPage
import org.shelfarr.app.core.UnreadableFile

/**
 * A fixed-layout book: a PDF or a comic. Pages render off the main thread into bitmaps
 * no larger than asked, and never larger than [MAX_PAGE_PIXELS].
 */
interface PageDocument : Closeable {
    val pageCount: Int

    /** Renders page [index] (0-based) to fit within [maxWidth] × [maxHeight] pixels, keeping its shape. */
    suspend fun render(index: Int, maxWidth: Int, maxHeight: Int): Bitmap
}

/** About 32 MiB of ARGB pixels: enough for a sharp zoomed phone or tablet page, bounded for memory. */
const val MAX_PAGE_PIXELS = 8_000_000L

/** Fits a [width] × [height] page inside the box and inside [MAX_PAGE_PIXELS]. */
internal fun fit(width: Int, height: Int, maxWidth: Int, maxHeight: Int): Pair<Int, Int> {
    val boxWidth = maxWidth.coerceAtLeast(1)
    val boxHeight = maxHeight.coerceAtLeast(1)
    var scale = minOf(boxWidth.toDouble() / width, boxHeight.toDouble() / height)
    val pixels = width * scale * height * scale
    if (pixels > MAX_PAGE_PIXELS) scale *= sqrt(MAX_PAGE_PIXELS / pixels)
    return (width * scale).roundToInt().coerceAtLeast(1) to (height * scale).roundToInt().coerceAtLeast(1)
}

/**
 * A PDF rendered by the platform's `android.graphics.pdf.PdfRenderer` (API 21+; this app's
 * minimum is 26). The renderer allows one open page at a time and, before Android 15, is
 * not thread-safe, so every call is serialized on one worker. It runs no PDF JavaScript,
 * forms or links. Password-protected or damaged files fail visibly at open.
 */
class PdfPages private constructor(
    private val descriptor: ParcelFileDescriptor,
    private val renderer: PdfRenderer,
    private val worker: CoroutineDispatcher,
) : PageDocument {
    private val lock = Any()
    private var closed = false

    override val pageCount: Int = renderer.pageCount

    override suspend fun render(index: Int, maxWidth: Int, maxHeight: Int): Bitmap = withContext(worker) {
        synchronized(lock) {
            if (closed) throw UnreadableFile("This book was closed")
            try {
                renderer.openPage(index).use { page ->
                    if (page.width <= 0 || page.height <= 0) throw UnreadableFile("Page ${index + 1} has no size")
                    val (width, height) = fit(page.width, page.height, maxWidth, maxHeight)
                    val bitmap = createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    // PDF pages are drawn onto paper; transparent areas would show the reader's background.
                    bitmap.eraseColor(Color.WHITE)
                    // No transform: the platform fits the whole page to the bitmap.
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bitmap
                }
            } catch (error: IllegalStateException) {
                throw UnreadableFile("Page ${index + 1} couldn't be drawn", error)
            } catch (error: IllegalArgumentException) {
                throw UnreadableFile("Page ${index + 1} couldn't be drawn", error)
            }
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            runCatching { renderer.close() }
            runCatching { descriptor.close() }
        }
    }

    companion object {
        /** The contract bounds PDF positions at 100,000 pages. */
        const val MAX_PAGES = 100_000

        /** Opens [file] on [worker], or throws [UnreadableFile]. Call off the main thread. */
        fun open(file: File, worker: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1)): PdfPages {
            val descriptor = try {
                ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            } catch (error: IOException) {
                throw UnreadableFile("The PDF file is missing", error)
            }
            val renderer = try {
                PdfRenderer(descriptor)
            } catch (error: SecurityException) {
                descriptor.close()
                throw UnreadableFile("This PDF is password-protected, so Shelfarr can't open it", error)
            } catch (error: IOException) {
                descriptor.close()
                throw UnreadableFile("This PDF is damaged or isn't a PDF", error)
            } catch (error: RuntimeException) {
                descriptor.close()
                throw UnreadableFile("This PDF is damaged or isn't a PDF", error)
            }
            val count = renderer.pageCount
            if (count !in 1..MAX_PAGES) {
                renderer.close()
                descriptor.close()
                throw UnreadableFile(if (count < 1) "This PDF has no pages" else "This PDF has more pages than Shelfarr can track")
            }
            return PdfPages(descriptor, renderer, worker)
        }
    }
}

/**
 * A comic's pages, inflated one at a time from the verified archive and decoded at the
 * smallest sample size that still fills the requested box. The image must be the type
 * the page list declares, and is never decoded beyond [MAX_PAGE_PIXELS].
 */
class ComicPages(
    private val archive: ComicArchive,
    private val worker: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(2),
) : PageDocument {
    override val pageCount: Int get() = archive.pageCount

    val pages: List<ComicPage> get() = archive.pages

    override suspend fun render(index: Int, maxWidth: Int, maxHeight: Int): Bitmap = withContext(worker) {
        val page = archive.pages[index]
        val bytes = archive.pageBytes(index)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) throw UnreadableFile("Page ${page.position} isn't an image this device can show")
        if (bounds.outMimeType != null && bounds.outMimeType != page.mediaType) {
            throw UnreadableFile("Page ${page.position} isn't the kind of image its page list says")
        }
        if (width > MAX_SIDE || height > MAX_SIDE) throw UnreadableFile("Page ${page.position} is too large to show")
        val (targetWidth, targetHeight) = fit(width, height, maxWidth, maxHeight)
        var sample = 1
        while (width / (sample * 2) >= targetWidth && height / (sample * 2) >= targetHeight) sample *= 2
        while ((width.toLong() / sample) * (height.toLong() / sample) > MAX_PAGE_PIXELS) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw UnreadableFile("Page ${page.position} couldn't be decoded")
    }

    override fun close() = archive.close()

    private companion object {
        /** No real page is wider or taller than this; a larger header is a decompression bomb. */
        const val MAX_SIDE = 30_000
    }
}

/** Recently drawn pages, bounded by bytes so paging through a long book can't exhaust memory. */
class PageBitmapCache(maxBytes: Int) {
    private val cache = object : LruCache<String, Bitmap>(maxBytes) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
    }

    fun get(key: String): Bitmap? = cache.get(key)

    fun put(key: String, bitmap: Bitmap) {
        cache.put(key, bitmap)
    }

    fun clear() = cache.evictAll()

    companion object {
        fun forRuntime(): PageBitmapCache {
            val budget = (Runtime.getRuntime().maxMemory() / 6).coerceIn(16L shl 20, 96L shl 20)
            return PageBitmapCache(budget.toInt())
        }
    }
}
