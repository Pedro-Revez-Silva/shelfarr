package org.shelfarr.app.core

import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FileProgressStoreTest {
    @get:Rule val folder = TemporaryFolder()

    @Test
    fun `round-trips across instances and lists unsynced records`() = runTest {
        val file = File(folder.root, "a/progress.json")
        val record = LocalProgress("p", SavedPosition("a", positionSeconds = 3.0), baseVersion = 2, dirty = true)
        FileProgressStore(file).put(record)
        FileProgressStore(file).put(LocalProgress("clean"))

        val reopened = FileProgressStore(file)
        assertEquals(record, reopened.get("p"))
        assertEquals(listOf("p"), reopened.unsynced().map { it.publicationId })
    }

    @Test
    fun `a closed store cannot recreate its file after a wipe`() = runTest {
        val file = File(folder.root, "account/progress.json")
        val store = FileProgressStore(file)
        store.put(LocalProgress("p"))
        store.close()
        file.parentFile!!.deleteRecursively()

        store.put(LocalProgress("late"))

        assertEquals(false, file.exists())
    }

    @Test
    fun `a damaged file reads as empty and is set aside rather than overwritten`() = runTest {
        val file = folder.newFile("progress.json").apply { writeText("{nope") }
        val store = FileProgressStore(file)
        assertNull(store.get("p"))
        store.put(LocalProgress("p"))
        assertEquals("{nope", File(file.path + ".damaged").readText())
    }

    @Test
    fun `a store from before activity times opens with unknown times and keeps its queued write`() = runTest {
        val file = folder.newFile("progress.json").apply {
            writeText(
                """{"p":{"publicationId":"p","position":{"assetId":"a","positionSeconds":12.5},"baseVersion":2,"dirty":true,""" +
                    """"pending":{"position":{"assetId":"a","positionSeconds":10.0},"expectedVersion":2,"mutationId":"m-old"},""" +
                    """"updatedAtEpochMs":1700000000000}}""",
            )
        }
        val store = FileProgressStore(file)
        val record = requireNotNull(store.get("p"))
        assertEquals(SavedPosition("a", positionSeconds = 12.5), record.position)
        assertNull("never borrowed from updatedAtEpochMs", record.observedAtEpochMs)
        assertEquals(PendingMutation(SavedPosition("a", positionSeconds = 10.0), 2, "m-old"), record.pending)
        assertNull(record.pending!!.toUpdate().observedAt)
        assertNull(record.pending!!.toUpdate().resolveConflict)
        assertEquals(listOf("p"), store.unsynced().map { it.publicationId })

        // A new write keeps the old record readable for the previous format's fields.
        store.put(record.copy(observedAtEpochMs = 5))
        assertEquals(5L, FileProgressStore(file).get("p")?.observedAtEpochMs)
    }

    @Test
    fun `a write that can't reach the disk is reported`() = runTest {
        val blocker = folder.newFile("not-a-directory")
        val store = FileProgressStore(File(blocker, "progress.json"))
        val failure = runCatching { store.put(LocalProgress("p")) }.exceptionOrNull()
        assertTrue(failure is java.io.IOException)
    }

    @Test
    fun `refused records are not sent in the background`() = runTest {
        val file = File(folder.root, "progress.json")
        val store = FileProgressStore(file)
        store.put(LocalProgress("p", SavedPosition("a", positionSeconds = 3.0), dirty = true, rejected = true))
        assertTrue(store.unsynced().isEmpty())
        assertTrue(store.get("p")!!.hasUnsyncedChanges)
    }
}
