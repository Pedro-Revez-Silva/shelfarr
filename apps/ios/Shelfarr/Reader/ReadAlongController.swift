import Foundation
import ShelfarrCore
import UIKit

/// Reads along in one open EPUB: plays its narration through the app's one playback
/// engine, highlights the element being heard with a Readium decoration, follows pages
/// only for cues out of view, and writes the places heard. The rules are
/// `ReadAlongSession` and `ReadAlongProgress` in ShelfarrCore; this drives them.
@MainActor
final class ReadAlongController: ObservableObject, ReadAlongListener {
    @Published private(set) var playing = false
    /// Narration has played in this session: the small Pause/Play pill shows.
    @Published private(set) var started = false
    @Published private(set) var follow: Bool
    /// The reader moved away while narration played: "Back to the narration" shows.
    @Published private(set) var suspended = false
    @Published private(set) var speed: Float = 1
    /// "Your audiobook is further along", while it waits for a choice.
    @Published private(set) var offer: String?
    @Published private(set) var problem: String?
    /// The coverage line for the reading controls.
    let note: String
    let fromDevice: Bool
    /// Simulator smoke only: the session's state in fixture terms (see `RestoreTrace`).
    @Published private(set) var trace: String?

    let manifest: ReadAlongManifest
    private var session: ReadAlongSession
    private let progress: ReadAlongProgress
    private let program: ReadAlongProgram
    private let engine: PlaybackEngine
    private weak var book: ReadiumBook?
    private let server: ServerAddress
    private let api: ConsumerAPI
    private var tint: UIColor
    private let traces: Bool
    /// Writes run in the order they were heard.
    private var lastWrite: Task<Void, Never>?
    /// A page move this controller made; the reports it causes are display only.
    private var followMoving = false
    /// Where the last follow went, until its report arrives (or a few seconds pass).
    private var followTarget: (href: String, until: Date)?
    private var heardCount = 0
    /// The last listening checkpoint recorded, as "audio:ms" (Debug UI-test trace only).
    private var lastSaved = "-"
    private var followCount = 0
    /// Simulator smoke only: every highlight change since narration last began, as
    /// `cue/follows` (`p1/0,-/0,p2/0`). A fixture cue lasts two seconds, about as long as
    /// one trace query takes on a hosted simulator, so the order heard is recorded here
    /// rather than sampled. Bounded; empty unless `traces`.
    private var shownCues: [String] = []
    private static let shownLimit = 64

    static let followKey = "readAlong.follow"

