package org.shelfarr.app.ui.setup

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.shelfarr.app.AppContainer
import org.shelfarr.app.BuildConfig
import org.shelfarr.app.core.ApiException
import org.shelfarr.app.core.AuthorizationOutcome
import org.shelfarr.app.core.SignInActivity
import org.shelfarr.app.core.Credential
import org.shelfarr.app.core.PendingAuthorization
import org.shelfarr.app.core.ServerAddress
import org.shelfarr.app.core.Session
import org.shelfarr.app.core.SessionState

sealed interface SetupPhase {
    data object EnterServer : SetupPhase
    data object Connecting : SetupPhase

    data class Authorizing(
        val server: ServerAddress,
        val userCode: String,
        val verificationUri: String,
        val browserUri: String,
        val secondsLeft: Long,
    ) : SetupPhase

    /** The attempt ended; the reader can start a fresh one. */
    data class Ended(val server: ServerAddress, val denied: Boolean) : SetupPhase
}

data class SetupState(
    val address: String = "",
    val allowLocalHttp: Boolean = false,
    val phase: SetupPhase = SetupPhase.EnterServer,
    val errorMessage: String? = null,
    /** Set when an old session ended, to explain why this screen is back. */
    val expiredFor: String? = null,
    /** The address came from a server's "Open Shelfarr" link rather than typing. */
    val fromLink: Boolean = false,
    /** The server a [SetupPhase.Connecting] request is for. */
    val connectingTo: ServerAddress? = null,
) {
    /** Whether a sign-in is being started or awaits approval, for deciding what a link may do. */
    val signInActivity: SignInActivity
        get() = if (phase is SetupPhase.Connecting || phase is SetupPhase.Authorizing) SignInActivity.IN_PROGRESS else SignInActivity.IDLE

    /** The server a sign-in under way is for. */
    val signingInTo: ServerAddress?
        get() = (phase as? SetupPhase.Authorizing)?.server ?: if (phase is SetupPhase.Connecting) connectingTo else null
}

/**
 * Whether [pending]'s approval pages are on its own server's HTTPS address. A link, not
 * the person, chose that server, so its sign-in must not lead the browser elsewhere.
 */
internal fun approvalStaysOnServer(pending: PendingAuthorization): Boolean = listOf(
    pending.grant.verificationUri,
    pending.grant.verificationUriComplete,
).all { reference ->
    val url = pending.server.resolve(reference)
    url != null && url.isHttps && url.username.isEmpty() && url.password.isEmpty() && pending.server.contains(url)
}

class SetupViewModel(private val container: AppContainer) : ViewModel() {
    private val mutableState = MutableStateFlow(initialState())
    val state: StateFlow<SetupState> = mutableState.asStateFlow()

    private val browserRequests = Channel<String>(Channel.CONFLATED)
    val openBrowser = browserRequests.receiveAsFlow()

    val canUseLocalHttp: Boolean = BuildConfig.ALLOW_LOCAL_HTTP

    private var polling: Job? = null

    init {
        // Android may have killed us while the browser was in front.
        container.sessions.pendingAuthorization(System.currentTimeMillis())?.let(::await)
    }

    private fun initialState(): SetupState {
        val expired = container.sessions.session.value as? SessionState.Expired
        return SetupState(
            address = expired?.server?.display.orEmpty(),
            allowLocalHttp = expired?.server?.isCleartext == true,
            expiredFor = expired?.userName,
        )
    }

    fun onAddressChange(value: String) = mutableState.update { it.copy(address = value, errorMessage = null, fromLink = false) }

    /**
     * A server's "Open Shelfarr" link, already checked by `ConnectLink` and allowed by
     * `ConnectLinks.decide`: starts the usual browser approval for [server] without
     * typing. It never opens the browser by itself; the approval screen names the
     * server first, and the person opens the browser from there.
     */
    fun connectFromLink(server: ServerAddress) {
        val current = mutableState.value
        if (current.signInActivity == SignInActivity.IN_PROGRESS) return
        mutableState.update {
            it.copy(address = server.display, allowLocalHttp = false, errorMessage = null, fromLink = true)
        }
        connect()
    }

    fun onAllowLocalHttpChange(value: Boolean) = mutableState.update { it.copy(allowLocalHttp = value, errorMessage = null) }

