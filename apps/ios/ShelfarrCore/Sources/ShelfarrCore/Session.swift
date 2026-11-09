import Foundation

public protocol SecretStore: AnyObject, Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ value: Data)
    func delete(_ name: String)
}

/// A signed-in account: one user on one server.
public struct Session: Equatable, Sendable, CustomStringConvertible {
    public let server: ServerAddress
    public let user: Me
    public let accessToken: String
    /// The `scope` the token response named; nil for sessions saved before it was kept.
    public let grantedScopes: [String]?

    public init(server: ServerAddress, user: Me, accessToken: String, grantedScopes: [String]? = nil) {
        self.server = server
        self.user = user
        self.accessToken = accessToken
        self.grantedScopes = grantedScopes
    }

    /// What this credential may do: the server's current answer, else what it granted.
    public var scopes: [String] { user.scopes ?? grantedScopes ?? RequestScopes.base }

    /// Whether this connection was explicitly approved for finding and requesting titles.
    public var canRequest: Bool { RequestScopes.allows(scopes) }

    /// Same account and token; display details and scopes may differ.
    public func hasSameAccountAndToken(_ other: Session?) -> Bool {
        guard let other else { return false }
        return accountKey == other.accountKey && accessToken == other.accessToken
    }

    /// Scopes every local file, so accounts and servers can never mix.
    public var accountKey: String { Self.accountKey(server: server, userId: user.id) }

    public static func accountKey(server: ServerAddress, userId: String) -> String {
        String(SHA256.hexDigest(Data("\(server.display)\n\(userId)".utf8)).prefix(32))
    }

    public var description: String { "Session(server: \(server.display), user: \(user.id))" }
}

public enum SessionState: Equatable, Sendable {
    case signedOut
    case expired(ServerAddress, String?)
    case signedIn(Session)
}

public struct PendingAuthorization: Codable, Equatable, Sendable {
    public let server: ServerAddress
    public let grant: DeviceGrant
    public let expiresAt: Date

    public init(server: ServerAddress, grant: DeviceGrant, expiresAt: Date) {
        self.server = server
        self.grant = grant
        self.expiresAt = expiresAt
    }
}

/// An unfinished request for more permission on the signed-in account's connection.
public struct PendingUpgrade: Codable, Equatable, Sendable {
    public let accountKey: String
    public let grant: DeviceGrant
    public let expiresAt: Date
    /// The replacement token once the server has issued it, kept until the server has
    /// confirmed it belongs to this account. Absent from upgrades saved before it was kept.
    public var issued: IssuedReplacement?

    public init(accountKey: String, grant: DeviceGrant, expiresAt: Date, issued: IssuedReplacement? = nil) {
        self.accountKey = accountKey
        self.grant = grant
        self.expiresAt = expiresAt
        self.issued = issued
    }
}

/// A token issued to replace the live one, not yet confirmed by the server.
///
/// The server retires the token it replaces as soon as it authenticates the first request
/// that carries the new one, before answering it. So from that first request on, the new
/// token may be the only one that works: it is kept with the pending upgrade until it is
/// confirmed or refused, never only in memory.
public struct IssuedReplacement: Codable, Equatable, Sendable, CustomStringConvertible {
    public let accessToken: String
    public let scopes: [String]
    /// `SessionManager`'s fingerprint of the token this one replaces.
    public let replaces: String

    public init(accessToken: String, scopes: [String], replaces: String) {
        self.accessToken = accessToken
        self.scopes = scopes
        self.replaces = replaces
    }

    public var description: String { "IssuedReplacement(scopes: \(scopes))" }
}

/// How a handover of the live sign-in to a replacement token ended.
public enum HandoverOutcome: Equatable, Sendable {
    /// The server confirmed the replacement for this account; the sign-in continues with it.
    case adopted(Session)
    /// The replacement, `credential`, belongs to another account. It was not used for anything.
    case otherAccount(Credential)
    /// The server refused the replacement.
    case refused
    /// The replacement couldn't be checked just now. It is kept, and checked again when the
    /// server next refuses the token it replaces, or when the app next starts.
    case unconfirmed
    /// No handover is waiting: there was none, or the sign-in ended or changed meanwhile.
    case ended
}

/// What work bound to one sign-in should do when the server refuses the token it sent.
public enum RefusalResolution: Equatable, Sendable {
    /// The same sign-in continues with this credential: send the request once more with it.
    case replay(Credential)
    /// The sign-in has ended. Nothing may be sent for it.
    case ended
    /// The sign-in's replacement token couldn't be confirmed just now. Nothing ended; try
    /// again later as if the connection had dropped.
    case unconfirmed
}