    init(narration: ReadAlongService.Narration, title: String, author: String?, book: ReadiumBook, engine: PlaybackEngine,
         ebook: ProgressSync, audiobook: ProgressSync?, server: ServerAddress, api: ConsumerAPI, theme: ReaderTheme) {
        manifest = narration.manifest
        let stored = UserDefaults.standard.object(forKey: Self.followKey) as? Bool
        follow = stored ?? true
        session = ReadAlongSession(manifest: narration.manifest, follow: stored ?? true)
        progress = ReadAlongProgress(manifest: narration.manifest, ebook: ebook, audiobook: audiobook)
        let manifest = narration.manifest
        program = ReadAlongProgram(title: title, author: author, tracks: narration.tracks, next: { manifest.nextAudio(after: $0) })
        self.engine = engine
        self.book = book
        self.server = server
        self.api = api
        tint = Self.tint(theme)
        fromDevice = narration.fromDevice
        let source = narration.manifest.source == .imported
            ? "Narrated by “\(narration.audiobookTitle ?? "the audiobook")”, aligned to this edition."
            : "Narration from this book."
        note = [source, narration.manifest.coverage?.description ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        #if DEBUG
        traces = ProcessInfo.processInfo.arguments.contains(UITestFixture.argument)
        #else
        traces = false
        #endif
        updateTrace("ready")
    }

    private static func tint(_ theme: ReaderTheme) -> UIColor {
        switch theme {
        case .paper: return UIColor(hex: 0xA33A22)
        case .sepia: return UIColor(hex: 0x96351F)
        case .night: return UIColor(hex: 0xEE9270)
        }
    }

    func applyTheme(_ theme: ReaderTheme) {
        tint = Self.tint(theme)
        redrawHighlight()
    }

    private var loaded: Bool { engine.isNarrating(for: self) }

    // MARK: Opening

    /// The reader opened at `locator`. Narration will start there; nothing plays or is written.
    func restored(_ locator: JSONValue?, arrival: ReadAlongSession.Arrival = .resume) {
        session.restore(locator, arrival: arrival)
        updateTrace("restored")
    }

    /// Offers the paired audiobook's place when it was heard later than the ebook's.
    func consider(audiobook progress: ReadingProgress?, local: LocalProgress?, ebookObservedAt: Int64?) {
        let localTime = local?.observedAt
        let serverTime = progress?.observedAtMillis
        let useLocal = local?.position?.positionSeconds != nil && (serverTime == nil || (localTime ?? .min) >= serverTime!)
        let assetId = useLocal ? local?.position?.assetId : progress?.assetId
        let seconds = useLocal ? local?.position?.positionSeconds : progress?.positionSeconds
        let time = useLocal ? localTime : serverTime
        let point = assetId.flatMap { id in seconds.flatMap { manifest.point(audiobookAsset: id, seconds: $0) } }
        session.consider(audiobook: point, observedAt: time, ebookObservedAt: ebookObservedAt)
        offer = session.offer == nil ? nil : "Your audiobook is further along than this page."
        updateTrace("offer")
    }

    /// Shows the audiobook's place and makes it where narration starts. Not activity.
    func acceptOffer() {
        offer = nil
        guard let point = session.acceptOffer() else { return }
        Task { await show(point.cue, force: true) }
        updateTrace("offer-accepted")
    }

    func dismissOffer() {
        session.dismissOffer()
        offer = nil
    }

    // MARK: Controls

    func togglePlay() {
        if loaded, session.playing {
            engine.pause()
            return
        }
        problem = nil
        start(session.plan(loaded: loaded))
    }

    /// Media controls use the same pending choice as the reader's Play button.
    /// Returning false leaves a plain resume (including its rewind) to the engine.
    func narrationResumeRequested() -> Bool {
        let plan = session.plan(loaded: loaded)
        guard plan != .resume else { return false }
        problem = nil
        start(plan)
        return true
    }

    private func start(_ plan: ReadAlongSession.Plan) {
        switch plan {
        case .resume:
            engine.play()
        case let .open(point, arrival):
            engine.loadReadAlong(program, listener: self, server: server, api: api, track: point.audio, seconds: point.seconds,
                                 start: arrival == .resume ? .resume : .adopted)
            engine.setSpeed(speed)
            began()
        case .fromPage:
            Task { await playFromPage() }
        }
    }

    /// Plays from the narration on the page in view: its first cue starting there, else
    /// the cue it continues, else the next narrated document's first cue.
    private func playFromPage() async {
        let cue = await visibleCue() ?? 0
        let point = ReadAlongManifest.Point(audio: manifest.audio(ofCue: cue), ms: manifest.beginMs(ofCue: cue), cue: cue, exact: false)
        if loaded {
            engine.readAlongMove(track: point.audio, seconds: point.seconds, play: true)
        } else {
            engine.loadReadAlong(program, listener: self, server: server, api: api, track: point.audio, seconds: point.seconds, start: .deliberate)
            engine.setSpeed(speed)
        }
        began()
        await show(cue, force: false)
    }

    private func began() {
        session.began()
        shownCues = []
        started = true
        suspended = false
        playing = true
        updateTrace("play")
    }

    private func visibleCue() async -> Int? {
        guard let book, let href = book.currentHref else { return nil }
        let cues = manifest.cues(inText: href)
        if let fragment = await book.firstVisibleElement(href: href, fragments: cues.map { manifest.fragments[$0] }),
           let cue = manifest.cue(href: href, fragment: fragment) {
            return cue
        }
        return manifest.firstCue(after: href, spine: book.spine)
    }

    func skip(by seconds: Double) {
        guard loaded else { return }
        engine.skip(by: seconds)
    }

    func setSpeed(_ value: Float) {
        speed = value
        if loaded { engine.setSpeed(value) }
    }

    func setFollow(_ on: Bool) {
        follow = on
        UserDefaults.standard.set(on, forKey: Self.followKey)
        let cue = session.setFollow(on)
        suspended = session.suspended
        if let cue { Task { await show(cue, force: true) } }
        updateTrace("follow")
    }

    /// "Back to the narration": shows the cue heard and resumes following.
    func returnToNarration() {
        let cue = session.returnToNarration()
        suspended = false
        if let cue { Task { await show(cue, force: true) } }
        updateTrace("return")
    }

    // MARK: The reader's reports

    /// A page report the reader would save, for a page in `href`. False when it must not
    /// be written: the page this controller moved to, or browsing while narration plays.
    func readerMoved(href: String?) -> Bool {
        if followMoving { return false }
        if let target = followTarget {
            followTarget = nil
            if Date() < target.until, let href, ReadingRestoration.same(href, target.href) {
                // The report of the follow's own move: display only.
                return false
            }
        }
        let turn = session.readerTurned()
        suspended = session.suspended
        updateTrace(turn == .browsing ? "browse" : "read")
        return turn == .reading
    }

    /// While narration plays, reports are never reading, whatever caused them.
    var suppressesReading: Bool { session.playing || followMoving }

    /// Paused reading shares the narration write queue: a pause checkpoint already
    /// queued before this turn must reach disk first, even if its store is still busy.
    func recordReading(_ position: SavedPosition, observedAt: Int64) {
        let ebook = progress.ebook
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await ebook.update(position, observedAt: observedAt)
        }
    }