    fun connect() {
        val current = mutableState.value
        val allowHttp = canUseLocalHttp && current.allowLocalHttp
        val server = when (val parsed = ServerAddress.parse(current.address, allowHttp)) {
            is ServerAddress.ParseResult.Valid -> parsed.address
            ServerAddress.ParseResult.Empty -> return fail("Enter your server's address.")
            ServerAddress.ParseResult.Malformed -> return fail("That doesn't look like a web address.")
            ServerAddress.ParseResult.CleartextNotAllowed -> return fail(
                if (canUseLocalHttp) {
                    "Plain HTTP needs the local-server option, and only works for hosts on your own network."
                } else {
                    "Shelfarr needs a secure https:// address."
                },
            )
        }

        val fromLink = current.fromLink
        mutableState.update { it.copy(phase = SetupPhase.Connecting, errorMessage = null, connectingTo = server) }
        viewModelScope.launch {
            try {
                val grant = container.api.startDeviceAuthorization(server, CLIENT_NAME)
                val pending = PendingAuthorization(server, grant, System.currentTimeMillis() + grant.expiresIn * 1_000)
                // A link chose this server, not the person: approval must stay on its own address.
                if (fromLink && !approvalStaysOnServer(pending)) {
                    mutableState.update {
                        it.copy(
                            phase = SetupPhase.EnterServer,
                            fromLink = false,
                            errorMessage = "${server.host} asked to approve this device somewhere else. " +
                                "Check the address, then tap Continue to try again.",
                        )
                    }
                    return@launch
                }
                container.sessions.savePendingAuthorization(pending)
                await(pending)
                if (!fromLink) browserRequests.trySend(browserUri(pending))
            } catch (error: ApiException) {
                mutableState.update { it.copy(phase = SetupPhase.EnterServer, errorMessage = connectMessage(error, server)) }
            }
        }
    }

    private fun browserUri(pending: PendingAuthorization): String =
        pending.server.resolve(pending.grant.verificationUriComplete)?.toString() ?: pending.grant.verificationUriComplete

    private fun await(pending: PendingAuthorization) {
        polling?.cancel()
        val verification = pending.server.resolve(pending.grant.verificationUri)?.toString() ?: pending.grant.verificationUri
        fun phase() = SetupPhase.Authorizing(
            server = pending.server,
            userCode = pending.grant.userCode,
            verificationUri = verification,
            browserUri = browserUri(pending),
            secondsLeft = ((pending.expiresAtEpochMs - System.currentTimeMillis()) / 1_000).coerceAtLeast(0),
        )
        mutableState.update { it.copy(phase = phase(), address = pending.server.display, errorMessage = null) }

        polling = viewModelScope.launch {
            val countdown = launch {
                while (isActive) {
                    delay(1_000)
                    mutableState.update { state ->
                        if (state.phase is SetupPhase.Authorizing) state.copy(phase = phase()) else state
                    }
                }
            }
            try {
                when (val outcome = container.authorizer.await(pending)) {
                    is AuthorizationOutcome.Approved -> finish(pending.server, outcome.token.accessToken)
                    AuthorizationOutcome.Denied -> end(pending.server, denied = true)
                    AuthorizationOutcome.Expired -> end(pending.server, denied = false)
                }
            } catch (error: ApiException) {
                container.sessions.clearPendingAuthorization()
                mutableState.update { it.copy(phase = SetupPhase.EnterServer, errorMessage = connectMessage(error, pending.server)) }
            } finally {
                countdown.cancel()
            }
        }
    }

    private suspend fun finish(server: ServerAddress, token: String) {
        container.sessions.useProvisional(Credential(server, token))
        try {
            val user = container.api.me(server)
            container.sessions.signIn(Session(server, user, token))
        } catch (error: ApiException) {
            container.sessions.useProvisional(null)
            container.sessions.clearPendingAuthorization()
            mutableState.update { it.copy(phase = SetupPhase.EnterServer, errorMessage = connectMessage(error, server)) }
        }
    }

    private fun end(server: ServerAddress, denied: Boolean) {
        container.sessions.clearPendingAuthorization()
        mutableState.update { it.copy(phase = SetupPhase.Ended(server, denied)) }
    }

    fun cancel() {
        polling?.cancel()
        polling = null
        container.sessions.clearPendingAuthorization()
        mutableState.update { it.copy(phase = SetupPhase.EnterServer) }
    }

    /** Starting over after an expired session means choosing a new server is allowed too. */
    fun startOver() = cancel()

    private fun fail(message: String) = mutableState.update { it.copy(errorMessage = message) }

    private fun connectMessage(error: ApiException, server: ServerAddress): String = when (error) {
        is ApiException.NotFound ->
            "${server.host} answered, but doesn't offer the reading API. It may need updating."
        is ApiException.Protocol -> "${server.host} doesn't look like a Shelfarr server."
        is ApiException.RedirectBlocked ->
            "${server.host} redirects to ${error.location}. Use that address instead."
        is ApiException.Offline -> {
            val certificate = generateSequence(error.cause) { it.cause }.any { it is javax.net.ssl.SSLException }
            if (certificate) {
                "The security certificate for ${server.host} couldn't be trusted."
            } else {
                "Couldn't reach ${server.host}. Check the address and your connection."
            }
        }
        is ApiException.Server -> "${server.host} had a problem (error ${error.status}). Try again in a moment."
        else -> "Couldn't connect to ${server.host}."
    }

    private companion object {
        const val CLIENT_NAME = "Shelfarr Android"
    }
}