/// Owns the session secret. Nothing else reads or writes the token.
///
/// Every change of the signed-in state, including what is written to the store for it, is
/// one transition: they never interleave, and `onChange` is called after each, outside
/// any lock.
public final class SessionManager: @unchecked Sendable {
    /// Asks the server who a candidate credential belongs to (`GET /me`), sending exactly
    /// that credential and never ending the live session on a refusal.
    public typealias CandidateCheck = @Sendable (Credential) async throws -> Me

    private struct Stored: Codable {
        let server: ServerAddress
        let accessToken: String
        let user: Me
        var scopes: [String]?
    }

    private enum Keys {
        static let session = "session"
        static let authorization = "pending_authorization"
        static let upgrade = "pending_upgrade"
    }

    /// One wait for a handover's outcome. Its continuation is taken exactly once.
    private final class Waiter: @unchecked Sendable {
        var continuation: CheckedContinuation<HandoverOutcome, Never>?
        var cancelled = false
    }

    /// The live sign-in being handed over to a replacement token for the same account.
    private final class Handover: @unchecked Sendable {
        let accountKey: String
        let server: ServerAddress
        /// The live token being replaced.
        let replaces: String
        let candidate: String
        let scopes: [String]
        let check: CandidateCheck?
        /// A refusal of `replaces` is waiting on this handover: if it fails, the sign-in ends.
        var refused = false
        /// A check of `candidate` is under way; `task` runs it.
        var isChecking = false
        var task: Task<Void, Never>?
        var waiters: [Waiter] = []

        init(accountKey: String, server: ServerAddress, replaces: String, candidate: String, scopes: [String], check: CandidateCheck?) {
            self.accountKey = accountKey
            self.server = server
            self.replaces = replaces
            self.candidate = candidate
            self.scopes = scopes
            self.check = check
        }
    }

    /// What a transition leaves to do once every lock is released.
    private struct Effects {
        var changed: SessionState?
        var released: [(CheckedContinuation<HandoverOutcome, Never>, HandoverOutcome)] = []
        var cancelled: Task<Void, Never>?
        var start: (Handover, CandidateCheck)?
    }

    private let store: SecretStore
    /// Serializes transitions, including their storage writes. Taken before `lock`.
    private let transition = NSLock()
    private let lock = NSLock()
    private var current: SessionState
    private var provisional: Credential?
    /// Fingerprints of every token the live sign-in has held: the one it began with and
    /// each replacement approved in place. Memory only; any other change starts afresh.
    private var lineage: Set<String>
    private var handover: Handover?
    private var candidateCheck: CandidateCheck?

    public var onChange: (@Sendable (SessionState) -> Void)?

    public init(store: SecretStore) {
        self.store = store
        let loaded = Self.load(store)
        current = loaded
        lineage = Self.lineage(starting: loaded)
        handover = restoredHandover(loaded)
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hexDigest(Data("shelfarr-sign-in\n\(token)".utf8))
    }

    private static func lineage(starting state: SessionState) -> Set<String> {
        if case let .signedIn(session) = state { return [fingerprint(session.accessToken)] }
        return []
    }

