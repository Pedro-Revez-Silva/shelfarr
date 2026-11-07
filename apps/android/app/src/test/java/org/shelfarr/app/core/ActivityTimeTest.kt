package org.shelfarr.app.core

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ActivityTimeTest {
    @Test
    fun `formats UTC with milliseconds and parses zoned times back`() {
        assertEquals("2026-11-07T09:00:00.000Z", ActivityTime.format(TEST_EPOCH))
        assertEquals("2026-11-07T09:00:00.007Z", ActivityTime.format(TEST_EPOCH + 7))
        assertEquals(TEST_EPOCH + 7, ActivityTime.parse("2026-11-07T09:00:00.007Z"))
        assertEquals(TEST_EPOCH, ActivityTime.parse("2026-11-07T10:00:00+01:00"))
        assertEquals(TEST_EPOCH + 123, ActivityTime.parse("2026-11-07T09:00:00.123456789Z"))
    }

    @Test
    fun `missing, zoneless and impossible times are unknown`() {
        for (value in listOf(null, "", "2026-11-07T09:00:00", "2026-11-07T09:00Z", "2026-02-30T09:00:00Z", "2026-11-07T24:00:00Z", "yesterday", "1794042000000")) {
            assertNull(value, ActivityTime.parse(value))
        }
    }

    @Test
    fun `plausible means set and not more than five minutes ahead`() {
        assertTrue(ActivityTime.isPlausible(TEST_EPOCH + 5 * 60_000, TEST_EPOCH))
        assertFalse(ActivityTime.isPlausible(TEST_EPOCH + 5 * 60_000 + 1, TEST_EPOCH))
        assertFalse(ActivityTime.isPlausible(86_400_000, TEST_EPOCH))
        assertFalse(ActivityTime.isPlausible(null, TEST_EPOCH))
    }

    @Test
    fun `a new local observation never sorts before the previous one on this device`() {
        assertEquals(TEST_EPOCH, ActivityTime.next(TEST_EPOCH, null))
        assertEquals(TEST_EPOCH, ActivityTime.next(TEST_EPOCH, TEST_EPOCH - 1))
        assertEquals(TEST_EPOCH + 1, ActivityTime.next(TEST_EPOCH, TEST_EPOCH))
        assertEquals(TEST_EPOCH + 2_001, ActivityTime.next(TEST_EPOCH, TEST_EPOCH + 2_000))
        // A wildly wrong earlier time is not carried forward.
        assertEquals(TEST_EPOCH, ActivityTime.next(TEST_EPOCH, TEST_EPOCH + 3_600_000))
    }

    @Test
    fun `the wire carries observed_at and only a true resolve_conflict`() {
        val automatic = PendingMutation(SavedPosition("a", positionSeconds = 1.5), 2, "m", TEST_EPOCH).toUpdate()
        val body = ApiJson.parseToJsonElement(ApiJson.encodeToString(automatic)).jsonObject
        assertEquals("\"2026-11-07T09:00:00.000Z\"", body["observed_at"].toString())
        assertFalse("resolve_conflict" in body)

        val choice = PendingMutation(SavedPosition("a", positionSeconds = 1.5), 2, "m", TEST_EPOCH, resolveConflict = true).toUpdate()
        assertTrue(ApiJson.encodeToString(choice).contains("\"resolve_conflict\":true"))

        val unknown = PendingMutation(SavedPosition("a", positionSeconds = 1.5), 2, "m").toUpdate()
        assertFalse(ApiJson.encodeToString(unknown).contains("observed_at"))
    }

    @Test
    fun `progress responses expose the activity time, or none from older servers`() {
        val current = ApiJson.decodeFromString<Progress>(
            """{"asset_id":"a","position_seconds":3.0,"version":2,"observed_at":"2026-11-07T09:00:00.000Z","updated_at":"2026-11-07T10:00:00Z"}""",
        )
        assertEquals(TEST_EPOCH, current.observedAtEpochMs)
        val older = ApiJson.decodeFromString<Progress>("""{"asset_id":"a","position_seconds":3.0,"version":2,"updated_at":"2026-11-07T10:00:00Z"}""")
        assertNull("never the upload time", older.observedAtEpochMs)
        val nulled = ApiJson.decodeFromString<Progress>("""{"asset_id":"a","version":2,"observed_at":null}""")
        assertNull(nulled.observedAtEpochMs)
    }
}
