import Foundation

/// Everything Find needs from the account, so it runs against a fixture in tests.
@MainActor
public protocol FindBackend: AnyObject {
    var access: RequestAccess { get }
    func refreshAccess() async
    /// Starts browser approval; the page to open, or nil if nothing should open.
    func allowRequesting() async -> URL?
    func cancelApproval()
    /// Asks the server what this credential may do now, after a 403.
    func refreshScopes() async
    func discover(_ query: String) async throws -> [DiscoverItem]
    func requests() async throws -> [RequestItem]
    func request(_ id: String) async throws -> RequestItem
    func create(_ request: NewRequest) async throws -> RequestOutcome
    func cancel(_ id: String) async throws -> RequestItem
}

public struct FindState: Equatable, Sendable {
    public var query = ""
    /// The query the shown results answer; results stay while a new search runs.
    public var searchedFor: String?
    public var searching = false
    public var results: [DiscoverItem] = []
    public var searchError: APIError?
    public var requests: [RequestItem] = []
    public var requestsLoaded = false
    /// Set when the list shown is from earlier because the server can't be reached.
    public var requestsError: APIError?

    public init() {}
}

public struct TitleState: Equatable, Sendable {
    public var item: DiscoverItem?
    public var format: BookType?
    public var submitting = false
    public var message: String?

    public init(item: DiscoverItem? = nil, format: BookType? = nil) {
        self.item = item
        self.format = format
    }
}

public struct TrackState: Equatable, Sendable {
    public var request: RequestItem?
    public var loading = false
    public var error: APIError?
    public var cancelling = false
    public var cancelMessage: String?

    public init(request: RequestItem? = nil, loading: Bool = false) {
        self.request = request
        self.loading = loading
    }
}

/// Find, choose a format, request, follow it, open it. Shared by the Find tab, the title
/// page and the request page, so a result tapped in one is the one shown in the next.
@MainActor
public final class FindFlow {
    public private(set) var find = FindState() { didSet { changed() } }
    public private(set) var title = TitleState() { didSet { changed() } }
    public private(set) var track = TrackState() { didSet { changed() } }
    public var onChange: (() -> Void)?
    /// A request page to show, after a request was made or an existing one chosen.
    public var onShowRequest: ((String) -> Void)?

    private let backend: FindBackend
    private let pollInterval: UInt64
    private var searchTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?

    public init(backend: FindBackend, pollIntervalNanoseconds: UInt64 = 5_000_000_000) {
        self.backend = backend
        pollInterval = pollIntervalNanoseconds
    }

    private func changed() { onChange?() }

    public var access: RequestAccess { backend.access }

    public func onShown() async {
        await backend.refreshAccess()
        if backend.access == .allowed { await loadRequests() }
    }

    /// Starts browser approval for requesting; the page to open, if any.
    public func allowRequesting() async -> URL? {
        let url = await backend.allowRequesting()
        changed()
        return url
    }

    public func cancelApproval() {
        backend.cancelApproval()
        changed()
    }

    public func setQuery(_ value: String) { find.query = String(value.prefix(200)) }

    public func search() {
        let query = find.query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !query.isEmpty else {
            find.searchedFor = nil
            find.results = []
            find.searchError = nil
            find.searching = false
            return
        }
        find.searching = true
        find.searchError = nil
        searchTask = Task {
            do {
                let items = try await backend.discover(query)
                guard !Task.isCancelled else { return }
                find.results = items
                find.searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                if error as? APIError == .forbidden { await backend.refreshScopes() }
                find.results = []
                find.searchError = error as? APIError ?? .protocolError
            }
            find.searchedFor = query
            find.searching = false
        }
    }

    /// Completes when the current search has finished.
    public func searchSettled() async { await searchTask?.value }

    public func loadRequests() async {
        if let listTask { return await listTask.value }
        let task = Task {
            do {
                find.requests = try await backend.requests()
                find.requestsError = nil
            } catch {
                if error as? APIError == .forbidden { await backend.refreshScopes() }
                find.requestsError = error as? APIError ?? .protocolError
            }
            find.requestsLoaded = true
        }
        listTask = task
        await task.value
        listTask = nil
    }