    /// Explicit conflict choices settle earlier observations before replacing them.
    func finishWrites() async {
        await lastWrite?.value
    }

    // MARK: ReadAlongListener

    func narration(at track: Int, seconds: Double, playing: Bool) {
        let tick = session.tick(audio: track, ms: Int64((seconds * 1000).rounded()), playing: playing)
        if self.playing != playing { self.playing = playing }
        if tick.changed {
            if traces {
                let shown = tick.highlight.map { manifest.fragments[$0] } ?? "-"
                shownCues.append("\(shown)/\(followCount)")
                if shownCues.count > Self.shownLimit { shownCues.removeFirst() }
            }
            redrawHighlight()
            updateTrace("cue")
        } else if traces {
            updateTrace("tick")
        }
        if let cue = tick.follow { Task { await show(cue, force: false) } }
    }

    func narration(heard track: Int, seconds: Double, observedAt: Int64, flush: Bool) {
        let ms = Int64((seconds * 1000).rounded())
        let reached = manifest.cueReached(at: ms, audio: track)
        let start = reached.flatMap { book?.startProgression(ofHref: manifest.href(ofCue: $0)) }
        let progress = self.progress
        session.heardCheckpoint(cueReached: reached != nil)
        heardCount += 1
        lastSaved = "\(track):\(ms)"
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await progress.checkpoint(audio: track, ms: ms, observedAt: observedAt, totalProgression: { _ in start }, flush: flush)
        }
        updateTrace("heard")
    }

    func narrationNeedsFlush() {
        let progress = self.progress
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await progress.flush()
        }
    }

    func narrationEnded() {
        session.ended()
        playing = false
        updateTrace("ended")
    }

    func narrationFailed(_ problem: PlaybackProblem) {
        self.problem = problem.message
        playing = false
        session.paused()
    }

    // MARK: Page

    private func redrawHighlight() {
        guard let book else { return }
        if let cue = session.highlighted {
            book.highlight(href: manifest.href(ofCue: cue), fragment: manifest.fragments[cue], tint: tint)
        } else {
            book.highlight(href: nil, fragment: nil, tint: tint)
        }
    }

    /// Brings `cue`'s element into view when it isn't. With `force` false this is
    /// following and only happens while it should.
    private func show(_ cue: Int, force: Bool) async {
        guard let book, !followMoving else { return }
        if !force, !(session.playing && session.follow && !session.suspended) { return }
        let href = manifest.href(ofCue: cue), fragment = manifest.fragments[cue]
        if await book.isElementVisible(href: href, fragment: fragment) == true { return }
        followMoving = true
        let moved = await book.go(toElement: fragment, href: href, animated: !UIAccessibility.isReduceMotionEnabled)
        followTarget = moved ? (href, Date().addingTimeInterval(5)) : nil
        followMoving = false
        followCount += 1
        redrawHighlight()
        updateTrace("followed")
    }

    // MARK: Closing

    /// Saves the place heard at once and unloads the narration (leaving, sign-out).
    func close() async {
        if loaded { await engine.stopReadAlong() }
        await lastWrite?.value
        await progress.ebook.requestFlush()
        await progress.audiobook?.requestFlush()
        book?.highlight(href: nil, fragment: nil, tint: tint)
    }

    /// Lifecycle checkpoints (background, the reader hidden): the engine saves the place
    /// heard and the writes are sent.
    func checkpointNow() {
        guard loaded else { return }
        engine.checkpointNow()
    }

    private func updateTrace(_ event: String) {
        guard traces else { return }
        let cue = session.highlighted.map { manifest.fragments[$0] } ?? "-"
        let heard = session.heard.map { "\($0.audio):\($0.ms)" } ?? "-"
        let shown = shownCues.isEmpty ? "-" : shownCues.joined(separator: ",")
        var line = "read-along event=\(event) cue=\(cue) playing=\(session.playing ? 1 : 0) follow=\(session.follow ? 1 : 0) "
            + "suspended=\(session.suspended ? 1 : 0) started=\(session.started ? 1 : 0) heard=\(heard) offer=\(session.offer == nil ? 0 : 1) "
            + "source=\(manifest.source.rawValue) audio=\(fromDevice ? "device" : "stream") generation=\(manifest.generation.prefix(8)) checkpoints=\(heardCount) saved=\(lastSaved) follows=\(followCount)"
        line += " shown=\(shown)"
        trace = line
    }
}
