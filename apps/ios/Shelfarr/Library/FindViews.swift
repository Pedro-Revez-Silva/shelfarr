import ShelfarrCore
import SwiftUI

/*
 * Find is its own tab, not part of Library search: Library is what you have, Find is
 * asking for something new. Each step is a full page with large targets and text
 * that wraps at every Dynamic Type size, and nothing is requested on a stray tap:
 * a title opens a page where the format is chosen and the request is one button.
 */

/// The signed-in account seen through `FindBackend`.
@MainActor
final class AppFindBackend: FindBackend {
    private let app: AppModel

    init(app: AppModel) { self.app = app }

    private func session() throws -> Session {
        guard let session = app.session else { throw APIError.unauthorized }
        return session
    }

    var access: RequestAccess { app.requesting.state }

    func refreshAccess() async {
        if let session = app.session { await app.requesting.refresh(session) }
    }

    func allowRequesting() async -> URL? {
        guard let session = app.session else { return nil }
        return await app.requesting.start(session)
    }

    func cancelApproval() { app.requesting.cancel() }

    func refreshScopes() async {
        guard let session = app.session, let me = try? await app.api(for: session).me(server: session.server) else { return }
        app.sessions.refreshUser(me, expected: session)
        await refreshAccess()
    }

    func discover(_ query: String) async throws -> [DiscoverItem] {
        let session = try session()
        return try await app.api(for: session).discover(server: session.server, query: query)
    }

    func requests() async throws -> [RequestItem] {
        let session = try session()
        return try await app.api(for: session).requests(server: session.server)
    }

    func request(_ id: String) async throws -> RequestItem {
        let session = try session()
        return try await app.api(for: session).request(server: session.server, id: id)
    }

    func create(_ request: NewRequest) async throws -> RequestOutcome {
        let session = try session()
        return try await app.api(for: session).createRequest(server: session.server, request)
    }

    func cancel(_ id: String) async throws -> RequestItem {
        let session = try session()
        return try await app.api(for: session).cancelRequest(server: session.server, id: id)
    }
}

enum FindRoute: Hashable {
    case title
    case request(String)
    case details(String)
}

/// Publishes `FindFlow` and the requesting permission for SwiftUI.
@MainActor
final class FindModel: ObservableObject {
    let flow: FindFlow
    @Published var path: [FindRoute] = []
    @Published private(set) var revision = 0
    @Published var opening = false
    @Published var openError: String?

    init(app: AppModel) {
        flow = FindFlow(backend: AppFindBackend(app: app))
        flow.onChange = { [weak self] in self?.revision += 1 }
        flow.onShowRequest = { [weak self] id in
            guard let self else { return }
            // A new request replaces its title page, so Back returns to Find.
            if self.path.last == .title { self.path.removeLast() }
            self.path.append(.request(id))
        }
        let previous = app.requesting.onChange
        app.requesting.onChange = { [weak self] state in
            previous?(state)
            self?.revision += 1
        }
    }

    func open(_ publicationId: String, app: AppModel, then start: @escaping (ShelfarrCore.Publication) -> Void) async {
        guard !opening, let session = app.session else { return }
        opening = true
        openError = nil
        defer { opening = false }
        do {
            let metadata = try await app.publications(for: session).load(id: publicationId, server: session.server, api: app.api(for: session))
            start(metadata.publication)
        } catch {
            openError = requestFailureMessage(error)
        }
    }
}

struct FindTab: View {
    @StateObject private var model: FindModel
    let open: (ShelfarrCore.Publication) -> Void

    init(app: AppModel, open: @escaping (ShelfarrCore.Publication) -> Void) {
        // Built once for the tab's lifetime.
        _model = StateObject(wrappedValue: FindModel(app: app))
        self.open = open
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            FindView(model: model)
                .navigationDestination(for: FindRoute.self) { route in
                    switch route {
                    case .title: FindTitleView(model: model)
                    case let .request(id): RequestTrackView(model: model, requestId: id, open: open)
                    case let .details(id): DetailsView(publicationId: id, open: open)
                    }
                }
        }
    }
}

