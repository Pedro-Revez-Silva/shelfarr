package org.shelfarr.app.core

import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString

/** A signed-in account: one user on one server. */
data class Session(
    val server: ServerAddress,
    val user: Me,
    val accessToken: String,
    /** The `scope` the token response named; null for sessions saved before it was kept. */
    val grantedScopes: List<String>? = null,
) {
    /** Scopes every local file, so accounts and servers can never mix. */
    val accountKey: String = accountKey(server, user.id)

    /** What this credential may do: the server's current answer, else what it granted. */
    val scopes: List<String> get() = user.scopes ?: grantedScopes ?: RequestScopes.BASE

    /** Whether this connection was explicitly approved for finding and requesting titles. */
    val canRequest: Boolean get() = RequestScopes.allows(scopes)

    /** Display names may change without replacing the account's services. */
    fun hasSameAccountAndToken(other: Session?): Boolean =
        other != null && accountKey == other.accountKey && accessToken == other.accessToken

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
    val scopes: List<String>? = null,
)

@Serializable
private data class StoredAuthorization(
    val server: String,
    val grant: DeviceGrant,
    val expiresAtEpochMs: Long,
)

@Serializable
private data class StoredUpgrade(
    val accountKey: String,
    val grant: DeviceGrant,
    val expiresAtEpochMs: Long,
    val issued: IssuedReplacement? = null,
)

/**
 * A token issued to replace the live one, not yet confirmed by the server.
 *
 * The server retires the token it replaces as soon as it authenticates the first request
 * that carries the new one, before answering it. So from that first request on, the new
 * token may be the only one that works: it is kept with the pending upgrade until it is
 * confirmed or refused, never only in memory.
 */
@Serializable
data class IssuedReplacement(
    val accessToken: String,
    val scopes: List<String>,
    /** [SessionManager]'s fingerprint of the token this one replaces. */
    val replaces: String,
) {
    override fun toString(): String = "IssuedReplacement(scopes=$scopes)"
}

/** An unfinished request for more permission on the signed-in account's connection. */
data class PendingUpgrade(
    val accountKey: String,
    val grant: DeviceGrant,
    val expiresAtEpochMs: Long,
    /** The replacement once the server has issued it, until it is confirmed for this account. */
    val issued: IssuedReplacement? = null,
)

/** An unfinished device authorization, kept so the app can survive being killed while the browser is open. */
data class PendingAuthorization(val server: ServerAddress, val grant: DeviceGrant, val expiresAtEpochMs: Long)

/** How a handover of the live sign-in to a replacement token ended. */
sealed interface HandoverOutcome {
    /** The server confirmed the replacement for this account; the sign-in continues with it. */
    data class Adopted(val session: Session) : HandoverOutcome

    /** The replacement, [credential], belongs to another account. It was not used for anything. */
    data class OtherAccount(val credential: Credential) : HandoverOutcome

    /** The server refused the replacement. */
    data object Refused : HandoverOutcome

    /**
     * The replacement couldn't be checked just now. It is kept, and checked again when the
     * server next refuses the token it replaces, or when the app next starts.
     */
    data object Unconfirmed : HandoverOutcome

    /** No handover is waiting: there was none, or the sign-in ended or changed meanwhile. */
    data object Ended : HandoverOutcome
}

/** What work bound to one sign-in should do when the server refuses the token it sent. */
sealed interface RefusalResolution {
    /** The same sign-in continues with [credential]: send the request once more with it. */
    data class Replay(val credential: Credential) : RefusalResolution

    /** The sign-in has ended. Nothing may be sent for it. */
    data object Ended : RefusalResolution

    /** The replacement couldn't be confirmed just now. Nothing ended; retry as if offline. */
    data object Unconfirmed : RefusalResolution
}

/** Asks the server who [credential] belongs to (`GET /me`), sending exactly it and never ending the live session. */
fun interface CandidateCheck {
    suspend fun me(credential: Credential): Me
}

/**
 * Owns the session secret. Nothing else reads or writes the token.
 *
 * Every change of the signed-in state, including what is written to the store for it, is
 * one transition under this object's lock; waiting work is released after it, outside the lock.
 */
