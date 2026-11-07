package org.shelfarr.app.core

import java.security.MessageDigest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString

/** A signed-in account: one user on one server. */
data class Session(val server: ServerAddress, val user: Me, val accessToken: String) {
    /** Scopes every local file, so accounts and servers can never mix. */
    val accountKey: String = accountKey(server, user.id)

    override fun toString(): String = "Session(server=$server, user=${user.id})"
}

fun accountKey(server: ServerAddress, userId: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("${server.identity}\n$userId".toByteArray())
    return digest.take(16).joinToString("") { "%02x".format(it) }
}

sealed interface SessionState {
    /** No server configured, or the user disconnected. */
    data object SignedOut : SessionState

    /** The token stopped working. The server is remembered to make signing in again quick. */
    data class Expired(val server: ServerAddress, val userName: String?) : SessionState

    data class SignedIn(val session: Session) : SessionState
}

@Serializable
private data class StoredSession(
    val server: String,
    val accessToken: String,
    val user: Me,
)

@Serializable
private data class StoredAuthorization(
    val server: String,
    val grant: DeviceGrant,
    val expiresAtEpochMs: Long,
)

/** An unfinished device authorization, kept so the app can survive being killed while the browser is open. */
data class PendingAuthorization(val server: ServerAddress, val grant: DeviceGrant, val expiresAtEpochMs: Long)

/** Owns the session secret. Nothing else reads or writes the token. */
class SessionManager(private val store: SecureStore) : CredentialSource {
    private val state = MutableStateFlow(load())

    val session: StateFlow<SessionState> = state.asStateFlow()

    val signedIn: Session? get() = (state.value as? SessionState.SignedIn)?.session

    /** A token between approval and `/me`, held in memory only. */
    @Volatile
    private var provisional: Credential? = null

    override fun current(): Credential? =
        provisional ?: signedIn?.let { Credential(it.server, it.accessToken) }

    fun useProvisional(credential: Credential?) {
        provisional = credential
    }

    private fun load(): SessionState {
        val json = store.read(SESSION) ?: return SessionState.SignedOut
        val stored = decode<StoredSession>(json)
        val server = stored?.let { ServerAddress.restore(it.server) }
        if (stored == null || server == null) {
            store.delete(SESSION)
            return SessionState.SignedOut
        }
        if (stored.accessToken.isEmpty()) return SessionState.Expired(server, stored.user.displayName)
        return SessionState.SignedIn(Session(server, stored.user, stored.accessToken))
    }

    fun signIn(session: Session) {
        store.write(SESSION, ApiJson.encodeToString(StoredSession(session.server.display, session.accessToken, session.user)))
        store.delete(AUTHORIZATION)
        provisional = null
        state.value = SessionState.SignedIn(session)
    }

    /** The server refused the token. Forget it, keep the address for re-authorizing. */
    fun markExpired(rejected: Credential) {
        val current = signedIn ?: return
        if (current.server != rejected.server || current.accessToken != rejected.accessToken) return
        store.write(SESSION, ApiJson.encodeToString(StoredSession(current.server.display, "", current.user)))
        state.value = SessionState.Expired(current.server, current.user.displayName)
    }

    fun refreshUser(user: Me) {
        val current = signedIn ?: return
        if (current.user == user) return
        signIn(current.copy(user = user))
    }

    /** Forgets everything secret. Callers clear account-scoped files separately. */
    fun clear() {
        store.delete(SESSION)
        store.delete(AUTHORIZATION)
        provisional = null
        state.value = SessionState.SignedOut
    }

    fun savePendingAuthorization(pending: PendingAuthorization) {
        val stored = StoredAuthorization(pending.server.display, pending.grant, pending.expiresAtEpochMs)
        store.write(AUTHORIZATION, ApiJson.encodeToString(stored))
    }

    fun pendingAuthorization(nowEpochMs: Long): PendingAuthorization? {
        val stored = store.read(AUTHORIZATION)?.let { decode<StoredAuthorization>(it) } ?: return null
        val server = ServerAddress.restore(stored.server)
        if (server == null || stored.expiresAtEpochMs <= nowEpochMs) {
            store.delete(AUTHORIZATION)
            return null
        }
        return PendingAuthorization(server, stored.grant, stored.expiresAtEpochMs)
    }

    fun clearPendingAuthorization() = store.delete(AUTHORIZATION)

    private inline fun <reified T> decode(json: String): T? = try {
        ApiJson.decodeFromString<T>(json)
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    private companion object {
        const val SESSION = "session"
        const val AUTHORIZATION = "pending_authorization"
    }
}
