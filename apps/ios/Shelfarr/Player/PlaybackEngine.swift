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

/// Narration a reader follows (read-along): its files in order and where its places go.
/// The engine plays it with everything an audiobook gets (background audio, lock-screen
/// and headset controls, interruptions, the sleep timer, checkpoint cadence and the
/// resume rewind); only where checkpoints are written differs.
struct ReadAlongProgram {
    struct Track {
        /// The key `ListeningCheckpoints` knows this file by (`read-along:<audio index>`).
        let key: String
        /// A verified file on this device, or else
        let local: URL?
        /// an authenticated stream from the configured server.
        let remote: URL?
    }

    let title: String
    let author: String?
    let tracks: [Track]
    /// The narrated file after a given one, or nil after the last.
    let next: (Int) -> Int?
}

/// Receives what the engine does with read-along narration.
@MainActor
protocol ReadAlongListener: AnyObject {
    /// Listening actually happened at `seconds` of `track`, at `observedAt` (captured
    /// before anything waits). Opened places and the replayed pre-roll are never reported.
    /// `flush` for pause, seek, file change, errors, background and stop.
    func narration(heard track: Int, seconds: Double, observedAt: Int64, flush: Bool)
    /// Send pending places without treating unchanged paused audio as new listening.
    func narrationNeedsFlush()
    /// Let the reader consume a pending adopted place or a page read while paused.
    /// False means the loaded audio can resume normally.
    func narrationResumeRequested() -> Bool
    /// Pause was asked for; a Play the reader is still holding doesn't go ahead.
    func narrationPauseRequested()
    /// About ten times a second while narration is loaded.
    func narration(at track: Int, seconds: Double, playing: Bool)
    /// The last narrated file finished.
    func narrationEnded()
    func narrationFailed(_ problem: PlaybackProblem)
}

