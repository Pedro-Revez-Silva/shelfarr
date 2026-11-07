import Combine
import AVFoundation
import Foundation
import MediaPlayer
import ShelfarrCore

struct AudioChapter: Identifiable, Equatable {
    let id: Int
    let title: String?
    let start: Double
}

enum PlaybackProblem {
    case connection, unsupported

    var message: String {
        switch self {
        case .connection: return "Lost the connection to your server. Press play to try again."
        case .unsupported: return "This device can't play this audio file."
        }
    }
}

/// Plays a publication's ordered files with background audio and lock-screen controls.
/// It holds no UI, so the position keeps saving while the app is in the background.
@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var publication: ShelfarrCore.Publication?
    @Published private(set) var tracks: [ShelfarrCore.Asset] = []
    @Published private(set) var trackIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var speed: Float = 1
    @Published private(set) var chapters: [AudioChapter] = []
    @Published private(set) var problem: PlaybackProblem?
    @Published private(set) var sleepEndsAt: Date?

    private let player = AVPlayer()
    private var api: ConsumerAPI?
    private var server: ServerAddress?
    private var sync: ProgressSync?
    private var loader: AuthenticatedAudioLoader?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var sleepTask: Task<Void, Never>?
    private var ticks = 0
    private var remoteConfigured = false

    static let skipBack = 15.0
    static let skipForward = 30.0

    var chapterIndex: Int? { chapters.lastIndex { $0.start <= position } }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observations.append(player.observe(\.timeControlStatus) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.statusChanged(status) }
        })
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor in self?.itemEnded(item) }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.failed(.connection) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.interrupted(type: type, options: raw) }
        })
    }

    /// Queues a publication and starts it from `start`, or the beginning.
    func load(
        _ publication: ShelfarrCore.Publication,
        server: ServerAddress,
        api: ConsumerAPI,
        sync: ProgressSync,
        start: SavedPosition?
    ) {
        self.api = api
        self.server = server
        self.sync = sync
        self.publication = publication
        tracks = publication.audioAssets
        problem = nil
        configureSession()
        configureRemoteCommands()
        let index = tracks.firstIndex { $0.id == start?.assetId } ?? 0
        open(track: index, at: start?.positionSeconds ?? 0, play: true)
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func open(track index: Int, at seconds: Double, play: Bool) {
        guard tracks.indices.contains(index), let server, let api,
              let source = server.resolve(tracks[index].contentUrl), server.contains(source)
        else {
            failed(.connection)
            return
        }
        loader?.cancelAll()
        let loader = AuthenticatedAudioLoader(source: source, api: api)
        self.loader = loader

        let asset = AVURLAsset(url: loader.assetURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        observations.append(item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in if failed { self?.failed(.unsupported) } }
        })

        trackIndex = index
        position = seconds
        duration = 0
        chapters = []
        player.replaceCurrentItem(with: item)
        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if play {
            player.playImmediately(atRate: speed)
        }
        Task { await loadDetails(asset, track: index) }
        updateNowPlaying()
    }

    private func loadDetails(_ asset: AVURLAsset, track: Int) async {
        if let length = try? await asset.load(.duration), trackIndex == track, length.isNumeric {
            duration = length.seconds
            updateNowPlaying()
        }
        let groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        var found: [AudioChapter] = []
        for (index, group) in groups.enumerated() {
            let titles = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
            let title = try? await titles.first?.load(.stringValue)
            found.append(AudioChapter(id: index, title: title ?? nil, start: group.timeRange.start.seconds))
        }
        if trackIndex == track { chapters = found }
    }

    private func tick(_ time: CMTime) {
        guard publication != nil, time.isNumeric else { return }
        position = time.seconds
        ticks += 1
        if isPlaying, ticks % 10 == 0 { record() }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        let wasPlaying = isPlaying
        isPlaying = status == .playing
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        updateNowPlaying()
        if wasPlaying, status == .paused { recordAndFlush() }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard item === player.currentItem else { return }
        if tracks.indices.contains(trackIndex + 1) {
            open(track: trackIndex + 1, at: 0, play: true)
        } else {
            recordAndFlush()
        }
    }

    private func interrupted(type: UInt?, options: UInt) {
        guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
        if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            player.playImmediately(atRate: speed)
        }
    }

    private func failed(_ reason: PlaybackProblem) {
        problem = reason
        isBuffering = false
        recordAndFlush()
    }

    func togglePlay() {
        if problem != nil {
            problem = nil
            open(track: trackIndex, at: position, play: true)
        } else if isPlaying {
            player.pause()
        } else {
            configureSession()
            player.playImmediately(atRate: speed)
        }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        record()
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func playTrack(_ index: Int) {
        record()
        open(track: index, at: 0, play: true)
    }

    func playChapter(_ chapter: AudioChapter) {
        seek(to: chapter.start)
        player.playImmediately(atRate: speed)
    }

    func setSpeed(_ value: Float) {
        speed = value
        if isPlaying { player.rate = value }
        updateNowPlaying()
    }

    /// Pauses after `minutes`; nil or zero cancels.
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes, minutes > 0 else {
            sleepEndsAt = nil
            return
        }
        sleepEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            if Task.isCancelled { return }
            self?.player.pause()
            self?.sleepEndsAt = nil
        }
    }

    /// Moves to a place chosen after a conflict.
    func jump(to saved: SavedPosition) {
        guard let index = tracks.firstIndex(where: { $0.id == saved.assetId }) else { return }
        open(track: index, at: saved.positionSeconds ?? 0, play: isPlaying)
    }

    /// Saves the final position, then stops and forgets the queue.
    func stop() async {
        let last = currentPosition()
        let target = sync
        sync = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        loader = nil
        publication = nil
        tracks = []
        chapters = []
        problem = nil
        setSleepTimer(minutes: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let target {
            if let last { await target.update(last) }
            await target.flush()
        }
    }

    private func currentPosition() -> SavedPosition? {
        guard tracks.indices.contains(trackIndex), publication != nil else { return nil }
        return SavedPosition(assetId: tracks[trackIndex].id, positionSeconds: position)
    }

    private func record() {
        guard let saved = currentPosition(), let sync else { return }
        Task { await sync.update(saved) }
    }

    private func recordAndFlush() {
        guard let sync else { return }
        let saved = currentPosition()
        Task {
            if let saved { await sync.update(saved) }
            await sync.flush()
        }
    }

    private func updateNowPlaying() {
        guard let publication else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: publication.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if let author = publication.author { info[MPMediaItemPropertyArtist] = author }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if tracks.count > 1 {
            info[MPNowPlayingInfoPropertyChapterNumber] = trackIndex + 1
            info[MPNowPlayingInfoPropertyChapterCount] = tracks.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            self?.player.playImmediately(atRate: self?.speed ?? 1)
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        commands.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -Self.skipBack)
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        commands.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: Self.skipForward)
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }
}