    public func choose(_ item: DiscoverItem) {
        let requestable = [BookType.ebook, .audiobook].first { item.format($0)?.state == .requestable }
        title = TitleState(item: item, format: requestable)
    }

    public func selectFormat(_ type: BookType) {
        guard title.item?.format(type)?.state == .requestable else { return }
        title.format = type
        title.message = nil
    }

    /// Requests the chosen format once. Further taps while it is in flight do nothing.
    public func submit() {
        guard let item = title.item, let format = title.format, !title.submitting else { return }
        title.submitting = true
        title.message = nil
        submitTask = Task {
            do {
                switch try await backend.create(NewRequest(item, format)) {
                case let .created(request), let .existing(request):
                    updateFormat(item, format) { $0.state = .requested; $0.request = request }
                    find.requests = [request] + find.requests.filter { $0.id != request.id }
                    title.submitting = false
                    track = TrackState(request: request)
                    onShowRequest?(request.id)
                case let .inLibrary(publicationId, _):
                    updateFormat(item, format) { $0.state = .inLibrary; $0.publicationId = publicationId }
                    title.submitting = false
                    title.format = nil
                    title.message = "This \(format.word) is already in the library."
                case let .requestedBySomeone(message):
                    updateFormat(item, format) { $0.state = .requestedBySomeone }
                    title.submitting = false
                    title.format = nil
                    title.message = message ?? "Someone on this server already asked for this \(format.word). It will appear in the library when it arrives."
                case let .refused(message):
                    title.submitting = false
                    title.message = message ?? "The server didn't accept this request."
                }
            } catch {
                if error as? APIError == .forbidden { await backend.refreshScopes() }
                title.submitting = false
                title.message = requestFailureMessage(error)
            }
        }
    }

    /// Completes when the current submission has finished.
    public func submitSettled() async { await submitTask?.value }

    public func openRequest(_ request: RequestItem) {
        track = TrackState(request: request)
        onShowRequest?(request.id)
    }

    /// Polls the shown request while its page is visible.
    public func startTracking(_ id: String) {
        if track.request?.id != id { track = TrackState(loading: true) }
        trackTask?.cancel()
        trackTask = Task {
            while !Task.isCancelled {
                do {
                    let fresh = try await backend.request(id)
                    guard !Task.isCancelled else { return }
                    track.request = fresh
                    track.loading = false
                    track.error = nil
                    replaceInList(fresh)
                    if !fresh.stage.isOpen { return }
                } catch {
                    guard !Task.isCancelled else { return }
                    let apiError = error as? APIError ?? .protocolError
                    if apiError == .forbidden { await backend.refreshScopes() }
                    track.loading = false
                    track.error = apiError
                    if !apiError.isRetryable { return }
                }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    public func stopTracking() {
        trackTask?.cancel()
        trackTask = nil
    }

    /// Completes when tracking has stopped by itself (finished or a lasting error).
    public func trackingSettled() async { await trackTask?.value }

    public func cancelRequest() async {
        guard let request = track.request, !track.cancelling else { return }
        track.cancelling = true
        track.cancelMessage = nil
        do {
            let updated = try await backend.cancel(request.id)
            track.request = updated
            replaceInList(updated)
        } catch {
            track.cancelMessage = requestFailureMessage(error)
        }
        track.cancelling = false
    }

    private func updateFormat(_ item: DiscoverItem, _ type: BookType, _ change: (inout FormatOption) -> Void) {
        var updated = item
        updated.formats = item.formats.map { option in
            var option = option
            if option.bookType == type { change(&option) }
            return option
        }
        if title.item?.id == item.id { title.item = updated }
        find.results = find.results.map { $0.id == item.id ? updated : $0 }
    }

    private func replaceInList(_ request: RequestItem) {
        find.requests = find.requests.map { $0.id == request.id ? request : $0 }
    }
}
