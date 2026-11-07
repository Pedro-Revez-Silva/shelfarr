package org.shelfarr.app.transfer

import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.shelfarr.app.core.DownloadManager
import org.shelfarr.app.core.DownloadProblem
import org.shelfarr.app.core.DownloadRecord
import org.shelfarr.app.core.DownloadState

/** The part of an account's services an OS host needs. */
interface TransferAccount {
    val accountKey: String
    val downloads: DownloadManager
}

/** Limits how often a host asks the OS to try again after transient failures. */
interface RetryBudget {
    /** Spends one retry; false once the budget is used up. */
    fun consume(): Boolean
    fun reset()
}

/**
 * What an OS host does while it holds the process: it starts the signed-in account's
 * queue and reports progress until nothing is left to transfer. It never transfers
 * anything itself, so a job and a service can both hold the process without racing
 * the same files. When the account changes, it follows the new account; when nobody
 * is signed in, it stops and leaves stopped downloads for that account's return.
 */
class TransferDriver(
    private val accounts: StateFlow<TransferAccount?>,
    private val budget: RetryBudget?,
    private val publishEveryMs: Long = 1_000,
) {
    private enum class Outcome { CHANGED, IDLE }

    /**
     * Returns true when the OS should run the host again later, because a download
     * stopped for a reason that may pass (connection, server error) and the retry
     * budget allows it.
     */
    suspend fun drive(
        publish: suspend (TransferAccount, Collection<DownloadRecord>) -> Unit,
        finished: suspend (TransferAccount, finished: List<DownloadRecord>, stopped: List<DownloadRecord>) -> Unit = { _, _, _ -> },
    ): Boolean {
        while (true) {
            val account = accounts.value ?: return false
            val downloads = account.downloads
            downloads.start()
            val before = downloads.records.value
            // The OS only starts a host once its network constraint is met: retry what the connection stopped.
            downloads.resumeTransient()
            downloads.resumeQueued()
            val outcome = coroutineScope {
                val updates = launch {
                    downloads.records.collect { records ->
                        publish(account, records.values)
                        delay(publishEveryMs)
                    }
                }
                val result = combine(accounts, downloads.records) { current, records ->
                    when {
                        current !== account -> Outcome.CHANGED
                        records.values.none { it.isActive } -> Outcome.IDLE
                        else -> null
                    }
                }.first { it != null }!!
                updates.cancel()
                result
            }
            if (outcome == Outcome.CHANGED) continue

            val after = downloads.records.value
            val started = before.filterValues { it.state != DownloadState.READY }.keys + (after.keys - before.keys)
            val finishedNow = after.values.filter { it.publicationId in started && it.isReady }
            val stoppedNow = after.values.filter {
                it.state == DownloadState.FAILED && it.problem !in TRANSIENT && before[it.publicationId] != it
            }
            finished(account, finishedNow, stoppedNow)
            if (!downloads.hasTransientFailures) {
                budget?.reset()
                return false
            }
            return budget?.consume() ?: false
        }
    }

    private companion object {
        val TRANSIENT = setOf(DownloadProblem.OFFLINE, DownloadProblem.SERVER)
    }
}
