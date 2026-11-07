import Foundation
import ShelfarrCore
import UIKit

/// The app's one system background session for downloads.
///
/// iOS runs its tasks in a separate daemon, so they continue while the app is suspended
/// and, after the system (not the user) ends the app, it relaunches the app in the
/// background to hand over the results. A force-quit from the app switcher cancels them,
/// and the system schedules them at its discretion, so nothing here promises a time.
///
/// Background sessions follow redirects without asking the delegate, and keep their
/// requests outside the Keychain. So this executor only ever receives requests whose sole
/// credential is an asset grant in the URL; `DownloadManager` never gives it the bearer.
/// Every result goes through the `TransferRouter`, which decides synchronously, before
/// the system deletes the file, whether the account that owns the task may keep it.
final class BackgroundDownloadSession: NSObject, DownloadExecutor, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "org.shelfarr.app.downloads"

    private let router: TransferRouter
    private let lock = NSLock()
    private var session: URLSession?
    /// Tasks created by this process, so a cancel finds them even before `allTasks` does.
    private var created: [TransferTag: URLSessionTask] = [:]
    private var eventsHandled: (() -> Void)?

    init(router: TransferRouter) {
        self.router = router
        super.init()
    }

    /// Creates the session, which reconnects to any transfers already in the daemon.
    /// Call after the signed-in account's manager is connected to the router, so the
    /// first callback already has an owner.
    func activate() {
        lock.withLock {
            guard session == nil else { return }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.httpMaximumConnectionsPerHost = 2
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }
    }

    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Returns false for a session that isn't this one.
    func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == Self.identifier else { return false }
        lock.withLock { eventsHandled = completionHandler }
        activate()
        return true
    }

    // MARK: DownloadExecutor

    func submit(_ request: URLRequest, tag: TransferTag, expectedBytes: Int64?) throws {
        // Defence in depth: the manager never hands this session the bearer.
        guard request.value(forHTTPHeaderField: "Authorization") == nil else { throw URLError(.userAuthenticationRequired) }
        guard let session = lock.withLock({ session }) else { throw URLError(.cannotLoadFromNetwork) }
        let task = session.downloadTask(with: request)
        task.taskDescription = tag.description
        if let expectedBytes { task.countOfBytesClientExpectsToReceive = expectedBytes + 4_096 }
        task.countOfBytesClientExpectsToSend = 4_096
        lock.withLock { created[tag] = task }
        task.resume()
    }

    func live() async -> [TransferTag] {
        guard let session = lock.withLock({ session }) else { return [] }
        let tasks = await session.allTasks
        return tasks
            .filter { $0.state == .running || $0.state == .suspended }
            .compactMap { TransferTag($0.taskDescription) }
    }

    /// The router has already revoked these tickets, so even a body that finishes in the
    /// meantime is never written.
    func cancel(_ tags: [TransferTag]) async {
        guard !tags.isEmpty, let session = lock.withLock({ session }) else { return }
        let wanted = Set(tags.map(\.description))
        var tasks = lock.withLock { tags.compactMap { created.removeValue(forKey: $0) } }
        tasks += await session.allTasks.filter { wanted.contains($0.taskDescription ?? "") }
        tasks.forEach { $0.cancel() }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file disappears when this returns.
        router.stage(downloadTask.taskDescription, temporaryFile: location)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        router.progress(downloadTask.taskDescription, received: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let tag = TransferTag(task.taskDescription) { _ = lock.withLock { created.removeValue(forKey: tag) } }
        router.complete(task.taskDescription, response: task.response as? HTTPURLResponse, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (() -> Void)? in
            defer { eventsHandled = nil }
            return eventsHandled
        }
        guard let handler else { return }
        // Only once every delivered event is on disk; Apple requires the main queue.
        router.whenIdle { DispatchQueue.main.async(execute: handler) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A background relaunch has no UI: the model and its session must exist anyway.
        _ = AppModel.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if !AppModel.shared.backgroundDownloads.handleEvents(for: identifier, completionHandler: completionHandler) {
            completionHandler()
        }
    }
}