/// Plays a publication's ordered files with background audio and lock-screen controls.
/// It holds no UI, so the position keeps saving while the app is in the background.
///
/// Listening is checkpointed locally at most every four seconds while playing, and at
/// once on pause, stop, seeks, track changes, errors, switching books and backgrounding.
/// A genuine resume (a saved place opened, or paused playback restarted) replays five
/// seconds of the current track once; `ListeningCheckpoints` holds those rules.
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
    /// Every track plays from a verified download on this device.
    @Published private(set) var fromDevice = false
    /// A reader's narration is loaded instead of an audiobook.
    @Published private(set) var readAlongActive = false

    private let player = AVPlayer()
    private var api: ConsumerAPI?
    private var server: ServerAddress?
    private var sync: ProgressSync?
    private var loader: AuthenticatedAudioLoader?
    private var localFiles: [String: URL] = [:]
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var sleepTask: Task<Void, Never>?
    private var remoteConfigured = false
    private var checkpoints = ListeningCheckpoints()
    /// Local writes run in the order they were made, each with the time it happened.
    private var lastWrite: Task<Void, Never>?
    /// While a seek is under way the player may still report the old time; it is not playback.
    private var seeking = false
    private var seekGeneration = 0
    // Read-along narration, when a reader is following one.
    private var program: ReadAlongProgram?
    private weak var listener: ReadAlongListener?
    private var fineObserver: Any?

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
        start: SavedPosition?,
        localFiles: [String: URL]? = nil
    ) {
        // Switching books: the one playing until now keeps its last place.
        if self.publication != nil || program != nil { recordAndFlush() }
        endReadAlong()
        self.api = api
        self.server = server
        self.sync = sync
        self.publication = publication
        tracks = publication.audioAssets
        // Downloaded files are used only when every track is on the device.
        let ordered = publication.audioAssets
        let local = localFiles.flatMap { files in ordered.allSatisfy { files[$0.id] != nil } ? files : nil }
        self.localFiles = local ?? [:]
        fromDevice = local != nil
        problem = nil
        configureSession()
        configureRemoteCommands()
        let found = tracks.firstIndex { $0.id == start?.assetId }
        let saved = found == nil ? nil : start
        // Opening a saved place is a resume: it starts a little earlier, and the saved
        // place stays the checkpoint until playback passes it.
        let at = checkpoints.open(saved, firstTrack: tracks.first?.id ?? "")
        open(track: found ?? 0, at: at, play: true)
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    // MARK: Read-along

    /// Loads a reader's narration and plays it from `seconds` of `track`.
    ///
    /// - `.resume`: this device's saved place; it starts five seconds earlier and stays the
    ///   checkpoint until playback passes it.
    /// - `.adopted`: a place chosen from elsewhere, played from exactly there, not activity.
    /// - `.deliberate`: the listener chose it (Play from this page); saved at once.
    enum ReadAlongStart { case resume, adopted, deliberate }

    func loadReadAlong(_ program: ReadAlongProgram, listener: ReadAlongListener, server: ServerAddress, api: ConsumerAPI, track: Int, seconds: Double, start: ReadAlongStart) {
        if self.publication != nil || self.program != nil { recordAndFlush() }
        publication = nil
        tracks = []
        localFiles = [:]
        sync = nil
        self.api = api
        self.server = server
        self.program = program
        self.listener = listener
        readAlongActive = true
        fromDevice = program.tracks.allSatisfy { $0.local != nil }
        problem = nil
        configureSession()
        configureRemoteCommands()
        installFineObserver()
        let index = program.tracks.indices.contains(track) ? track : 0
        let saved = SavedPosition(assetId: program.tracks[index].key, positionSeconds: max(0, seconds))
        var at = checkpoints.open(saved, firstTrack: program.tracks[index].key)
        switch start {
        case .resume: break
        case .adopted:
            checkpoints.hold(saved)
            at = max(0, seconds)
        case .deliberate:
            checkpoints.movedDeliberately()
            at = max(0, seconds)
        }
        open(track: index, at: at, play: true)
        if start == .deliberate { recordAndFlush(narrationActivity: true) }
    }

    /// A deliberate move within the loaded narration (Play from this page, a chosen place):
    /// no rewind, saved at once.
    func readAlongMove(track: Int, seconds: Double, play: Bool) {
        guard let program, program.tracks.indices.contains(track) else { return }
        checkpoints.movedDeliberately()
        if track == trackIndex {
            position = max(0, seconds)
            exactSeek(to: position)
        } else {
            open(track: track, at: max(0, seconds), play: play)
        }
        if play { player.playImmediately(atRate: speed) }
        recordAndFlush(narrationActivity: true)
        updateNowPlaying()
    }

    /// Saves the narration's place and unloads it. The audio session stays as it was.
    func stopReadAlong() async {
        guard program != nil else { return }
        recordAndFlush()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        loader = nil
        endReadAlong()
        problem = nil
        setSleepTimer(minutes: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        await lastWrite?.value
    }

    private func endReadAlong() {
        if let fineObserver { player.removeTimeObserver(fineObserver) }
        fineObserver = nil
        program = nil
        listener = nil
        readAlongActive = false
    }

    private func installFineObserver() {
        guard fineObserver == nil else { return }
        // The highlight follows the words more closely than the half-second checkpoint tick.
        fineObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.program != nil, time.isNumeric, !self.seeking else { return }
                self.listener?.narration(at: self.trackIndex, seconds: time.seconds, playing: self.isPlaying)
            }
        }
    }

    /// True while `listener`'s narration is the one loaded.
    func isNarrating(for listener: ReadAlongListener) -> Bool {
        program != nil && self.listener === listener
    }

    private var trackCount: Int { program?.tracks.count ?? tracks.count }

    private func trackKey(_ index: Int) -> String {
        program?.tracks[index].key ?? tracks[index].id
    }

    private var isLoaded: Bool { publication != nil || program != nil }

    private func open(track index: Int, at seconds: Double, play: Bool) {
        guard (0 ..< trackCount).contains(index) else {
            failed(.connection)
            return
        }
        loader?.cancelAll()
        loader = nil
        let asset: AVURLAsset
        if let program {
            let track = program.tracks[index]
            if let file = track.local {
                asset = AVURLAsset(url: file)
            } else if let server, let api, let source = track.remote, server.contains(source) {
                // The bearer goes only to the configured server, in a header, never in the URL.
                let loader = AuthenticatedAudioLoader(source: source, api: api)
                self.loader = loader
                asset = AVURLAsset(url: loader.assetURL)
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            } else {
                failed(.connection)
                return
            }
        } else if let file = localFiles[tracks[index].id] {
            // A verified download plays straight from disk, with no credential involved.
            asset = AVURLAsset(url: file)
        } else {
            guard let server, let api, let source = server.resolve(tracks[index].contentUrl), server.contains(source) else {
                failed(.connection)
                return
            }
            let loader = AuthenticatedAudioLoader(source: source, api: api)
            self.loader = loader
            asset = AVURLAsset(url: loader.assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        }
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
        if seconds > 0 { exactSeek(to: seconds) }
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

    /// Seeks precisely, ignoring the player's reported time until it has arrived.
    private func exactSeek(to seconds: Double) {
        seeking = true
        seekGeneration += 1
        let generation = seekGeneration
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seeking = false
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard isLoaded, time.isNumeric, !seeking else { return }
        position = time.seconds
        let elapsed = ProcessInfo.processInfo.systemUptime
        if isPlaying, checkpoints.due(at: elapsed) {
            checkpoints.checkpointed(at: elapsed)
            record()
        }
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        let wasPlaying = isPlaying
        isPlaying = status == .playing
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        updateNowPlaying()
        if wasPlaying, status == .paused {
            // Paused by anyone (the app, lock screen, headset, sleep timer): the next play is a resume.
            checkpoints.paused()
            recordAndFlush(narrationActivity: true)
        }
        if program != nil, wasPlaying != isPlaying {
            listener?.narration(at: trackIndex, seconds: position, playing: isPlaying)
        }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard item === player.currentItem else { return }
        if let program {
            if let next = program.next(trackIndex) {
                checkpoints.carriedOn()
                recordAndFlush(narrationActivity: true)
                open(track: next, at: 0, play: true)
                record()
            } else {
                recordAndFlush(narrationActivity: true)
                listener?.narrationEnded()
            }
            return
        }
        if tracks.indices.contains(trackIndex + 1) {
            // A natural move into the next track: no rewind, and a checkpoint at once.
            checkpoints.carriedOn()
            open(track: trackIndex + 1, at: 0, play: true)
            record()
        } else {
            recordAndFlush()
        }
    }

    private func interrupted(type: UInt?, options: UInt) {
        guard type == AVAudioSession.InterruptionType.ended.rawValue else { return }
        if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
            // The system handing audio back is not the listener resuming.
            checkpoints.carriedOn()
            player.playImmediately(atRate: speed)
        }
    }

    private func failed(_ reason: PlaybackProblem) {
        problem = reason
        isBuffering = false
        recordAndFlush()
        if program != nil { listener?.narrationFailed(reason) }
    }

    func togglePlay() {
        if !isPlaying, program != nil, listener?.narrationResumeRequested() == true { return }
        if problem != nil {
            problem = nil
            let at = currentPosition().flatMap { checkpoints.resumed(at: $0) } ?? position
            open(track: trackIndex, at: at, play: true)
        } else if isPlaying {
            player.pause()
        } else {
            resume()
        }
    }

    /// Plays again after a pause, a little earlier than where it stopped, once.
    private func resume() {
        guard !isPlaying, isLoaded else { return }
        if program != nil, listener?.narrationResumeRequested() == true { return }
        configureSession()
        if let current = currentPosition(), let target = checkpoints.resumed(at: current) {
            position = target
            exactSeek(to: target)
            updateNowPlaying()
        }
        player.playImmediately(atRate: speed)
    }

    /// A deliberate move: no rewind, and a checkpoint at once.
    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        checkpoints.movedDeliberately()
        position = target
        exactSeek(to: target)
        record()
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// Plays after a pause (a resume, rewound once) or pauses; no-op when nothing is loaded.
    func play() {
        if !isPlaying { togglePlay() }
    }

    func pause() {
        if program != nil { listener?.narrationPauseRequested() }
        player.pause()
    }

    func playTrack(_ index: Int) {
        record()
        checkpoints.movedDeliberately()
        open(track: index, at: 0, play: true)
        record()
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

    /// Moves to a place chosen after a conflict. It is already saved, so arriving there is
    /// not new activity, and it plays from exactly there.
    func jump(to saved: SavedPosition) {
        guard let index = tracks.firstIndex(where: { $0.id == saved.assetId }) else { return }
        checkpoints.hold(saved)
        open(track: index, at: saved.positionSeconds ?? 0, play: isPlaying)
    }

    /// Saves the current place now, e.g. when the app goes to the background.
    func checkpointNow() {
        recordAndFlush()
    }

    /// Saves the final position, then stops and forgets the queue.
    func stop() async {
        if program != nil { return await stopReadAlong() }
        let observedAt = ActivityTime.now()
        let last = currentPosition().flatMap { checkpoints.isActivity($0) ? $0 : nil }
        let previousWrite = lastWrite
        let target = sync
        sync = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.cancelAll()
        loader = nil
        localFiles = [:]
        fromDevice = false
        publication = nil
        tracks = []
        chapters = []
        problem = nil
        setSleepTimer(minutes: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        await previousWrite?.value
        if let target {
            if let last { await target.update(last, observedAt: observedAt) }
            await target.flush()
        }
    }

    private func currentPosition() -> SavedPosition? {
        guard (0 ..< trackCount).contains(trackIndex), isLoaded else { return nil }
        return SavedPosition(assetId: trackKey(trackIndex), positionSeconds: position)
    }

    /// Takes the player's own time before a checkpoint. `position` follows the half-second
    /// observer, so a pause shortly after a track starts would otherwise save where the
    /// track started: on a hosted iPad, narration paused at 0.439 s into its second file
    /// saved 0 s, the same place as the file's start, so the pause wrote nothing.
    /// A seek in flight keeps its target.
    private func catchUpPosition() {
        guard isLoaded, !seeking, player.currentItem != nil else { return }
        let time = player.currentTime()
        if time.isNumeric { position = time.seconds }
    }

    /// Writes the current place locally, stamped now. The opened place and the replayed
    /// pre-roll before it are not new listening and are skipped.
    private func record() {
        let observedAt = ActivityTime.now()
        catchUpPosition()
        if program != nil {
            guard let saved = currentPosition(), checkpoints.isActivity(saved) else { return }
            listener?.narration(heard: trackIndex, seconds: saved.positionSeconds ?? 0, observedAt: observedAt, flush: false)
            return
        }
        guard let saved = currentPosition(), let sync, checkpoints.isActivity(saved) else { return }
        enqueue { await sync.update(saved, observedAt: observedAt) }
    }

    private func recordAndFlush(narrationActivity: Bool? = nil) {
        let observedAt = ActivityTime.now()
        catchUpPosition()
        if program != nil {
            // Lifecycle flushes while paused send the outbox only. Pause edges,
            // deliberate moves and natural file ends explicitly record their activity.
            guard narrationActivity ?? isPlaying,
                  let saved = currentPosition(), checkpoints.isActivity(saved) else {
                listener?.narrationNeedsFlush()
                return
            }
            listener?.narration(heard: trackIndex, seconds: saved.positionSeconds ?? 0, observedAt: observedAt, flush: true)
            return
        }
        guard let sync else { return }
        let saved = currentPosition().flatMap { checkpoints.isActivity($0) ? $0 : nil }
        enqueue {
            if let saved { await sync.update(saved, observedAt: observedAt) }
            await sync.requestFlush()
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await work()
        }
    }

    private func updateNowPlaying() {
        guard let title = publication?.title ?? program?.title else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
        ]
        if let author = publication?.author ?? program?.author { info[MPMediaItemPropertyArtist] = author }
        if program != nil { info[MPMediaItemPropertyAlbumTitle] = "Read along" }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if trackCount > 1 {
            info[MPNowPlayingInfoPropertyChapterNumber] = trackIndex + 1
            info[MPNowPlayingInfoPropertyChapterCount] = trackCount
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
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
