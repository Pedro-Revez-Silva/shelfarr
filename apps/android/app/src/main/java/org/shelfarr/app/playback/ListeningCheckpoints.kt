package org.shelfarr.app.playback

import org.shelfarr.app.core.SavedPosition

/**
 * When listening becomes a saved checkpoint, and where a resume restarts.
 *
 * Pure state, driven by [PlaybackController] from Media3 callbacks so it can be tested
 * without a player:
 * - While playing, a checkpoint is due at most every [intervalMs] of elapsed time.
 * - A genuine resume (opening a saved place, or playing again after a pause) restarts
 *   [REWIND_MS] earlier, clamped to the start of the current track. It applies once
 *   per resume, never after a deliberate seek or track choice.
 * - The rewound pre-roll is not new activity: the place resumed from stays the saved
 *   checkpoint until playback passes it or the listener deliberately moves.
 */
class ListeningCheckpoints(private val intervalMs: Long = CHECKPOINT_INTERVAL_MS) {
    private var held: SavedPosition? = null
    private var lastCheckpointAt: Long? = null
    private var rewindArmed = false

    /**
     * A saved place, or the start of [firstTrack] when there is none, is being opened.
     * Returns where to start in its track, in milliseconds. Opening is not activity, so
     * the place itself is held until playback moves beyond it.
     */
    fun open(saved: SavedPosition?, firstTrack: String): Long {
        val savedMs = saved?.millis() ?: 0
        held = saved ?: SavedPosition(firstTrack, positionSeconds = 0.0)
        rewindArmed = false
        lastCheckpointAt = null
        return rewound(savedMs)
    }

    /** Playback was paused, by anyone: the next requested play is a resume. */
    fun paused() {
        rewindArmed = true
    }

    /** The listener chose a place or track: no rewind for it, and it is real activity. */
    fun movedDeliberately() {
        rewindArmed = false
        held = null
    }

    /**
     * Someone asked to play at [current]. Returns the earlier place to restart from when
     * this resumes paused playback, or null to carry on where it is.
     */
    fun resumed(current: SavedPosition): Long? {
        if (!rewindArmed) return null
        rewindArmed = false
        val currentMs = current.millis()
        val target = rewound(currentMs)
        if (target >= currentMs) return null
        // Keep the place it was paused at until playback passes it again.
        val place = held
        if (place == null || place.assetId != current.assetId || place.millis() < currentMs) held = current
        return target
    }

    /** False while [position] is only the opened place or the replayed pre-roll before it. */
    fun isActivity(position: SavedPosition): Boolean {
        val place = held ?: return true
        if (position.assetId == place.assetId && position.millis() <= place.millis()) return false
        held = null
        return true
    }

    /** Whether a periodic checkpoint is due at [elapsedMs] (a monotonic clock). */
    fun due(elapsedMs: Long): Boolean = lastCheckpointAt?.let { elapsedMs - it >= intervalMs } ?: true

    fun checkpointed(elapsedMs: Long) {
        lastCheckpointAt = elapsedMs
    }

    private fun SavedPosition.millis(): Long = ((positionSeconds ?: 0.0) * 1_000).toLong().coerceAtLeast(0)

    companion object {
        const val REWIND_MS = 5_000L

        /**
         * Ticks come every half second, so checking at four seconds keeps the gap between
         * checkpoints under five seconds even when a tick runs late.
         */
        const val CHECKPOINT_INTERVAL_MS = 4_000L

        fun rewound(positionMs: Long): Long = (positionMs - REWIND_MS).coerceAtLeast(0)
    }
}
