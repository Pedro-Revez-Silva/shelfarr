package org.shelfarr.app.ui.find

import org.shelfarr.app.core.BookType
import org.shelfarr.app.core.FormatOption
import org.shelfarr.app.core.FormatState
import org.shelfarr.app.core.RequestItem
import org.shelfarr.app.core.RequestStage

/** A request's state in plain words: a short headline and one sentence of detail. */
data class StageCopy(val headline: String, val detail: String)

fun RequestItem.stageCopy(): StageCopy = when (stage) {
    RequestStage.QUEUED -> StageCopy("Requested", "Waiting for Shelfarr to start looking.")
    RequestStage.SEARCHING -> if (attentionNeeded) {
        StageCopy("Waiting for the server's admin", "Shelfarr needs someone to look at this request.")
    } else {
        StageCopy("Looking for a copy", "This can take a few minutes.")
    }
    RequestStage.NOT_FOUND -> StageCopy("No copy found yet", "Shelfarr will keep looking and try again later.")
    RequestStage.AWAITING_PURCHASE -> StageCopy("Available to buy", "A store has it. Ask the server's admin to buy it and add it.")
    RequestStage.DOWNLOADING -> StageCopy(
        downloadPercent?.let { "Downloading · $it%" } ?: "Downloading",
        "Fetching the files to the server.",
    )
    RequestStage.PROCESSING -> StageCopy("Adding to your library", "Almost there.")
    RequestStage.AVAILABLE -> StageCopy("Ready", if (bookType == BookType.EBOOK) "In your library and ready to read." else "In your library and ready to listen.")
    RequestStage.COMPLETED -> StageCopy("Finished", "It was added, but isn't in the library now.")
    RequestStage.FAILED -> StageCopy("Stopped", "This request was cancelled or couldn't be completed. You can request it again from Find.")
    RequestStage.UNKNOWN -> StageCopy("Requested", "Shelfarr is working on it.")
}

/** One line under a format's name on the title page. */
fun FormatOption.summary(): String = when (state) {
    FormatState.REQUESTABLE -> if (bookType == BookType.EBOOK) "Read it in the app" else "Listen in the app"
    FormatState.IN_LIBRARY -> "Already in your library"
    FormatState.REQUESTED -> request?.let { "You requested it · ${it.stageCopy().headline}" } ?: "You requested it"
    FormatState.REQUESTED_BY_SOMEONE -> "Already requested on this server. It will appear in the library."
    FormatState.UNKNOWN -> "Not available to request"
}

/** The steps a request passes through, for the tracker. Returns the index reached. */
internal fun RequestItem.stepReached(): Int = when (stage) {
    RequestStage.QUEUED, RequestStage.UNKNOWN -> 0
    RequestStage.SEARCHING, RequestStage.NOT_FOUND, RequestStage.AWAITING_PURCHASE -> 1
    RequestStage.DOWNLOADING -> 2
    RequestStage.PROCESSING -> 3
    RequestStage.AVAILABLE, RequestStage.COMPLETED -> 4
    RequestStage.FAILED -> -1
}

internal val REQUEST_STEPS = listOf("Requested", "Finding a copy", "Downloading", "Adding to the library", "Ready")

internal val BookType.label: String get() = if (this == BookType.EBOOK) "Ebook" else "Audiobook"