    private static func load(_ store: SecretStore) -> SessionState {
        guard let data = store.read(Keys.session),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return .signedOut }
        if stored.accessToken.isEmpty { return .expired(stored.server, stored.user.displayName) }
        return .signedIn(Session(server: stored.server, user: stored.user, accessToken: stored.accessToken, grantedScopes: stored.scopes))
    }

    /// A replacement issued before the app last stopped, for the sign-in it was issued to.
    private func restoredHandover(_ state: SessionState) -> Handover? {
        guard let pending = storedUpgrade(), let issued = pending.issued else { return nil }
        guard case let .signedIn(live) = state, pending.accountKey == live.accountKey,
              issued.replaces == Self.fingerprint(live.accessToken), issued.accessToken != live.accessToken
        else {
            // Adopted already, or issued to a sign-in that has ended: never usable again.
            store.delete(Keys.upgrade)
            return nil
        }
        return Handover(accountKey: live.accountKey, server: live.server, replaces: live.accessToken,
                        candidate: issued.accessToken, scopes: issued.scopes, check: nil)
    }

    public var state: SessionState { lock.withLock { current } }

    public var signedIn: Session? {
        if case let .signedIn(session) = state { return session }
        return nil
    }

    /// The live session when it continues `earlier`'s sign-in: the same session, one
    /// with fresher details, or a replacement token for the same account approved in place
    /// (`replaceToken`). Nil after any other sign-in, an expiry or a sign-out, so work
    /// bound to `earlier` follows a handover but can never borrow another sign-in's token.
    public func continuing(_ earlier: Session) -> Session? {
        lock.withLock { continuingLocked(earlier) }
    }

    private func continuingLocked(_ earlier: Session) -> Session? {
        guard case let .signedIn(live) = current, live.accountKey == earlier.accountKey,
              lineage.contains(Self.fingerprint(earlier.accessToken))
        else { return nil }
        return live
    }

    public func credential() -> Credential? {
        lock.withLock {
            if let provisional { return provisional }
            if case let .signedIn(session) = current {
                return Credential(server: session.server, accessToken: session.accessToken)
            }
            return nil
        }
    }

    /// A token between approval and `/me`, held in memory only.
    public func useProvisional(_ credential: Credential?) {
        lock.withLock { provisional = credential }
    }

    /// How a replacement left from an earlier launch is confirmed when the old token is
    /// refused. Install before any request is sent.
    public func useCandidateCheck(_ check: @escaping CandidateCheck) {
        lock.withLock { candidateCheck = check }
    }

    public func signIn(_ session: Session) {
        run {
            persist(Stored(server: session.server, accessToken: session.accessToken, user: session.user, scopes: session.grantedScopes))
            store.delete(Keys.authorization)
            // A replacement issued to an earlier sign-in is never carried into this one.
            if storedUpgrade()?.issued != nil { store.delete(Keys.upgrade) }
            return apply(.signedIn(session))
        }
    }

    /// Keeps fresher display details and scopes for the same account and token.
    public func refreshUser(_ user: Me, expected: Session) {
        run {
            guard let current = signedIn, current.hasSameAccountAndToken(expected), current.user.id == user.id, current.user != user else { return Effects() }
            let refreshed = Session(server: current.server, user: user, accessToken: current.accessToken, grantedScopes: current.grantedScopes)
            persist(Stored(server: refreshed.server, accessToken: refreshed.accessToken, user: refreshed.user, scopes: refreshed.grantedScopes))
            return apply(.signedIn(refreshed), continuingSignIn: true)
        }
    }

    /// Swaps in a newly approved credential for the same account, keeping everything
    /// stored for it. Refused unless `expected` is still the live session and `upgraded`
    /// is the same user on the same server.
    @discardableResult
    public func replaceToken(expected: Session, upgraded: Session) -> Bool {
        var replaced = false
        run {
            guard let current = signedIn, current.hasSameAccountAndToken(expected), upgraded.accountKey == current.accountKey else { return Effects() }
            persist(Stored(server: upgraded.server, accessToken: upgraded.accessToken, user: upgraded.user, scopes: upgraded.grantedScopes))
            store.delete(Keys.upgrade)
            replaced = true
            // The same sign-in continues: work bound to `expected` now uses this token.
            return apply(.signedIn(upgraded), continuingSignIn: true)
        }
        return replaced
    }

    // MARK: Handing the sign-in over to a replacement token

    /// Records that the server issued `accessToken` to replace `expected`'s live token,
    /// before anything is sent with it. The replacement is stored with `pending`, and until
    /// `confirmHandover` settles it, a refusal of the live token waits for that answer
    /// instead of ending the sign-in. False, with nothing changed, unless `expected` is
    /// still the live session and nothing else is being handed over.
    @discardableResult
    public func beginHandover(expected: Session, pending: PendingUpgrade, accessToken: String, grantedScopes: [String],
                              check: @escaping CandidateCheck) -> Bool {
        transition.withLock {
            guard let live = signedIn, live.hasSameAccountAndToken(expected), pending.accountKey == live.accountKey,
                  accessToken != live.accessToken, lock.withLock({ handover == nil })
            else { return false }
            var stored = pending
            stored.issued = IssuedReplacement(accessToken: accessToken, scopes: grantedScopes, replaces: Self.fingerprint(live.accessToken))
            guard let data = try? JSONEncoder().encode(stored) else { return false }
            store.write(Keys.upgrade, data)
            lock.withLock {
                handover = Handover(accountKey: live.accountKey, server: live.server, replaces: live.accessToken,
                                    candidate: accessToken, scopes: grantedScopes, check: check)
            }
            return true
        }
    }

    /// Whether a replacement token for `session`'s live sign-in is waiting to be confirmed.
    public func hasPendingHandover(for session: Session) -> Bool {
        lock.withLock {
            guard let handover, let live = continuingLocked(session) else { return false }
            return handover.accountKey == live.accountKey && handover.replaces == live.accessToken
        }
    }

    /// Asks the server who the waiting replacement belongs to, once for everyone who asks
    /// meanwhile, and adopts it in place when it is this account's. With `refused`, the
    /// caller's request was refused with the token being replaced, so a replacement that
    /// can't be adopted ends the sign-in. A caller that is cancelled stops waiting; the
    /// check itself goes on for the others.
    public func confirmHandover(refused: Bool = false) async -> HandoverOutcome {
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HandoverOutcome, Never>) in
                var now: HandoverOutcome?
                var effects = Effects()
                transition.withLock {
                    lock.withLock {
                        guard !waiter.cancelled else { now = .unconfirmed; return }
                        guard let handover else { now = .ended; return }
                        if refused { handover.refused = true }
                        waiter.continuation = continuation
                        handover.waiters.append(waiter)
                        if !handover.isChecking, let check = handover.check ?? candidateCheck {
                            handover.isChecking = true
                            effects.start = (handover, check)
                        }
                    }
                    if now == nil, effects.start == nil, lock.withLock({ handover?.isChecking == false }) {
                        // Nothing can check this replacement here, so it can't be adopted.
                        effects = abandonLocked(.unconfirmed)
                    }
                }
                if let now { continuation.resume(returning: now) }
                perform(effects)
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<HandoverOutcome, Never>? in
                waiter.cancelled = true
                defer { waiter.continuation = nil }
                return waiter.continuation
            }
            continuation?.resume(returning: .unconfirmed)
        }
    }

    /// For work bound to `earlier`'s sign-in (or, without it, to whichever sign-in held
    /// `rejected`) whose request with `rejected` was refused: what to do next. Answers at
    /// once unless a replacement for `rejected` is waiting to be confirmed; then it waits
    /// for that answer. Never ends the sign-in itself: an `.ended` caller reports the
    /// refusal (`markExpired`), which ends it only if `rejected` is still the token in use.
    public func resolveRefusal(of rejected: Credential, signIn earlier: Session? = nil) async -> RefusalResolution {
        func settled() -> RefusalResolution? {
            lock.withLock {
                let holder: Session?
                if let earlier {
                    holder = continuingLocked(earlier)
                } else if case let .signedIn(live) = current, lineage.contains(Self.fingerprint(rejected.accessToken)) {
                    holder = live
                } else {
                    holder = nil
                }
                guard let live = holder, live.server == rejected.server else { return .ended }
                if live.accessToken != rejected.accessToken {
                    return .replay(Credential(server: live.server, accessToken: live.accessToken))
                }
                guard let handover, handover.accountKey == live.accountKey, handover.replaces == live.accessToken else { return .ended }
                return nil
            }
        }
        if let answer = settled() { return answer }
        let outcome = await confirmHandover(refused: true)
        if let answer = settled() { return answer }
        return outcome == .unconfirmed || Task.isCancelled ? .unconfirmed : .ended
    }

    private func startCheck(_ handover: Handover, _ check: @escaping CandidateCheck) {
        let candidate = Credential(server: handover.server, accessToken: handover.candidate)
        let task = Task.detached { [weak self] in
            let result: Result<Me, Error>
            do {
                result = .success(try await check(candidate))
            } catch {
                result = .failure(error)
            }
            self?.settle(handover, result)
        }
        lock.withLock { handover.task = task }
    }

    private func settle(_ settling: Handover, _ result: Result<Me, Error>) {
        run {
            guard lock.withLock({ handover === settling }), let live = signedIn,
                  live.accountKey == settling.accountKey, live.accessToken == settling.replaces
            else { return Effects() }
            switch result {
            case let .success(me) where me.id == live.user.id:
                let upgraded = Session(server: live.server, user: me, accessToken: settling.candidate, grantedScopes: settling.scopes)
                persist(Stored(server: upgraded.server, accessToken: upgraded.accessToken, user: upgraded.user, scopes: upgraded.grantedScopes))
                store.delete(Keys.upgrade)
                var effects = lock.withLock { () -> Effects in
                    var effects = Effects()
                    effects.released = release(settling, .adopted(upgraded))
                    handover = nil
                    return effects
                }
                let applied = apply(.signedIn(upgraded), continuingSignIn: true)
                effects.changed = applied.changed
                return effects
            case .success:
                return abandonLocked(.otherAccount(Credential(server: settling.server, accessToken: settling.candidate)))
            case .failure(APIError.unauthorized):
                return abandonLocked(.refused)
            case .failure:
                // Unanswered: keep the replacement for the next refusal or the next launch.
                return lock.withLock {
                    var effects = Effects()
                    settling.isChecking = false
                    settling.task = nil
                    effects.released = release(settling, .unconfirmed)
                    return effects
                }
            }
        }
    }

    /// Drops the live handover. With a refusal waiting on it, the token being replaced
    /// has been refused and nothing replaces it, so the sign-in ends. Caller holds `transition`.
    private func abandonLocked(_ outcome: HandoverOutcome) -> Effects {
        guard let dropped = lock.withLock({ handover }) else { return Effects() }
        if outcome == .unconfirmed && !dropped.refused {
            // Nothing was refused: keep it stored for a later check, but nobody waits here.
            return lock.withLock {
                var effects = Effects()
                effects.released = release(dropped, .unconfirmed)
                return effects
            }
        }
        store.delete(Keys.upgrade)
        var effects = lock.withLock { () -> Effects in
            var effects = Effects()
            effects.released = release(dropped, outcome == .unconfirmed ? .ended : outcome)
            effects.cancelled = dropped.task
            handover = nil
            return effects
        }
        if dropped.refused, let live = signedIn, live.accessToken == dropped.replaces {
            effects.changed = expireLocked(live).changed
        }
        return effects
    }

    /// Takes every waiting continuation of `handover`. Caller holds `lock`.
    private func release(_ handover: Handover, _ outcome: HandoverOutcome) -> [(CheckedContinuation<HandoverOutcome, Never>, HandoverOutcome)] {
        let taken = handover.waiters.compactMap { waiter -> CheckedContinuation<HandoverOutcome, Never>? in
            defer { waiter.continuation = nil }
            return waiter.continuation
        }
        handover.waiters = []
        return taken.map { ($0, outcome) }
    }

    // MARK: Pending upgrades

    public func savePendingUpgrade(_ pending: PendingUpgrade) {
        transition.withLock {
            // A replacement already issued for this sign-in is never overwritten by a new attempt.
            guard lock.withLock({ handover == nil }), storedUpgrade()?.issued == nil else { return }
            if let data = try? JSONEncoder().encode(pending) { store.write(Keys.upgrade, data) }
        }
    }

    /// The unfinished upgrade for `accountKey`; one for any other account is discarded.
    /// One whose replacement was already issued lasts until that is settled, however
    /// long ago its approval code expired.
    public func pendingUpgrade(accountKey: String, now: Date = Date()) -> PendingUpgrade? {
        transition.withLock {
            guard let pending = storedUpgrade() else { return nil }
            if pending.accountKey != accountKey || (pending.issued == nil && pending.expiresAt <= now) {
                store.delete(Keys.upgrade)
                return nil
            }
            return pending
        }
    }

    /// Forgets an unfinished approval. A replacement the server already issued is kept:
    /// the server may already have retired the token it replaces.
    public func clearPendingUpgrade() {
        transition.withLock {
            guard lock.withLock({ handover == nil }), storedUpgrade()?.issued == nil else { return }
            store.delete(Keys.upgrade)
        }
    }

    private func storedUpgrade() -> PendingUpgrade? {
        store.read(Keys.upgrade).flatMap { try? JSONDecoder().decode(PendingUpgrade.self, from: $0) }
    }

    // MARK: Ending a sign-in

    /// The server refused the token. Forget it, keep the address for re-authorizing.
    ///
    /// While a replacement for that token is waiting to be confirmed, the refusal waits
    /// for it instead: the server retires the old token as soon as the replacement is
    /// first used. The sign-in ends only if the replacement can't be adopted.
    public func markExpired(_ rejected: Credential) {
        run {
            guard let session = signedIn, session.server == rejected.server, session.accessToken == rejected.accessToken else { return Effects() }
            let deferred = lock.withLock { () -> Effects? in
                guard let handover, handover.accountKey == session.accountKey, handover.replaces == session.accessToken else { return nil }
                handover.refused = true
                var effects = Effects()
                if !handover.isChecking {
                    guard let check = handover.check ?? candidateCheck else { return nil }
                    handover.isChecking = true
                    effects.start = (handover, check)
                }
                return effects
            }
            if let deferred { return deferred }
            if lock.withLock({ handover != nil }) {
                var effects = abandonLocked(.refused)
                if effects.changed == nil { effects.changed = expireLocked(session).changed }
                return effects
            }
            return expireLocked(session)
        }
    }

    /// Caller holds `transition`.
    private func expireLocked(_ session: Session) -> Effects {
        persist(Stored(server: session.server, accessToken: "", user: session.user, scopes: session.grantedScopes))
        store.delete(Keys.upgrade)
        return apply(.expired(session.server, session.user.displayName))
    }

    public func clear() {
        run {
            store.delete(Keys.session)
            store.delete(Keys.authorization)
            store.delete(Keys.upgrade)
            return apply(.signedOut)
        }
    }

    private func persist(_ stored: Stored) {
        if let data = try? JSONEncoder().encode(stored) { store.write(Keys.session, data) }
    }

    /// One transition: `body` runs alone; what it leaves to do happens after every lock is released.
    private func run(_ body: () -> Effects) {
        let effects = transition.withLock(body)
        perform(effects)
    }

    private func perform(_ effects: Effects) {
        effects.cancelled?.cancel()
        for (continuation, outcome) in effects.released { continuation.resume(returning: outcome) }
        if let (handover, check) = effects.start { startCheck(handover, check) }
        if let changed = effects.changed { onChange?(changed) }
    }

    /// Sets the live state. A handover only survives while its sign-in keeps the token it
    /// replaces. Caller holds `transition`.
    private func apply(_ state: SessionState, continuingSignIn: Bool = false) -> Effects {
        lock.withLock {
            var effects = Effects()
            if continuingSignIn, case let .signedIn(session) = state {
                lineage.insert(Self.fingerprint(session.accessToken))
            } else {
                lineage = Self.lineage(starting: state)
            }
            current = state
            provisional = nil
            if let handover {
                let keeps: Bool
                if continuingSignIn, case let .signedIn(session) = state {
                    keeps = session.accountKey == handover.accountKey && session.accessToken == handover.replaces
                } else {
                    keeps = false
                }
                if !keeps {
                    effects.released = release(handover, .ended)
                    effects.cancelled = handover.task
                    self.handover = nil
                }
            }
            effects.changed = state
            return effects
        }
    }

    public func savePendingAuthorization(_ pending: PendingAuthorization) {
        if let data = try? JSONEncoder().encode(pending) { store.write(Keys.authorization, data) }
    }

    public func pendingAuthorization(now: Date = Date()) -> PendingAuthorization? {
        guard let data = store.read(Keys.authorization),
              let pending = try? JSONDecoder().decode(PendingAuthorization.self, from: data)
        else { return nil }
        if pending.expiresAt <= now {
            store.delete(Keys.authorization)
            return nil
        }
        return pending
    }

    public func clearPendingAuthorization() { store.delete(Keys.authorization) }
}

