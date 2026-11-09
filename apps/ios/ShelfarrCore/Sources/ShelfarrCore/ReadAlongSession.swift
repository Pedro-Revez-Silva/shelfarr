import Foundation

/// What reading along decides, as plain state driven by the app's reader and player, so
/// every rule is tested without either:
///
/// - The page is quiet: nothing is highlighted until narration has played in this
///   session. Then the element of the cue being heard is highlighted, and nothing between
///   cues.
/// - While narration plays, the page follows only a cue whose element is out of view, and
///   only with Follow on. A page the reader turns meanwhile is browsing: nothing is written
///   and following pauses until "Back to the narration".
/// - While paused, a turned page is reading: an ordinary place is written by the reader,
///   and the next Play starts from the narration on that page.
/// - Restoring a place, following, layout and adopting a remote place are never activity.
///   The first Play after restoring a heard place is a genuine resume: five seconds
///   earlier, once (the player's `ListeningCheckpoints`).
/// - A later audiobook place is offered, never applied by itself.
public struct ReadAlongSession: Sendable {
    public let manifest: ReadAlongManifest

    /// How a restored place starts playing.
    public enum Arrival: Sendable, Equatable {
        /// This device's own saved place: a genuine resume, rewound once.
        case resume
        /// A place adopted from elsewhere (the audiobook's, another device's): from exactly there.
        case adopted
    }

    /// What Play does now.
    public enum Plan: Sendable, Equatable {
        /// Start from the narration on the page in view: ask the reader which cue that is,
        /// then `play(fromCue:)`.
        case fromPage
        /// Open the player at a restored place without it being activity.
        case open(ReadAlongManifest.Point, Arrival)
        /// The player has this session's narration loaded and paused: play on.
        case resume
    }

    public private(set) var follow: Bool
    /// Following paused because the reader moved away while narration played.
    public private(set) var suspended = false
    /// Narration has played in this session: the highlight and the small pill show.
    public private(set) var started = false
    public private(set) var playing = false
    /// The last narrated file ended.
    public private(set) var finished = false
    public private(set) var highlighted: Int?
    /// Where narration is: the loaded audio and offset, or the restored place before Play.
    public private(set) var heard: ReadAlongManifest.Point?
    /// A restored place not yet played.
    public private(set) var restored: ReadAlongManifest.Point?
    public private(set) var arrival = Arrival.resume
    /// A paused reading turn happened since narration last ran (or the saved place was read, not heard).
    public private(set) var readSinceHeard = true
    /// A later audiobook place, waiting for the reader's choice.
    public private(set) var offer: ReadAlongManifest.Point?
    /// The cue the page last followed to, so a cue is followed once.
    private var followed: Int?

    public init(manifest: ReadAlongManifest, follow: Bool = true) {
        self.manifest = manifest
        self.follow = follow
    }

    /// The reader opened at `locator` (a saved place, or another device's chosen one).
    /// Nothing plays and nothing is written; narration will start there.
    public mutating func restore(_ locator: JSONValue?, arrival: Arrival = .resume) {
        let point = manifest.point(from: locator)
        restored = point
        heard = point ?? heard
        self.arrival = arrival
        if arrival == .adopted { highlighted = nil; followed = nil }
        // A reading place (no exact offset) starts from the page, as after reading on.
        readSinceHeard = point == nil || !ReadAlongManifest.isHeard(locator)
    }

    /// Offers the paired audiobook's place when it was reached later than the ebook's and
    /// lands on another cue. Never applies it.
    public mutating func consider(audiobook point: ReadAlongManifest.Point?, observedAt audiobookTime: Int64?, ebookObservedAt ebookTime: Int64?, now: Int64 = ActivityTime.now()) {
        offer = nil
        guard let point, let audiobookTime, ActivityTime.isPlausible(audiobookTime, now: now) else { return }
        let ebook = ebookTime.flatMap { ActivityTime.isPlausible($0, now: now) ? $0 : nil }
        guard ebook.map({ audiobookTime > $0 }) ?? true else { return }
        guard point.cue != restored?.cue else { return }
        offer = point
    }

    /// The reader chose the offered place: narration will start exactly there. Showing it
    /// is not activity.
    public mutating func acceptOffer() -> ReadAlongManifest.Point? {
        guard let point = offer else { return nil }
        offer = nil
        restored = point
        heard = point
        arrival = .adopted
        highlighted = nil
        followed = nil
        readSinceHeard = false
        suspended = false
        return point
    }

    public mutating func dismissOffer() {
        offer = nil
    }

    /// What pressing Play does. `loaded` is whether the player holds this narration.
    public func plan(loaded: Bool) -> Plan {
        // A choice made while this program was paused supersedes the loaded audio too.
        // It remains pending until playback begins; merely showing its page is silent.
        if let restored, arrival == .adopted, !readSinceHeard { return .open(restored, .adopted) }
        if !loaded {
            if let restored, !readSinceHeard { return .open(restored, arrival) }
            return .fromPage
        }
        if readSinceHeard || finished { return .fromPage }
        return .resume
    }

    /// Narration starts (or resumes) playing.
    public mutating func began() {
        started = true
        playing = true
        finished = false
        readSinceHeard = false
        restored = nil
        suspended = false
    }

    public mutating func paused() {
        playing = false
    }

    /// The last narrated file ended: the next Play starts from the page.
    public mutating func ended() {
        playing = false
        finished = true
    }

    /// The highlight and, when due, the cue to bring into view. `follow` is nil when the
    /// page should stay where it is.
    public struct Tick: Sendable, Equatable {
        public let highlight: Int?
        public let changed: Bool
        public let follow: Int?
    }

