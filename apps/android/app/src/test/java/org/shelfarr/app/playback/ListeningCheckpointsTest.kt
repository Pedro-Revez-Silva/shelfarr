package org.shelfarr.app.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.shelfarr.app.core.SavedPosition

class ListeningCheckpointsTest {
    private fun at(seconds: Double, track: String = "t1") = SavedPosition(track, positionSeconds = seconds)

    @Test
    fun `opening a saved place starts five seconds earlier within its track`() {
        assertEquals(95_000, ListeningCheckpoints().open(at(100.0), "t1"))
        assertEquals("clamped to the track start", 0, ListeningCheckpoints().open(at(3.2), "t1"))
        assertEquals(0, ListeningCheckpoints().open(null, "t1"))
    }

    @Test
    fun `the replayed pre-roll does not replace the saved place`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(at(100.0), "t1")
        assertFalse(checkpoints.isActivity(at(95.0)))
        assertFalse(checkpoints.isActivity(at(99.9)))
        assertFalse(checkpoints.isActivity(at(100.0)))
        assertTrue(checkpoints.isActivity(at(100.5)))
        assertTrue("once passed, everything counts", checkpoints.isActivity(at(50.0)))
    }

    @Test
    fun `a natural move into the next track ends the pre-roll`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(at(598.0, "t1"), "t1")
        assertFalse(checkpoints.isActivity(at(594.0, "t1")))
        assertTrue(checkpoints.isActivity(at(0.2, "t2")))
    }

    @Test
    fun `restarting paused playback rewinds once`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(null, "t1")
        checkpoints.paused()
        assertEquals(195_000L, checkpoints.resumed(at(200.0)))
        assertNull("only once per resume", checkpoints.resumed(at(195.0)))
        assertFalse("the place it was paused at stays saved", checkpoints.isActivity(at(197.0)))
        assertTrue(checkpoints.isActivity(at(200.5)))
    }

    @Test
    fun `a pause during the pre-roll keeps the original place, not the earlier one`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(at(100.0), "t1")
        checkpoints.paused()
        assertEquals(92_000L, checkpoints.resumed(at(97.0)))
        assertFalse(checkpoints.isActivity(at(99.0)))
        assertTrue(checkpoints.isActivity(at(100.1)))
    }

    @Test
    fun `opening at the beginning is not activity until playback moves`() {
        val checkpoints = ListeningCheckpoints()
        assertEquals(0, checkpoints.open(null, "t1"))
        assertFalse(checkpoints.isActivity(at(0.0)))
        assertTrue(checkpoints.isActivity(at(0.5)))
    }

    @Test
    fun `a rewind is clamped to the start of the current track`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(null, "t1")
        checkpoints.paused()
        assertEquals(0L, checkpoints.resumed(at(2.0, "t3")))
        checkpoints.paused()
        assertNull("nothing earlier in this track", checkpoints.resumed(at(0.0, "t3")))
    }

    @Test
    fun `a deliberate seek or track choice is never rewound and counts at once`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(at(100.0), "t1")
        checkpoints.paused()
        checkpoints.movedDeliberately()
        assertNull(checkpoints.resumed(at(40.0)))
        assertTrue(checkpoints.isActivity(at(40.0)))
    }

    @Test
    fun `playing without a pause first never rewinds`() {
        val checkpoints = ListeningCheckpoints()
        checkpoints.open(at(100.0), "t1")
        assertNull(checkpoints.resumed(at(95.0)))
    }

    @Test
    fun `periodic checkpoints are due at most every four seconds`() {
        val checkpoints = ListeningCheckpoints()
        assertTrue(checkpoints.due(0))
        checkpoints.checkpointed(1_000)
        assertFalse(checkpoints.due(4_999))
        assertTrue(checkpoints.due(5_000))
        assertTrue(ListeningCheckpoints.CHECKPOINT_INTERVAL_MS < 5_000)
    }
}
