package org.shelfarr.app.core

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

/**
 * When a reading or listening checkpoint actually happened, as the wire's `observed_at`.
 *
 * Times travel as ISO-8601 UTC with milliseconds and are compared as epoch
 * milliseconds. A time is only trusted for ordering when it is well formed and
 * plausible: not before [EARLIEST] (a reset clock) and not more than
 * [FUTURE_TOLERANCE_MS] ahead of this device, which matches the server's limit.
 */
object ActivityTime {
    const val FUTURE_TOLERANCE_MS = 5 * 60_000L

    /** 2000-01-01T00:00:00Z. Anything earlier comes from a clock that was never set. */
    const val EARLIEST = 946_684_800_000L

    private val FORMAT: DateTimeFormatter =
        DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    // Seconds and an explicit zone are required, as on the server.
    private val SHAPE = Regex("""\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})""")

    fun format(epochMs: Long): String = FORMAT.format(Instant.ofEpochMilli(epochMs))

    /** Epoch milliseconds, or null when [value] is missing or not a zoned ISO-8601 time. */
    fun parse(value: String?): Long? {
        if (value == null || !SHAPE.matches(value)) return null
        return try {
            OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toEpochMilli()
        } catch (_: DateTimeParseException) {
            null
        }
    }

    /** True when [epochMs] can be trusted to order activity against this device's [now]. */
    fun isPlausible(epochMs: Long?, now: Long): Boolean =
        epochMs != null && epochMs >= EARLIEST && epochMs <= now + FUTURE_TOLERANCE_MS

    /**
     * The time to record for a new local observation. Activity on one device happens in
     * order, so a clock that stepped back a little (or an adopted place stamped by a
     * slightly fast clock elsewhere) must not make the newer place look older.
     */
    fun next(observed: Long, previous: Long?): Long =
        if (previous != null && previous >= observed && previous <= observed + FUTURE_TOLERANCE_MS) previous + 1 else observed
}