    /// The player reported `ms` of `audio`.
    public mutating func tick(audio: Int, ms: Int64, playing: Bool) -> Tick {
        self.playing = playing
        if !playing, restored != nil, arrival == .adopted, !readSinceHeard {
            // The old loaded item keeps reporting its paused position until Play.
            // It must not pull the pending choice or its highlight back to that item.
            return Tick(highlight: highlighted, changed: false, follow: nil)
        }
        let cue = manifest.cue(at: ms, audio: audio)
        if let reached = manifest.cueReached(at: ms, audio: audio) {
            heard = ReadAlongManifest.Point(audio: audio, ms: ms, cue: reached, exact: true)
        }
        let shown = started ? cue : nil
        let changed = shown != highlighted
        highlighted = shown
        var target: Int?
        if playing, follow, !suspended, let cue, cue != followed {
            followed = cue
            target = cue
        }
        return Tick(highlight: shown, changed: changed, follow: target)
    }

    /// What a page the reader turned means.
    public enum Turn: Sendable, Equatable {
        /// Browsing while narration plays: write nothing.
        case browsing
        /// Reading while paused: the reader writes an ordinary place.
        case reading
    }

    public mutating func readerTurned() -> Turn {
        if playing {
            if follow { suspended = true }
            return .browsing
        }
        readSinceHeard = true
        return .reading
    }

    /// "Back to the narration": the cue to show, and following resumes.
    public mutating func returnToNarration() -> Int? {
        suspended = false
        followed = highlighted
        return highlighted ?? heard?.cue
    }

    /// Turns following on or off. Turning it on while playing brings the cue into view.
    public mutating func setFollow(_ on: Bool) -> Int? {
        follow = on
        guard on else { return nil }
        suspended = false
        guard playing else { return nil }
        followed = highlighted
        return highlighted
    }

    /// A checkpoint of narration actually heard landed: the place is the narration again.
    public mutating func heardCheckpoint(cueReached: Bool) {
        if cueReached { readSinceHeard = false }
    }
}

/// Writes the places heard while reading along.
///
/// The ebook place is the element of the cue reached at the heard offset, with
/// `locations.readAlong` naming the generation, audio and exact offset; nothing is
/// written before a track's first cue. For an imported alignment the paired audiobook's
/// own place (its asset and seconds) is written with the **same** `observed_at`. Both
/// are on this device's disk before either is scheduled to send, and each then follows
/// its publication's ordinary queue, retry and conflict rules.
public struct ReadAlongProgress: Sendable {
    public let manifest: ReadAlongManifest
    public let ebook: ProgressSync
    /// The paired audiobook's sync, for an imported alignment.
    public let audiobook: ProgressSync?

    public init(manifest: ReadAlongManifest, ebook: ProgressSync, audiobook: ProgressSync?) {
        self.manifest = manifest
        self.ebook = ebook
        self.audiobook = manifest.source == .imported ? audiobook : nil
    }

    /// Sends already recorded places without observing the paused audio again. A page
    /// read after pausing, or a place adopted from elsewhere, must keep its own time.
    public func flush() async {
        await ebook.requestFlush()
        await audiobook?.requestFlush()
    }

    /// What one checkpoint wrote.
    public struct Written: Sendable, Equatable {
        public let ebook: SavedPosition?
        public let audiobook: SavedPosition?
        public let observedAt: Int64
    }

    /// Records narration heard at `ms` of `audio` at `observedAt`, the time captured when
    /// it was heard. `flush` sends at once (pause, seek, file change, background, close);
    /// otherwise the ordinary debounce applies.
    @discardableResult
    public func checkpoint(audio: Int, ms: Int64, observedAt: Int64, totalProgression: (String) -> Double? = { _ in nil }, flush: Bool) async -> Written {
        var ebookPlace: SavedPosition?
        if let cue = manifest.cueReached(at: ms, audio: audio),
           let locator = manifest.locator(heardAt: ms, audio: audio, totalProgression: totalProgression(manifest.href(ofCue: cue))) {
            ebookPlace = SavedPosition(assetId: manifest.ebookAssetId, locator: locator)
        }
        var audiobookPlace: SavedPosition?
        if audiobook != nil, manifest.audio.indices.contains(audio), let assetId = manifest.audio[audio].assetId {
            audiobookPlace = SavedPosition(assetId: assetId, positionSeconds: Double(max(0, ms)) / 1000)
        }
        // One stamp for both. Each book's own observations stay in order (a clock that
        // stepped back is moved past the previous one), and both get the same time.
        var stamp = observedAt
        if ebookPlace != nil { stamp = max(stamp, ActivityTime.next(observedAt, after: await ebook.snapshot().observedAt)) }
        if audiobookPlace != nil, let audiobook { stamp = max(stamp, ActivityTime.next(observedAt, after: await audiobook.snapshot().observedAt)) }
        // Both on disk first.
        var ebookNew = false
        if let ebookPlace { ebookNew = await ebook.record(ebookPlace, observedAt: stamp) }
        var audiobookNew = false
        if let audiobookPlace, let audiobook { audiobookNew = await audiobook.record(audiobookPlace, observedAt: stamp) }
        // Then sent, each by its own publication's rules.
        if flush {
            if ebookPlace != nil { await ebook.requestFlush() }
            if audiobookPlace != nil { await audiobook?.requestFlush() }
        } else {
            if ebookNew { await ebook.sendSoon() }
            if audiobookNew { await audiobook?.sendSoon() }
        }
        return Written(ebook: ebookPlace, audiobook: audiobookPlace, observedAt: stamp)
    }
}
