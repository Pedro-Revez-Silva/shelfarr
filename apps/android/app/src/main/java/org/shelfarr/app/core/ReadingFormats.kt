package org.shelfarr.app.core

/**
 * The reading formats this app can open, as declared to the server with
 * [READER_FORMATS_HEADER]. A server that predates the header ignores it and keeps
 * sending only EPUB files for books, so an older server never offers a PDF or CBZ.
 */
enum class ReadingFormat(
    val wire: String,
    val label: String,
    /** The largest file the server promises to offer in this format. */
    val maxBytes: Long,
) {
    EPUB("epub", "EPUB", Long.MAX_VALUE),
    PDF("pdf", "PDF", 500L shl 20),
    CBZ("cbz", "Comic (CBZ)", 2L shl 30),
    ;

    /** Fixed-layout pages: no reflowing text, no EPUB typography. */
    val isPaged: Boolean get() = this != EPUB

    companion object {
        fun fromWire(value: String?): ReadingFormat? = entries.firstOrNull { it.wire == value }
    }
}

const val READER_FORMATS_HEADER = "X-Shelfarr-Reader-Formats"

/** Every format this build reads. The server normalizes order and duplicates. */
val READER_FORMATS: String = ReadingFormat.entries.joinToString(",") { it.wire }

const val PDF_MEDIA_TYPE = "application/pdf"
const val CBZ_MEDIA_TYPE = "application/vnd.comicbook+zip"

/** What a reader should open for one publication, before anything is fetched. */
sealed interface FormatChoice {
    data class Use(val asset: Asset) : FormatChoice

    /** More than one format, and nothing saved says which: the reader picks. */
    data class Ask(val options: List<Asset>) : FormatChoice
    data object None : FormatChoice

    companion object {
        /**
         * A saved place keeps its own format. Otherwise a ready download's format, then
         * the only format there is. Several formats with nothing to go on ask, rather
         * than guessing and starting a different file from its first page.
         */
        fun decide(publication: Publication, saved: SavedPosition?, downloadedAssetId: String? = null): FormatChoice {
            val readable = publication.readingAssets
            if (readable.isEmpty()) return None
            readable.firstOrNull { it.id == saved?.assetId }?.let { return Use(it) }
            readable.firstOrNull { it.id == downloadedAssetId }?.let { return Use(it) }
            return if (readable.size == 1) Use(readable.single()) else Ask(readable)
        }
    }
}
