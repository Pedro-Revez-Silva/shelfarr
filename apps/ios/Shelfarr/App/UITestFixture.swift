#if DEBUG
import Foundation
import ShelfarrCore

/// A signed-in account for the simulator smoke test, and nothing else.
///
/// Only Debug builds contain this, and it does anything only when the UI test launches
/// the app with `-shelfarr-ui-test` and a server, token and user in its environment. The
/// session then lives in memory instead of the Keychain; everything after sign-in uses the
/// app's ordinary code paths. Release builds never compile it.
enum UITestFixture {
    static let argument = "-shelfarr-ui-test"
    static let resetArgument = "-shelfarr-ui-test-reset"

    private final class MemoryStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        func read(_ name: String) -> Data? { lock.withLock { values[name] } }
        func write(_ name: String, _ value: Data) { lock.withLock { values[name] = value } }
        func delete(_ name: String) { _ = lock.withLock { values.removeValue(forKey: name) } }
    }

    static func secretStore() -> SecretStore? {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains(argument) else { return nil }
        if process.arguments.contains(resetArgument) { reset() }
        let environment = process.environment
        let store = MemoryStore()
        guard let address = environment["SHELFARR_UITEST_SERVER"],
              case let .valid(server) = ServerAddress.parse(address, allowLocalHTTP: true),
              let token = environment["SHELFARR_UITEST_TOKEN"], !token.isEmpty,
              let userId = environment["SHELFARR_UITEST_USER_ID"]
        else { return store }
        let user = Me(id: userId, name: environment["SHELFARR_UITEST_USER_NAME"], username: nil)
        SessionManager(store: store).signIn(Session(server: server, user: user, accessToken: token))
        return store
    }

    /// A clean device: no downloads, cached books, metadata or saved places.
    private static func reset() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? manager.removeItem(at: support.appendingPathComponent("accounts", isDirectory: true))
        try? manager.removeItem(at: caches.appendingPathComponent("epub", isDirectory: true))
        try? manager.removeItem(at: manager.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true))
    }
}
#endif
