import ShelfarrCore
import SwiftUI

@MainActor
final class PlayerModel: ObservableObject {
    enum State {
        case loading
        case chooseResume(ShelfarrCore.Publication, local: SavedPosition, server: ReadingProgress)
        case active(notice: String?)
        case failed(Error)
        case noAudio
    }

    @Published private(set) var state = State.loading
    @Published private(set) var syncStatus = SyncStatus.idle

    private let app: AppModel
    private let owner: Session?
    private let publicationId: String
    private let sync: ProgressSync?

    init(app: AppModel, publicationId: String) {
        self.app = app
        owner = app.session
        self.publicationId = publicationId
        sync = app.progressRegistry()?.sync(for: publicationId)
    }

    func start() async {
        guard let sync, let session = owner, app.session == session else {
            state = .failed(APIError.unauthorized)
            return
        }
        await sync.observe { [weak self] status in
            Task { @MainActor in self?.syncStatus = status }
        }
        if app.playback.publication?.id == publicationId {
            state = .active(notice: nil)
            return
        }
        state = .loading
        do {
            let publication = try await app.api(for: session).publication(server: session.server, id: publicationId)
            guard app.session == session else { throw CancellationError() }
            if publication.audioAssets.isEmpty {
                state = .noAudio
                return
            }
            let local = await sync.snapshot()
            switch ResumeDecision.decide(publication: publication, server: publication.progress, local: local) {
            case .beginning:
                await play(publication, nil, baseVersion: 0)
            case let .resume(position, baseVersion):
                await play(publication, position, baseVersion: baseVersion)
            case let .choose(local, server):
                state = .chooseResume(publication, local: local, server: server)
            case let .editionChanged(staleVersion):
                await play(
                    publication,
                    nil,
                    baseVersion: staleVersion,
                    notice: "These audio files were replaced, so your old place doesn't apply. Starting from the beginning."
                )
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error)
        }
    }

    func chooseResume(keepLocal: Bool) async {
        guard case let .chooseResume(publication, local, server) = state else { return }
        let position = keepLocal ? local : SavedPosition(server)
        await sync?.chooseAtOpen(position: position, serverVersion: server.version, keepLocal: keepLocal)
        await play(publication, position, baseVersion: server.version)
    }

    private func play(_ publication: ShelfarrCore.Publication, _ start: SavedPosition?, baseVersion: Int, notice: String? = nil) async {
        guard let session = owner, app.session == session, let sync else { return }
        await sync.begin(position: start, baseVersion: baseVersion)
        app.playback.load(publication, server: session.server, api: app.api(for: session), sync: sync, start: start)
        state = .active(notice: notice)
    }

    func keepThisPlace() {
        guard let sync else { return }
        Task { await sync.keepLocal() }
    }

    func useOtherPlace() {
        guard let sync else { return }
        let playback = app.playback
        Task {
            if let position = await sync.useServer() { playback.jump(to: position) }
        }
    }
}

struct PlayerView: View {
    @StateObject private var model: PlayerModel
    @ObservedObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: PlayerSheet?
    private let host: String?