struct FindView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: FindModel
    @Environment(\.openURL) private var openURL

    private var host: String { app.session?.server.host ?? "your server" }

    var body: some View {
        let _ = model.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Find")
                    .font(Typeface.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                switch model.flow.access {
                case .checking:
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                case .serverTooOld:
                    explainer(
                        title: "Requesting isn't available on \(host)",
                        body: "This server's version of Shelfarr doesn't offer requesting from the app. Reading and listening work as usual, and you can still request books on the website.",
                        action: "Open the website"
                    ) { if let url = app.session?.server.baseURL { openURL(url) } }
                case let .notAllowed(notice):
                    explainer(
                        title: "Find new books",
                        body: "Search beyond your library and request ebooks and audiobooks as \(app.session?.user.displayName ?? "you"). You approve this once in your browser. Your library, downloads and saved places stay exactly as they are.",
                        action: "Allow requesting",
                        notice: notice
                    ) {
                        Task { if let url = await model.flow.allowRequesting() { openURL(url) } }
                    }
                case let .approving(code, verification, browser, expiresAt):
                    approving(code: code, verification: verification, browser: browser, expiresAt: expiresAt)
                case .allowed:
                    searchable
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.flow.onShown() }
        .task(id: model.flow.find.requests.contains { $0.stage.isOpen }) {
            // While Find is visible, keep open requests current at a gentle pace.
            while !Task.isCancelled, model.flow.find.requests.contains(where: { $0.stage.isOpen }) {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await model.flow.loadRequests()
            }
        }
    }

    private func explainer(title: String, body: String, action: String, notice: String? = nil, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(Palette.inkMuted)
            Text(title).font(Typeface.display(24, relativeTo: .title2)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Text(body).font(.body).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            if let notice { NoticeView(text: notice) }
            Button(action, action: perform).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
                .accessibilityIdentifier("find-explainer-action")
        }
    }

    private func approving(code: String, verification: URL, browser: URL, expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve in your browser").font(Typeface.display(24, relativeTo: .title2)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            Text("Check that the page shows this code, then choose Allow requesting. Come back here when you're done.")
                .foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            Text(code)
                .font(.system(.largeTitle, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Or open \(verification.absoluteString) and enter the code. It expires in \(formatDuration(max(expiresAt.timeIntervalSince(context.date), 0))).")
                    .font(.footnote).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open browser") { openURL(browser) }.buttonStyle(PrimaryButtonStyle())
            Button("Cancel") { model.flow.cancelApproval() }.frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder
    private var searchable: some View {
        let state = model.flow.find
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkMuted)
            TextField("Title or author", text: Binding(get: { state.query }, set: { model.flow.setQuery($0) }))
                .submitLabel(.search)
                .onSubmit { model.flow.search() }
                .accessibilityIdentifier("find-query")
            Button { model.flow.search() } label: { Image(systemName: "arrow.right").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Search")
                .accessibilityIdentifier("find-submit")
        }
        .padding(.leading, 14)
        .frame(minHeight: 52)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        let showingResults = state.searchedFor != nil || state.searching
        if state.searching { ProgressView().frame(maxWidth: .infinity).padding() }
        if showingResults, !state.searching {
            if let error = state.searchError {
                NoticeView(text: searchProblem(error))
                Button("Try again") { model.flow.search() }.frame(minHeight: 44)
            } else if state.results.isEmpty {
                Text("Nothing found for “\(state.searchedFor ?? "")”. Try fewer words, or the author's name.")
                    .foregroundStyle(Palette.inkMuted)
            } else {
                ForEach(state.results) { item in
                    Button {
                        model.flow.choose(item)
                        model.path.append(.title)
                    } label: { ResultRow(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("result:\(item.id)")
                }
            }
        }
        if !state.requests.isEmpty || state.requestsError != nil {
            Text("Your requests").font(Typeface.serifBold(19)).foregroundStyle(Palette.ink).padding(.top, showingResults ? 18 : 4)
                .accessibilityAddTraits(.isHeader)
            if let error = state.requestsError {
                HStack {
                    Text(error == .offline(certificate: false)
                        ? (state.requests.isEmpty ? "You're offline. Your requests appear when \(host) can be reached." : "You're offline. These are from earlier.")
                        : errorCopy(error, host: host).message)
                        .font(.footnote).foregroundStyle(Palette.inkMuted)
                    Spacer()
                    Button("Retry") { Task { await model.flow.loadRequests() } }.frame(minHeight: 44)
                }
            }
            ForEach(state.requests) { request in
                Button {
                    model.flow.openRequest(request)
                } label: { RequestRow(request: request) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("request:\(request.id)")
            }
        } else if !showingResults, state.requestsLoaded {
            Text("Search for a title or author. Requests you make appear here so you can follow them.")
                .foregroundStyle(Palette.inkMuted)
        }
    }

    private func searchProblem(_ error: APIError) -> String {
        switch error {
        case .offline(certificate: false): return "You're offline. Finding new books needs a connection to \(host)."
        case .forbidden: return "This connection can't search any more. Allow requesting again to continue."
        case .server(503): return "\(host) couldn't reach its book catalogues. Try again in a moment."
        case let .server(status): return "\(host) couldn't search right now (error \(status)). Try again in a moment."
        default: return errorCopy(error, host: host).message
        }
    }
}

struct NoticeView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.inkMuted)
            Text(text).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ResultRow: View {
    let item: DiscoverItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCover(publication: item.coverPublication).frame(width: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(Typeface.serifBold(18)).foregroundStyle(Palette.ink)
                let byline = [item.author, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                if !byline.isEmpty { Text(byline).font(.subheadline).foregroundStyle(Palette.inkMuted) }
                Text(item.formatsLine).font(.footnote.weight(.medium)).foregroundStyle(Palette.inkMuted).padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose a format")
    }
}

private struct RequestRow: View {
    let request: RequestItem

    var body: some View {
        HStack(spacing: 14) {
            BookCover(publication: request.coverPublication).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).foregroundStyle(Palette.ink)
                Text("\(request.bookType.label) · \(request.stageCopy.headline)")
                    .font(.footnote)
                    .foregroundStyle(request.isReady ? Palette.accent : Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Palette.inkMuted)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A search result, where the format is chosen and the request made.
struct FindTitleView: View {
    @ObservedObject var model: FindModel

    var body: some View {
        let _ = model.revision
        let state = model.flow.title
        ScrollView {
            if let item = state.item {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 18) {
                        BookCover(publication: item.coverPublication, corner: 6).frame(width: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(Typeface.display(26, relativeTo: .title)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                            if let author = item.author { Text(author).foregroundStyle(Palette.inkMuted) }
                            let extra = [item.year.map(String.init), item.seriesName.map { series in item.seriesPosition.map { "\(series), book \($0)" } ?? series }]
                                .compactMap { $0 }.joined(separator: " · ")
                            if !extra.isEmpty { Text(extra).font(.footnote).foregroundStyle(Palette.inkMuted) }
                        }
                    }
                    Text("Choose a format").font(Typeface.serifBold(19)).foregroundStyle(Palette.ink).padding(.top, 28).padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 10) {
                        ForEach([BookType.ebook, .audiobook], id: \.self) { type in
                            FormatRow(option: item.format(type) ?? FormatOption(bookType: type), selected: state.format == type, model: model)
                        }
                    }
                    if let message = state.message { NoticeView(text: message).padding(.top, 16) }
                    if let format = state.format {
                        Button(state.submitting ? "Requesting…" : "Request \(format.word)") { model.flow.submit() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(state.submitting)
                            .padding(.top, 20)
                            .accessibilityIdentifier("request-submit")
                        Text("Shelfarr looks for a copy and adds it to the library for everyone on this server. It can take a while; you can follow it here.")
                            .font(.footnote).foregroundStyle(Palette.inkMuted).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
                    } else if !item.formats.contains(where: { $0.state == .requestable }) {
                        Text("There's nothing left to request for this title.").foregroundStyle(Palette.inkMuted).padding(.top, 20)
                    }
                    if let description = item.description, !description.isEmpty {
                        Text(description).font(Typeface.serif(17)).foregroundStyle(Palette.ink).padding(.top, 28)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FormatRow: View {
    let option: FormatOption
    let selected: Bool
    @ObservedObject var model: FindModel

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(selected ? Palette.accent : Palette.inkMuted).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.bookType.label).font(Typeface.serifBold(17)).foregroundStyle(Palette.ink)
                    Text(option.summary).font(.footnote).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if option.state == .inLibrary, option.publicationId != nil {
                    Text("Open").font(.callout.weight(.medium)).foregroundStyle(Palette.accent)
                } else if option.state == .requested {
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Palette.inkMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Palette.accent : Palette.hairline, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("format:\(option.bookType.word)")
    }

    private var icon: String {
        switch option.state {
        case .requestable: return selected ? "largecircle.fill.circle" : "circle"
        case .inLibrary: return "checkmark.circle"
        default: return option.bookType == .audiobook ? "headphones" : "book"
        }
    }

    private func activate() {
        switch option.state {
        case .requestable: model.flow.selectFormat(option.bookType)
        case .inLibrary: if let id = option.publicationId { model.path.append(.details(id)) }
        case .requested: if let request = option.request { model.flow.openRequest(request) }
        default: break
        }
    }
}

/// Follows one request to the moment it can be opened.
struct RequestTrackView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: FindModel
    let requestId: String
    let open: (ShelfarrCore.Publication) -> Void
    @State private var confirming = false

    var body: some View {
        let _ = model.revision
        let state = model.flow.track
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let request = state.request {
                    content(request, state)
                } else if let error = state.error {
                    let copy = errorCopy(error, host: app.session?.server.host)
                    MessageState(title: copy.title, message: copy.message, action: copy.retryable ? "Try again" : nil) { model.flow.startTracking(requestId) }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.flow.startTracking(requestId) }
        .onDisappear { model.flow.stopTracking() }
        .confirmationDialog("Cancel this request?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Cancel request", role: .destructive) { Task { await model.flow.cancelRequest() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Shelfarr stops looking for it. You can request it again later.")
        }
    }

    @ViewBuilder
    private func content(_ request: RequestItem, _ state: TrackState) -> some View {
        let copy = request.stageCopy
        HStack(alignment: .top, spacing: 18) {
            BookCover(publication: request.coverPublication, corner: 6).frame(width: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title).font(Typeface.display(24, relativeTo: .title)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                Text([request.author, request.bookType.label].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Palette.inkMuted)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(copy.headline).font(Typeface.display(22, relativeTo: .title2)).foregroundStyle(Palette.ink)
            Text(copy.detail).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("request-stage")
        if request.stage == .downloading, let percent = request.downloadPercent {
            ProgressRule(fraction: Double(percent) / 100).padding(.top, 14)
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(RequestItem.steps.enumerated()), id: \.offset) { index, label in
                let reached = request.stepReached
                let done = reached >= 0 && (index < reached || (reached == RequestItem.steps.count - 1 && index == reached))
                let current = index == reached && !done
                HStack(spacing: 12) {
                    Circle().fill(done ? Palette.accent : current ? Palette.accent.opacity(0.45) : Palette.hairline).frame(width: 10, height: 10)
                    Text(label).font(current ? Font.callout.weight(.semibold) : Font.footnote).foregroundStyle(done || current ? Palette.ink : Palette.inkMuted)
                }
            }
        }
        .padding(.top, 20)
        .accessibilityElement(children: .combine)
        if let error = state.error {
            Text(error == .offline(certificate: false) ? "Offline. Showing the last update; this page refreshes when the connection is back." : errorCopy(error, host: app.session?.server.host).message)
                .font(.footnote).foregroundStyle(Palette.inkMuted).padding(.top, 16)
        }
        if let message = state.cancelMessage ?? model.openError { NoticeView(text: message).padding(.top, 16) }
        if request.isReady, let publication = request.publicationId {
            Button(model.opening ? "Opening…" : (request.bookType == .ebook ? "Read now" : "Listen now")) {
                Task { await model.open(publication, app: app, then: open) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.opening)
            .padding(.top, 24)
            .accessibilityIdentifier("request-open")
            Button("Details and download") { model.path.append(.details(publication)) }.frame(minHeight: 44)
        } else if request.canCancel, request.stage.isOpen {
            Button(state.cancelling ? "Cancelling…" : "Cancel request") { confirming = true }
                .disabled(state.cancelling)
                .frame(minHeight: 44)
                .padding(.top, 24)
                .accessibilityIdentifier("request-cancel")
        }
    }
}
