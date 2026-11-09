package org.shelfarr.app.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Whether this connection may find and request titles, and how to change that. */
sealed interface RequestAccess {
    data object Checking : RequestAccess

    data object Allowed : RequestAccess

    /** The server has no requesting for apps. Reading and listening are unaffected. */
    data object ServerTooOld : RequestAccess

    /** Read-and-listen only. [notice] explains how the last attempt ended. */
    data class NotAllowed(val notice: String? = null) : RequestAccess

    /** Waiting for the person to approve in the browser. */
    data class Approving(
        val userCode: String,
        val verificationUri: String,
        val browserUri: String,
        val secondsLeft: Long,
    ) : RequestAccess
}

/** What adding requesting needs from the outside world, so tests can drive it without Android. */
interface RequestingBackend {
    val sessions: SessionManager
    /** The signed-in API: its HTTP stack sends the live bearer to the configured server. */
    val api: ConsumerApi
    val authorizer: DeviceAuthorizer

    /** A client that sends exactly [credential] and never ends the live session on a 401. */
    fun apiFor(credential: Credential): ConsumerApi
}

/**
 * Adds the requesting permission to the signed-in connection without disconnecting:
 * the server, account files, downloads, settings and saved places stay as they are.
 * Only a fresh, explicit browser approval for the same account grants it; an approval
 * by another account, a denial or an expiry leaves the existing connection untouched.
 */