    init(publicationId: String, app: AppModel) {
        _model = StateObject(wrappedValue: PlayerModel(app: app, publicationId: publicationId))
        playback = app.playback
        host = app.session?.server.host
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").frame(width: 44, height: 44)
                }
                .tint(Palette.ink)
                .accessibilityLabel("Close player")
                Spacer()
            }
            .padding(.horizontal, 4)
            content
        }
        .background(Palette.background.ignoresSafeArea())
        .task { await model.start() }
        .sheet(item: $sheet) { which in
            PlayerOptionsSheet(which: which, playback: playback).presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .chooseResume(_, local, server):
            Color.clear.alert("Where would you like to continue?", isPresented: .constant(true)) {
                Button("Use other device") { Task { await model.chooseResume(keepLocal: false) } }
                Button("Keep this device") { Task { await model.chooseResume(keepLocal: true) } }
            } message: {
                Text(choiceMessage(local, server))
            }
        case let .failed(error):
            let copy = errorCopy(error, host: host)
            MessageState(title: copy.title, message: copy.message, systemImage: "wifi.slash", action: copy.retryable ? "Try again" : nil) {
                Task { await model.start() }
            }
        case .noAudio:
            MessageState(title: "Nothing to play", message: "This publication has no audio file the app can play.")
        case let .active(notice):
            if let publication = playback.publication {
                nowPlaying(publication, notice)
                if case let .conflict(local?, server) = model.syncStatus {
                    Color.clear.frame(height: 0).alert("Where would you like to continue?", isPresented: .constant(true)) {
                        Button("Use other device", action: model.useOtherPlace)
                        Button("Keep this device", action: model.keepThisPlace)
                    } message: {
                        Text(choiceMessage(local, server))
                    }
                }
            } else {
                MessageState(title: "Playback stopped", message: "Open this audiobook again to carry on.")
            }
        }
    }

    private func choiceMessage(_ local: SavedPosition, _ server: ReadingProgress) -> String {
        "This device: \(describePlace(locator: local.locator, seconds: local.positionSeconds))\n"
            + "Other device: \(describePlace(locator: server.locator, seconds: server.positionSeconds))"
    }

    private func nowPlaying(_ publication: ShelfarrCore.Publication, _ notice: String?) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    BookCover(publication: publication, corner: 8)
                        .frame(maxWidth: min(geometry.size.width - 72, geometry.size.height * 0.44, 420))
                    Text(publication.title)
                        .font(Typeface.display(22))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, 24)
                    if let author = publication.author {
                        Text(author).font(.subheadline).foregroundStyle(Palette.inkMuted).lineLimit(1)
                    }
                    if let line = placeLine {
                        Text(line).font(.footnote.weight(.medium)).foregroundStyle(Palette.accent).lineLimit(1).padding(.top, 8)
                    }
                    if let notice {
                        Text(notice).font(.footnote).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center).padding(.top, 10)
                    }
                    if let problem = playback.problem {
                        Text(problem.message).font(.footnote).foregroundStyle(Palette.danger).multilineTextAlignment(.center).padding(.top, 10)
                    }
                    Scrubber(playback: playback).padding(.top, 16)
                    Transport(playback: playback).padding(.top, 8)
                    HStack {
                        Spacer()
                        Button(speedLabel(playback.speed)) { sheet = .speed }
                        Spacer()
                        Button { sheet = .sleep } label: {
                            Label(playback.sleepEndsAt == nil ? "Sleep" : "Sleep on", systemImage: "moon")
                        }
                        Spacer()
                        if playback.tracks.count > 1 || !playback.chapters.isEmpty {
                            Button { sheet = .contents } label: {
                                Label(playback.chapters.isEmpty ? "Tracks" : "Chapters", systemImage: "list.bullet")
                            }
                            Spacer()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .tint(Palette.ink)
                    .padding(.top, 20)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
    }

    private var placeLine: String? {
        if let index = playback.chapterIndex, playback.chapters.indices.contains(index) {
            return playback.chapters[index].title ?? "Chapter \(index + 1)"
        }
        if playback.tracks.count > 1 { return "Track \(playback.trackIndex + 1) of \(playback.tracks.count)" }
        return nil
    }
}

func speedLabel(_ speed: Float) -> String {
    let text = String(format: "%.2f", speed)
    let trimmed = text.hasSuffix("0") ? String(text.dropLast()) : text
    return trimmed + "×"
}

private struct Scrubber: View {
    @ObservedObject var playback: PlaybackEngine
    @State private var scrubbing: Double?

    var body: some View {
        let shown = scrubbing ?? playback.position
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shown }, set: { scrubbing = $0 }),
                in: 0 ... max(playback.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        playback.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            .disabled(playback.duration <= 0)
            .accessibilityLabel("Position")
            .accessibilityValue("\(formatDuration(shown)) of \(formatDuration(playback.duration))")
            HStack {
                Text(formatDuration(shown))
                Spacer()
                Text(playback.duration > 0 ? "-\(formatDuration(playback.duration - shown))" : "--:--")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Palette.inkMuted)
        }
    }
}

private struct Transport: View {
    @ObservedObject var playback: PlaybackEngine

    private var canStep: Bool { !playback.chapters.isEmpty || playback.tracks.count > 1 }