public enum AuthorizationOutcome: Equatable, Sendable {
    case approved(TokenResponse)
    case expired
    case denied
}

/// Runs the token polling loop for one grant. It stops at approval, expiry, denial
/// or task cancellation, and only ever has one request outstanding.
public struct DeviceAuthorizer: Sendable {
    private let exchange: @Sendable (ServerAddress, String) async throws -> TokenResponse
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void

    public init(
        exchange: @escaping @Sendable (ServerAddress, String) async throws -> TokenResponse,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.exchange = exchange
        self.now = now
        self.sleep = sleep
    }

    public func await(_ pending: PendingAuthorization) async throws -> AuthorizationOutcome {
        var interval = max(pending.grant.interval, 1)
        var failures = 0
        while true {
            let backoff = failures > 0 ? min(30, 1 << min(failures, 5)) : 0
            try await sleep(UInt64(interval + backoff) * 1_000_000_000)
            try Task.checkCancellation()
            if now() >= pending.expiresAt { return .expired }
            do {
                return .approved(try await exchange(pending.server, pending.grant.deviceCode))
            } catch let APIError.authorization(code) {
                failures = 0
                switch code {
                case "authorization_pending": continue
                case "slow_down": interval += 5
                case "access_denied": return .denied
                default: return .expired
                }
            } catch let error as APIError where error.isRetryable {
                // A dropped connection must not cost the user their sign-in attempt.
                failures += 1
            }
        }
    }
}