class RequestingAccess(
    private val backend: RequestingBackend,
    private val scope: CoroutineScope,
    private val clientName: String,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val mutableState = MutableStateFlow<RequestAccess>(RequestAccess.Checking)
    val state: StateFlow<RequestAccess> = mutableState.asStateFlow()

    private var polling: Job? = null
    private var starting = false
    private val facts = mutableMapOf<String, Boolean>()

    /** Recomputes from the live session, asking the server what it offers when needed. */
    suspend fun refresh(session: Session) {
        if (mutableState.value is RequestAccess.Approving) return
        if (session.canRequest) {
            mutableState.value = RequestAccess.Allowed
            return
        }
        val offered = facts[session.server.identity] ?: try {
            backend.api.serverFacts(session.server).offersRequesting.also { facts[session.server.identity] = it }
        } catch (_: ApiException.NotFound) {
            false.also { facts[session.server.identity] = it }
        } catch (_: ApiException) {
            // Unknown while offline: let the person try; the attempt explains itself.
            null
        }
        val current = mutableState.value
        mutableState.value = when {
            offered == false -> RequestAccess.ServerTooOld
            current is RequestAccess.NotAllowed -> current
            else -> RequestAccess.NotAllowed()
        }
    }

    /**
     * Continues an approval the app was killed during. One whose replacement token was
     * already issued is confirmed with the server; nothing is asked of the person again.
     */
    fun resume(session: Session) {
        if (backend.sessions.hasPendingHandover(session)) return confirm(session)
        val pending = backend.sessions.pendingUpgrade(session.accountKey, now()) ?: return
        poll(session, pending)
    }

    /**
     * Starts one approval and returns the page to open, or null when nothing started
     * (already approving, or a failure now explained in [state]). A second tap is ignored.
     */
    suspend fun start(session: Session): String? {
        val current = mutableState.value
        if (current is RequestAccess.Approving) return current.browserUri
        if (starting) return null
        if (backend.sessions.hasPendingHandover(session)) {
            // Approved already: what's left is the server confirming the new token.
            if (polling?.isActive != true) confirm(session)
            return null
        }
        starting = true
        try {
            val grant = backend.api.startDeviceAuthorization(session.server, clientName, RequestScopes.ALL)
            val browser = session.server.resolve(grant.verificationUriComplete)
            val verification = session.server.resolve(grant.verificationUri)
            if (browser == null || verification == null || !session.server.contains(browser) || !session.server.contains(verification)) {
                mutableState.value = RequestAccess.NotAllowed("${session.server.host} asked to approve this somewhere else, so nothing was opened.")
                return null
            }
            val pending = PendingUpgrade(session.accountKey, grant, now() + grant.expiresIn * 1_000)
            backend.sessions.savePendingUpgrade(pending)
            poll(session, pending)
            return browser.toString()
        } catch (error: ApiException) {
            mutableState.value = when {
                error is ApiException.NotFound -> RequestAccess.ServerTooOld
                error.isPlainOffline -> RequestAccess.NotAllowed("You're offline. Allowing requesting needs a connection to ${session.server.host}.")
                error is ApiException.Unauthorized -> RequestAccess.NotAllowed("Your sign-in has ended. Sign in again, then allow requesting.")
                else -> RequestAccess.NotAllowed("${session.server.host} couldn't start the approval. Try again in a moment.")
            }
            return null
        } finally {
            starting = false
        }
    }

    /** Signed out: forget the attempt; the stored grant went with the session. */
    fun detach() {
        polling?.cancel()
        polling = null
        facts.clear()
        mutableState.value = RequestAccess.Checking
    }

    fun cancel() {
        polling?.cancel()
        polling = null
        backend.sessions.clearPendingUpgrade()
        mutableState.value = RequestAccess.NotAllowed()
    }

    private fun poll(session: Session, pending: PendingUpgrade) {
        polling?.cancel()
        fun approving() = RequestAccess.Approving(
            userCode = pending.grant.userCode,
            verificationUri = session.server.resolve(pending.grant.verificationUri)?.toString() ?: pending.grant.verificationUri,
            browserUri = session.server.resolve(pending.grant.verificationUriComplete)?.toString() ?: pending.grant.verificationUriComplete,
            secondsLeft = ((pending.expiresAtEpochMs - now()) / 1_000).coerceAtLeast(0),
        )
        mutableState.value = approving()
        polling = scope.launch {
            val countdown = launch {
                while (isActive) {
                    delay(1_000)
                    if (mutableState.value is RequestAccess.Approving) mutableState.value = approving()
                }
            }
            val ended = try {
                when (val outcome = backend.authorizer.await(PendingAuthorization(session.server, pending.grant, pending.expiresAtEpochMs))) {
                    is AuthorizationOutcome.Approved -> adopt(session, pending, outcome.token)
                    AuthorizationOutcome.Denied -> RequestAccess.NotAllowed("Requesting wasn't allowed. The app still reads and plays everything as before.")
                    AuthorizationOutcome.Expired -> RequestAccess.NotAllowed("The approval code expired. Try again when you're ready.")
                }
            } catch (error: ApiException) {
                RequestAccess.NotAllowed(
                    if (error.isPlainOffline) "The connection dropped before approval finished. Try again." else "Approval couldn't finish. Try again.",
                )
            } finally {
                countdown.cancel()
            }
            backend.sessions.clearPendingUpgrade()
            mutableState.value = ended
        }
    }

    /** Confirms a replacement issued before, without asking the person again. */
    private fun confirm(session: Session) {
        polling?.cancel()
        mutableState.value = RequestAccess.Checking
        polling = scope.launch {
            val ended = settleHandover(session)
            backend.sessions.clearPendingUpgrade()
            mutableState.value = ended
        }
    }

    private suspend fun adopt(session: Session, pending: PendingUpgrade, token: TokenResponse): RequestAccess {
        val granted = token.scope.split(' ').filter(String::isNotBlank)
        // Recorded before the new token is first sent: the server retires the old one as it
        // authenticates that first request, so from then on the old token's refusals wait
        // for this answer instead of signing out, and the new token survives the process.
        val server = session.server
        val began = backend.sessions.beginHandover(session, pending, token.accessToken, granted) { candidate ->
            backend.apiFor(candidate).me(server)
        }
        if (!began) {
            // The sign-in changed meanwhile; this token never becomes anyone's credential.
            quietly { backend.apiFor(Credential(server, token.accessToken)).revoke(server) }
            return RequestAccess.NotAllowed()
        }
        return settleHandover(session)
    }

    private suspend fun settleHandover(session: Session): RequestAccess =
        when (val outcome = backend.sessions.confirmHandover()) {
            is HandoverOutcome.Adopted -> {
                // The server retires the old credential once the new one is used; this also covers older servers.
                quietly { backend.apiFor(Credential(session.server, session.accessToken)).revoke(session.server) }
                if (outcome.session.canRequest) {
                    RequestAccess.Allowed
                } else {
                    facts[session.server.identity] = false
                    RequestAccess.ServerTooOld
                }
            }
            is HandoverOutcome.OtherAccount -> {
                // Never switch accounts from here; the server already refuses this, so a stray token is dropped.
                quietly { backend.apiFor(outcome.credential).revoke(session.server) }
                RequestAccess.NotAllowed("That approval was for a different account, so nothing changed.")
            }
            HandoverOutcome.Refused, HandoverOutcome.Unconfirmed ->
                RequestAccess.NotAllowed("Approval finished, but ${session.server.host} couldn't confirm it. Try again.")
            HandoverOutcome.Ended -> RequestAccess.NotAllowed()
        }
}

/** Best effort: a failure here changes nothing the person relies on. */
private suspend fun quietly(block: suspend () -> Unit) {
    try {
        block()
    } catch (_: ApiException) {
        // Expiry covers a credential that could not be revoked.
    }
}
