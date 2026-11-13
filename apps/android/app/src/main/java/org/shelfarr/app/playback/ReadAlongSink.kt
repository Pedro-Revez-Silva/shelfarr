package org.shelfarr.app.playback

import org.shelfarr.app.core.HeardPlaceMapper
import org.shelfarr.app.core.HeardPlaces
import org.shelfarr.app.core.ProgressSync

/**
 * Listening checkpoints for read-along narration (docs/read-along.md, Saved places).
 *
 * A checkpoint heard at an exact narration point becomes the ebook place of the cue reached
 * there (its element plus the offset; nothing before the first cue) and, for an imported
 * alignment, the paired audiobook's own file and second. Both are saved on this device with
 * one identical activity time before either may be sent.
 */
class ReadAlongSink(
    private val mapper: HeardPlaceMapper,
    private val ebook: ProgressSync,
    private val audiobook: ProgressSync?,
    /** Told about every place written, for the reader's own state. */
    private val onRecorded: (HeardPlaces) -> Unit = {},
) : ListeningSink {
    override suspend fun record(trackIndex: Int, mediaId: String, positionMs: Long, observedAtEpochMs: Long) {
        val places = mapper.placesAt(trackIndex, positionMs)
        val paired = audiobook?.takeIf { places.audiobook != null }
        if (places.ebook == null && paired == null) return
        ProgressSync.together {
            var time = observedAtEpochMs
            if (places.ebook != null) time = maxOf(time, ebook.observationTime(observedAtEpochMs))
            if (paired != null) time = maxOf(time, paired.observationTime(observedAtEpochMs))
            places.ebook?.let { ebook.update(it, time, send = false) }
            places.audiobook?.let { paired?.update(it, time, send = false) }
        }
        ebook.requestSend()
        paired?.requestSend()
        onRecorded(places)
    }

    override suspend fun flush() {
        ebook.flush()
        audiobook?.flush()
    }
}
