package org.shelfarr.app.core

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString

/** The last-seen details of a book, so a working copy can reopen without a connection. */
class AccountPublications(accountDirectory: File) {
    private val directory = File(accountDirectory, "publications")

    private fun file(id: String): File = File(directory, "${id.hashCode().toUInt()}-${id.length}.json")

    suspend fun remember(publication: Publication) = withContext(Dispatchers.IO) {
        directory.mkdirs()
        file(publication.id).writeText(ApiJson.encodeToString(publication))
    }

    suspend fun recall(id: String): Publication? = withContext(Dispatchers.IO) {
        val stored = file(id)
        if (!stored.exists()) return@withContext null
        try {
            ApiJson.decodeFromString<Publication>(stored.readText()).takeIf { it.id == id }
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
    }
}
