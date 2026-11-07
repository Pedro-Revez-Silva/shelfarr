package org.shelfarr.app.core

/** Every way a server call can fail, in terms the UI can act on. */
sealed class ApiException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** No usable connection. Safe to retry. */
    class Offline(cause: Throwable? = null) : ApiException("Server could not be reached", cause)

    /** The token is missing, expired or revoked. */
    class Unauthorized : ApiException("Sign-in is no longer valid")

    /** The token lacks a scope this call needs. */
    class Forbidden : ApiException("This account cannot do that")

    class NotFound : ApiException("Not found")

    /** Someone else moved the shared position on. */
    class ProgressConflict(val current: Progress?) : ApiException("Progress changed on another device")

    class Rejected(val code: String?) : ApiException("The server rejected this request")

    class Server(val status: Int) : ApiException("Server error $status")

    /** The server answered with something other than the Shelfarr API. */
    class Protocol(cause: Throwable? = null) : ApiException("Unexpected server response", cause)

    /** A redirect would have left the configured server. Nothing was sent. */
    class RedirectBlocked(val location: String) : ApiException("Server redirected elsewhere")

    /** The device-flow token endpoint's `error` value. */
    class Authorization(val code: String) : ApiException("Authorization: $code")

    val isRetryable: Boolean get() = this is Offline || this is Server
}
