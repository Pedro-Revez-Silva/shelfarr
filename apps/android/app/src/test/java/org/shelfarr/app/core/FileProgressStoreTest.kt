package org.shelfarr.app.core

import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
    fun `a damaged file reads as empty`() = runTest {
        val file = folder.newFile("progress.json").apply { writeText("{nope") }
        assertNull(FileProgressStore(file).get("p"))
    }
}