class SessionManager(
    private val store: SecureStore,
    /** Where a replacement token is checked with the server. */
    private val checks: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : CredentialSource {
    /** One check of a replacement; everyone who asks meanwhile waits for the same answer. */
    private class Attempt {
        val done = CompletableDeferred<HandoverOutcome>()
        private val latch = CountDownLatch(1)

        fun finish(outcome: HandoverOutcome) {
            if (done.complete(outcome)) latch.countDown()
        }

        /** Blocks an HTTP thread until answered, or until [canceled]. */
        @OptIn(ExperimentalCoroutinesApi::class)
        fun await(canceled: () -> Boolean): HandoverOutcome {
            while (!latch.await(POLL_MS, TimeUnit.MILLISECONDS)) {
                if (canceled()) return HandoverOutcome.Unconfirmed
            }
            return done.getCompleted()
        }
    }

    /** The live sign-in being handed over to a replacement token for the same account. */
    private class Handover(
        val accountKey: String,
        val server: ServerAddress,
        /** The live token being replaced. */
        val replaces: String,
        val candidate: String,
        val scopes: List<String>,
        val check: CandidateCheck?,
    ) {
        /** A refusal of [replaces] is waiting on this handover: if it fails, the sign-in ends. */
        var refused = false
        var attempt: Attempt? = null
        var job: Job? = null
    }

    /** What a transition leaves to do once the lock is released. */
    private class Effects {
        val finished = mutableListOf<Pair<Attempt, HandoverOutcome>>()
        val cancelled = mutableListOf<Job>()
        var start: Triple<Handover, Attempt, CandidateCheck>? = null

        fun perform(manager: SessionManager) {
            cancelled.forEach { it.cancel() }
            finished.forEach { (attempt, outcome) -> attempt.finish(outcome) }
            start?.let { (handover, attempt, check) -> manager.startCheck(handover, attempt, check) }
        }
    }

    private val state = MutableStateFlow(load())

    val session: StateFlow<SessionState> = state.asStateFlow()

    val signedIn: Session? get() = (state.value as? SessionState.SignedIn)?.session

    /** A token between approval and `/me`, held in memory only. */
    @Volatile
    private var provisional: Credential? = null

    /**
     * Fingerprints of every token the live sign-in has held: the one it began with and each
     * replacement approved in place. Memory only; any other change starts afresh.
     */
    private var lineage: MutableSet<String> = lineageOf(state.value)

    private var handover: Handover? = restoredHandover(state.value)

    @Volatile
    private var candidateCheck: CandidateCheck? = null

    override fun current(): Credential? =
        provisional ?: signedIn?.let { Credential(it.server, it.accessToken) }

    fun useProvisional(credential: Credential?) {
        provisional = credential
    }

    /** How a replacement left from an earlier process is confirmed. Install before any request is sent. */
    fun useCandidateCheck(check: CandidateCheck) {
        candidateCheck = check
    }

    /**
     * The live session when it continues [earlier]'s sign-in: the same session, one with
     * fresher details, or a replacement token for the same account approved in place. Null
     * after any other sign-in, an expiry or a sign-out, so work bound to [earlier] follows a
     * handover but can never borrow another sign-in's token.
     */
    @Synchronized
    fun continuing(earlier: Session): Session? = continuingLocked(earlier)

    private fun continuingLocked(earlier: Session): Session? {
        val live = signedIn ?: return null
        return live.takeIf { it.accountKey == earlier.accountKey && fingerprint(earlier.accessToken) in lineage }
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
        return SessionState.SignedIn(Session(server, stored.user, stored.accessToken, stored.scopes))
    }

    /** A replacement issued before the process last stopped, for the sign-in it was issued to. */
    private fun restoredHandover(loaded: SessionState): Handover? {
        val stored = storedUpgrade() ?: return null
        val issued = stored.issued ?: return null
        val live = (loaded as? SessionState.SignedIn)?.session
        if (live == null || stored.accountKey != live.accountKey || issued.replaces != fingerprint(live.accessToken) ||
            issued.accessToken == live.accessToken
        ) {
            // Adopted already, or issued to a sign-in that has ended: never usable again.
            store.delete(UPGRADE)
            return null
        }
        return Handover(live.accountKey, live.server, live.accessToken, issued.accessToken, issued.scopes, null)
    }

    fun signIn(session: Session) = transition {
        persist(session)
        store.delete(AUTHORIZATION)
        // A replacement issued to an earlier sign-in is never carried into this one.
        if (storedUpgrade()?.issued != null) store.delete(UPGRADE)
        apply(SessionState.SignedIn(session), continuing = false)
    }

    private fun persist(session: Session) {
        store.write(SESSION, ApiJson.encodeToString(StoredSession(session.server.display, session.accessToken, session.user, session.grantedScopes)))
    }

    /**
     * Swaps in a newly approved credential for the same account, keeping everything
     * stored for it. Refused unless [expected] is still the live session and
     * [upgraded] is the same user on the same server.
     */
    fun replaceToken(expected: Session, upgraded: Session): Boolean = transition {
        val current = signedIn ?: return@transition false
        if (!current.hasSameAccountAndToken(expected) || upgraded.accountKey != current.accountKey) return@transition false
        persist(upgraded)
        store.delete(UPGRADE)
        // The same sign-in continues: work bound to [expected] now uses this token.
        apply(SessionState.SignedIn(upgraded), continuing = true)
        true
    }

    // Handing the sign-in over to a replacement token.

    /**
     * Records that the server issued [accessToken] to replace [expected]'s live token, before
     * anything is sent with it. The replacement is stored with [pending], and until
     * [confirmHandover] settles it, a refusal of the live token waits for that answer instead
     * of ending the sign-in. False, with nothing changed, unless [expected] is still the live
     * session and nothing else is being handed over.
     */
    fun beginHandover(
        expected: Session,
        pending: PendingUpgrade,
        accessToken: String,
        grantedScopes: List<String>,
        check: CandidateCheck,
    ): Boolean = transition {
        val live = signedIn
        if (live == null || !live.hasSameAccountAndToken(expected) || pending.accountKey != live.accountKey ||
            accessToken == live.accessToken || handover != null
        ) return@transition false
        val issued = IssuedReplacement(accessToken, grantedScopes, fingerprint(live.accessToken))
        store.write(UPGRADE, ApiJson.encodeToString(StoredUpgrade(pending.accountKey, pending.grant, pending.expiresAtEpochMs, issued)))
        handover = Handover(live.accountKey, live.server, live.accessToken, accessToken, grantedScopes, check)
        true
    }

    /** Whether a replacement token for [session]'s live sign-in is waiting to be confirmed. */
    @Synchronized
    fun hasPendingHandover(session: Session): Boolean {
        val pending = handover ?: return false
        val live = continuingLocked(session) ?: return false
        return pending.accountKey == live.accountKey && pending.replaces == live.accessToken
    }

    /**
     * Asks the server who the waiting replacement belongs to, once for everyone who asks
     * meanwhile, and adopts it in place when it is this account's. With [refused], the
     * caller's request was refused with the token being replaced, so a replacement that
     * can't be adopted ends the sign-in. A cancelled caller stops waiting; the check goes on.
     */
    suspend fun confirmHandover(refused: Boolean = false): HandoverOutcome {
        val attempt = join(refused) ?: return HandoverOutcome.Ended
        return attempt.done.await()
    }

    /**
     * For work bound to [earlier]'s sign-in (or, without it, to whichever sign-in held
     * [rejected]) whose request with [rejected] was refused: what to do next. Answers at
     * once unless a replacement for [rejected] is waiting to be confirmed; then it waits.
     * Never ends the sign-in itself: an [RefusalResolution.Ended] caller reports the
     * refusal ([markExpired]), which ends it only if [rejected] is still the token in use.
     */
    suspend fun resolveRefusal(rejected: Credential, earlier: Session? = null): RefusalResolution {
        settledRefusal(rejected, earlier)?.let { return it }
        val outcome = confirmHandover(refused = true)
        return settledRefusal(rejected, earlier) ?: unsettled(outcome)
    }

    /** [resolveRefusal] for an HTTP thread: blocks until answered, or until [canceled]. */
    fun resolveRefusalBlocking(rejected: Credential, earlier: Session? = null, canceled: () -> Boolean): RefusalResolution {
        settledRefusal(rejected, earlier)?.let { return it }
        val outcome = join(refused = true)?.await(canceled) ?: HandoverOutcome.Ended
        if (canceled()) return RefusalResolution.Unconfirmed
        return settledRefusal(rejected, earlier) ?: unsettled(outcome)
    }

    private fun unsettled(outcome: HandoverOutcome): RefusalResolution =
        if (outcome == HandoverOutcome.Unconfirmed) RefusalResolution.Unconfirmed else RefusalResolution.Ended

    @Synchronized
    private fun settledRefusal(rejected: Credential, earlier: Session?): RefusalResolution? {
        val live = (if (earlier != null) continuingLocked(earlier) else signedIn?.takeIf { fingerprint(rejected.accessToken) in lineage })
            ?: return RefusalResolution.Ended
        if (live.server != rejected.server) return RefusalResolution.Ended
        if (live.accessToken != rejected.accessToken) return RefusalResolution.Replay(Credential(live.server, live.accessToken))
        val pending = handover
        if (pending == null || pending.accountKey != live.accountKey || pending.replaces != live.accessToken) return RefusalResolution.Ended
        return null
    }

    /** The check under way for the live handover, started if needed; null when there is no handover. */
    private fun join(refused: Boolean): Attempt? {
        var joined: Attempt? = null
        transition {
            val pending = handover ?: return@transition
            if (refused) pending.refused = true
            pending.attempt?.let {
                joined = it
                return@transition
            }
            val check = pending.check ?: candidateCheck
            val attempt = Attempt()
            joined = attempt
            if (check == null) {
                // Nothing can check this replacement here, so it can't be adopted.
                pending.attempt = attempt
                abandon(HandoverOutcome.Unconfirmed)
                return@transition
            }
            pending.attempt = attempt
            start = Triple(pending, attempt, check)
        }
        return joined
    }

    private fun startCheck(pending: Handover, attempt: Attempt, check: CandidateCheck) {
        val candidate = Credential(pending.server, pending.candidate)
        val job = checks.launch {
            val result = try {
                Result.success(check.me(candidate))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Result.failure(error)
            }
            settle(pending, attempt, result)
        }
        job.invokeOnCompletion { cause -> if (cause != null) settleCancelled(pending, attempt) }
        synchronized(this) { if (pending.attempt === attempt) pending.job = job }
    }

    private fun settleCancelled(pending: Handover, attempt: Attempt) = transition {
        if (handover === pending && pending.attempt === attempt) {
            pending.attempt = null
            pending.job = null
        }
        finished += attempt to (if (handover === pending) HandoverOutcome.Unconfirmed else HandoverOutcome.Ended)
    }

    private fun settle(settling: Handover, attempt: Attempt, result: Result<Me>) = transition {
        val live = signedIn
        if (handover !== settling || live == null || live.accountKey != settling.accountKey || live.accessToken != settling.replaces) {
            finished += attempt to HandoverOutcome.Ended
            return@transition
        }
        val me = result.getOrNull()
        when {
            me != null && me.id == live.user.id -> {
                val upgraded = live.copy(user = me, accessToken = settling.candidate, grantedScopes = settling.scopes)
                persist(upgraded)
                store.delete(UPGRADE)
                handover = null
                finished += attempt to HandoverOutcome.Adopted(upgraded)
                apply(SessionState.SignedIn(upgraded), continuing = true)
            }
            me != null -> abandon(HandoverOutcome.OtherAccount(Credential(settling.server, settling.candidate)))
            result.exceptionOrNull() is ApiException.Unauthorized -> abandon(HandoverOutcome.Refused)
            else -> {
                // Unanswered: keep the replacement for the next refusal or the next launch.
                settling.attempt = null
                settling.job = null
                finished += attempt to HandoverOutcome.Unconfirmed
            }
        }
    }

    /**
     * Drops the live handover. With a refusal waiting on it, the token being replaced has
     * been refused and nothing replaces it, so the sign-in ends. Caller holds the lock.
     */
    private fun Effects.abandon(outcome: HandoverOutcome) {
        val dropped = handover ?: return
        if (outcome == HandoverOutcome.Unconfirmed && !dropped.refused) {
            // Nothing was refused: keep it stored for a later check, but nobody waits here.
            dropped.attempt?.let { finished += it to HandoverOutcome.Unconfirmed }
            dropped.attempt = null
            return
        }
        store.delete(UPGRADE)
        dropped.attempt?.let { finished += it to (if (outcome == HandoverOutcome.Unconfirmed) HandoverOutcome.Ended else outcome) }
        dropped.job?.let { cancelled += it }
        handover = null
        val live = signedIn
        if (dropped.refused && live != null && live.accessToken == dropped.replaces) expire(live)
    }

    fun savePendingUpgrade(pending: PendingUpgrade) = transition {
        // A replacement already issued for this sign-in is never overwritten by a new attempt.
        if (handover != null || storedUpgrade()?.issued != null) return@transition
        store.write(UPGRADE, ApiJson.encodeToString(StoredUpgrade(pending.accountKey, pending.grant, pending.expiresAtEpochMs)))
    }

    /**
     * The unfinished upgrade for [accountKey]; one for any other account is discarded. One
     * whose replacement was already issued lasts until that is settled, however long ago its
     * approval code expired.
     */
    @Synchronized
    fun pendingUpgrade(accountKey: String, nowEpochMs: Long): PendingUpgrade? {
        val stored = storedUpgrade() ?: return null
        if (stored.accountKey != accountKey || (stored.issued == null && stored.expiresAtEpochMs <= nowEpochMs)) {
            store.delete(UPGRADE)
            return null
        }
        return PendingUpgrade(stored.accountKey, stored.grant, stored.expiresAtEpochMs, stored.issued)
    }

    /** Forgets an unfinished approval. A replacement the server already issued is kept. */
    @Synchronized
    fun clearPendingUpgrade() {
        if (handover != null || storedUpgrade()?.issued != null) return
        store.delete(UPGRADE)
    }

    private fun storedUpgrade(): StoredUpgrade? = store.read(UPGRADE)?.let { decode<StoredUpgrade>(it) }

    /**
     * The server refused the token. Forget it, keep the address for re-authorizing.
     *
     * While a replacement for that token is waiting to be confirmed, the refusal waits for
     * it instead: the server retires the old token as soon as the replacement is first used.
     * The sign-in ends only if the replacement can't be adopted.
     */
    fun markExpired(rejected: Credential) = transition {
        val current = signedIn ?: return@transition
        if (current.server != rejected.server || current.accessToken != rejected.accessToken) return@transition
        val pending = handover
        if (pending != null && pending.accountKey == current.accountKey && pending.replaces == current.accessToken) {
            pending.refused = true
            if (pending.attempt != null) return@transition
            val check = pending.check ?: candidateCheck
            if (check != null) {
                val attempt = Attempt()
                pending.attempt = attempt
                start = Triple(pending, attempt, check)
                return@transition
            }
            abandon(HandoverOutcome.Refused)
            if (signedIn != null) expire(current)
            return@transition
        }
        if (pending != null) abandon(HandoverOutcome.Refused)
        if (signedIn?.accessToken == current.accessToken) expire(current)
    }

    /** Caller holds the lock. */
    private fun Effects.expire(current: Session) {
        store.write(SESSION, ApiJson.encodeToString(StoredSession(current.server.display, "", current.user, current.grantedScopes)))
        store.delete(UPGRADE)
        apply(SessionState.Expired(current.server, current.user.displayName), continuing = false)
    }

    fun refreshUser(user: Me, expectedSession: Session) = transition {
        val current = signedIn ?: return@transition
        if (!current.hasSameAccountAndToken(expectedSession) || current.user.id != user.id || current.user == user) return@transition
        val refreshed = current.copy(user = user)
        persist(refreshed)
        apply(SessionState.SignedIn(refreshed), continuing = true)
    }

    /** Forgets everything secret. Callers clear account-scoped files separately. */
    fun clear() = transition {
        store.delete(SESSION)
        store.delete(AUTHORIZATION)
        store.delete(UPGRADE)
        apply(SessionState.SignedOut, continuing = false)
    }

    /** One transition: [block] runs alone; what it leaves to do happens after the lock is released. */
    private inline fun <T> transition(block: Effects.() -> T): T {
        val effects = Effects()
        val result = synchronized(this) { effects.block() }
        effects.perform(this)
        return result
    }

    /** Sets the live state. A handover only survives while its sign-in keeps the token it replaces. Caller holds the lock. */
    private fun Effects.apply(next: SessionState, continuing: Boolean) {
        val nextSession = (next as? SessionState.SignedIn)?.session
        if (continuing && nextSession != null) lineage.add(fingerprint(nextSession.accessToken)) else lineage = lineageOf(next)
        provisional = null
        val pending = handover
        if (pending != null && !(continuing && nextSession != null && nextSession.accountKey == pending.accountKey && nextSession.accessToken == pending.replaces)) {
            pending.attempt?.let { finished += it to HandoverOutcome.Ended }
            pending.job?.let { cancelled += it }
            handover = null
        }
        state.value = next
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
        const val UPGRADE = "pending_upgrade"
        const val POLL_MS = 50L

        fun fingerprint(token: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest("shelfarr-sign-in\n$token".toByteArray())
            return digest.joinToString("") { "%02x".format(it) }
        }

        fun lineageOf(state: SessionState): MutableSet<String> =
            (state as? SessionState.SignedIn)?.let { mutableSetOf(fingerprint(it.session.accessToken)) } ?: mutableSetOf()
    }
}