    var body: some View {
        HStack {
            if canStep {
                Button(action: previous) { Image(systemName: "backward.end").font(.title3).frame(width: 44, height: 44) }
                    .disabled(playback.chapters.isEmpty && playback.trackIndex == 0)
                    .accessibilityLabel("Previous")
            }
            Spacer()
            Button { playback.skip(by: -PlaybackEngine.skipBack) } label: {
                Image(systemName: "gobackward.15").font(.title).frame(width: 56, height: 56)
            }
            .accessibilityLabel("Back 15 seconds")
            Spacer()
            Button(action: playback.togglePlay) {
                ZStack {
                    Circle().fill(Palette.accent)
                    if playback.isBuffering {
                        ProgressView().tint(Palette.onAccent)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(Palette.onAccent)
                    }
                }
                .frame(width: 76, height: 76)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { playback.skip(by: PlaybackEngine.skipForward) } label: {
                Image(systemName: "goforward.30").font(.title).frame(width: 56, height: 56)
            }
            .accessibilityLabel("Forward 30 seconds")
            Spacer()
            if canStep {
                Button(action: next) { Image(systemName: "forward.end").font(.title3).frame(width: 44, height: 44) }
                    .disabled(!hasNext)
                    .accessibilityLabel("Next")
            }
        }
        .tint(Palette.ink)
    }

    private var hasNext: Bool {
        if !playback.chapters.isEmpty { return (playback.chapterIndex ?? 0) < playback.chapters.count - 1 }
        return playback.trackIndex < playback.tracks.count - 1
    }

    private func previous() {
        if !playback.chapters.isEmpty {
            playback.playChapter(playback.chapters[max((playback.chapterIndex ?? 0) - 1, 0)])
        } else {
            playback.playTrack(playback.trackIndex - 1)
        }
    }

    private func next() {
        if !playback.chapters.isEmpty {
            playback.playChapter(playback.chapters[(playback.chapterIndex ?? 0) + 1])
        } else {
            playback.playTrack(playback.trackIndex + 1)
        }
    }
}

private enum PlayerSheet: String, Identifiable {
    case contents, speed, sleep
    var id: String { rawValue }
}

private struct PlayerOptionsSheet: View {
    let which: PlayerSheet
    @ObservedObject var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Float] = [0.8, 1, 1.2, 1.5, 1.75, 2, 2.5, 3]
    private let sleepMinutes = [0, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            List {
                switch which {
                case .speed:
                    ForEach(speeds, id: \.self) { value in
                        row(speedLabel(value), selected: value == playback.speed) { playback.setSpeed(value) }
                    }
                case .sleep:
                    ForEach(sleepMinutes, id: \.self) { minutes in
                        row(minutes == 0 ? "Off" : "\(minutes) minutes", selected: false) { playback.setSleepTimer(minutes: minutes) }
                    }
                case .contents:
                    if playback.chapters.isEmpty {
                        ForEach(Array(playback.tracks.enumerated()), id: \.element.id) { index, asset in
                            row(asset.filename.isEmpty ? "Track \(index + 1)" : asset.filename, selected: index == playback.trackIndex) {
                                playback.playTrack(index)
                            }
                        }
                    } else {
                        ForEach(playback.chapters) { chapter in
                            row(chapter.title ?? "Chapter \(chapter.id + 1)", selected: chapter.id == playback.chapterIndex) {
                                playback.playChapter(chapter)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch which {
        case .speed: return "Playback speed"
        case .sleep: return "Sleep timer"
        case .contents: return playback.chapters.isEmpty ? "Tracks" : "Chapters"
        }
    }

    private func row(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                Text(label).foregroundStyle(selected ? Palette.accent : Palette.ink)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
        }
    }
}

/// The always-available strip above the tab bar while audio is loaded.
struct MiniPlayer: View {
    @EnvironmentObject private var playback: PlaybackEngine
    let open: () -> Void

    var body: some View {
        if let publication = playback.publication {
            VStack(spacing: 0) {
                ProgressRule(fraction: playback.duration > 0 ? playback.position / playback.duration : 0)
                HStack(spacing: 12) {
                    BookCover(publication: publication).frame(width: 40)
                    VStack(alignment: .leading) {
                        Text(publication.title).font(Typeface.serifBold(15)).foregroundStyle(Palette.ink).lineLimit(1)
                        if let author = publication.author {
                            Text(author).font(.footnote).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(action: playback.togglePlay) {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                    }
                    .tint(Palette.ink)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Palette.surface)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(publication.title)")
        }
    }
}
