import Foundation

/// Optional reader features this app understands (`docs/read-along.md`).
///
/// Features are not formats: they add fields installed clients have never seen, so a
/// server sends them only to a client that declares them. The app declares
/// `read-along` on publication details only; listings and Continue never carry it.
public enum ReaderFeatures {
    public static let header = "X-Shelfarr-Reader-Features"
    public static let declared = "read-along"
}

/// Where a book's read-along alignment comes from. Nothing else is ever used: no
/// percentages, durations, text length or speech synthesis.
public enum ReadAlongSource: String, Codable, Sendable {
    /// EPUB 3 Media Overlays inside the book: its own SMIL and audio.
    case mediaOverlay = "media_overlay"
    /// An alignment imported for this EPUB and a separate audiobook.
    case imported
}

public enum ReadAlongStatus: String, Codable, Sendable {
    case available, unaligned, stale, invalid
}

/// An EPUB asset's `read_along` summary, from details requested with the feature.
///
/// Decoded leniently: an absent or malformed summary is nil and the EPUB reads exactly
/// as before. An `available` summary is only usable when it carries a generation and a
/// manifest URL.
public struct ReadAlongSummary: Codable, Equatable, Sendable {
    public struct Coverage: Codable, Equatable, Sendable {
        public let complete: Bool
        public let textSections: Int?
        public let alignedSections: Int?
        public let cues: Int?
        public let audioMs: Int64?

        public init(complete: Bool, textSections: Int? = nil, alignedSections: Int? = nil, cues: Int? = nil, audioMs: Int64? = nil) {
            self.complete = complete
            self.textSections = textSections
            self.alignedSections = alignedSections
            self.cues = cues
            self.audioMs = audioMs
        }

        enum CodingKeys: String, CodingKey {
            case complete, cues
            case textSections = "text_sections"
            case alignedSections = "aligned_sections"
            case audioMs = "audio_ms"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            complete = (try? container.decodeIfPresent(Bool.self, forKey: .complete)) ?? false
            textSections = (try? container.decodeIfPresent(Int.self, forKey: .textSections)) ?? nil
            alignedSections = (try? container.decodeIfPresent(Int.self, forKey: .alignedSections)) ?? nil
            cues = (try? container.decodeIfPresent(Int.self, forKey: .cues)) ?? nil
            audioMs = (try? container.decodeIfPresent(Int64.self, forKey: .audioMs)) ?? nil
        }

        /// A short line for the reading controls, or empty when the counts are unknown.
        public var description: String {
            guard let total = textSections, let aligned = alignedSections, total > 0 else { return "" }
            if complete || aligned >= total {
                return total == 1 ? "Narration covers the whole text." : "Narration covers all \(total) sections."
            }
            return "Narration covers \(aligned) of \(total) sections; the others show text only."
        }
    }

    public struct Audiobook: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
    }

    public let status: ReadAlongStatus
    public let source: ReadAlongSource?
    public let generation: String?
    public let manifestUrl: String?
    public let coverage: Coverage?
    public let textBytes: Int64?
    public let audioBytes: Int64?
    public let reason: String?
    /// The related audiobook: the aligned one, or for `unaligned` one that exists but isn't aligned.
    public let audiobook: Audiobook?

    public init(status: ReadAlongStatus, source: ReadAlongSource? = nil, generation: String? = nil, manifestUrl: String? = nil,
                coverage: Coverage? = nil, textBytes: Int64? = nil, audioBytes: Int64? = nil, reason: String? = nil, audiobook: Audiobook? = nil) {
        self.status = status
        self.source = source
        self.generation = generation
        self.manifestUrl = manifestUrl
        self.coverage = coverage
        self.textBytes = textBytes
        self.audioBytes = audioBytes
        self.reason = reason
        self.audiobook = audiobook
    }

    enum CodingKeys: String, CodingKey {
        case status, source, generation, coverage, reason, audiobook
        case manifestUrl = "manifest_url"
        case textBytes = "text_bytes"
        case audioBytes = "audio_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(ReadAlongStatus.self, forKey: .status)
        source = (try? container.decodeIfPresent(ReadAlongSource.self, forKey: .source)) ?? nil
        generation = ((try? container.decodeIfPresent(String.self, forKey: .generation)) ?? nil).flatMap { ReadAlongManifest.isGeneration($0) ? $0 : nil }
        manifestUrl = (try? container.decodeIfPresent(String.self, forKey: .manifestUrl)) ?? nil
        coverage = (try? container.decodeIfPresent(Coverage.self, forKey: .coverage)) ?? nil
        textBytes = (try? container.decodeIfPresent(Int64.self, forKey: .textBytes)) ?? nil
        audioBytes = (try? container.decodeIfPresent(Int64.self, forKey: .audioBytes)) ?? nil
        reason = ((try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil).map { String($0.prefix(500)) }
        audiobook = (try? container.decodeIfPresent(Audiobook.self, forKey: .audiobook)) ?? nil
    }

    /// Narration can be offered: a validated manifest exists for a known generation.
    public var isAvailable: Bool {
        status == .available && source != nil && generation != nil && !(manifestUrl ?? "").isEmpty
    }
}

/// Why a manifest can't be used. The EPUB still reads exactly as without read-along.
public enum ReadAlongError: Error, Equatable, Sendable {
    /// The server has no alignment for this edition (404 `read_along_unaligned`).
    case unaligned(String?)
    /// An imported alignment was made for an earlier file generation (409).
    case stale(String?)
    /// The server refused its own alignment data (422).
    case invalid(String?)
    /// This EPUB generation no longer exists (410), or the manifest is for another
    /// generation or edition than the details named.
    case changed
    /// The manifest isn't one this app can use: an unknown version or layout, unsafe
    /// references, URLs outside the server, overlapping or out-of-range cues, too large.
    case unusable(String)
}

/// A read-along manifest (version 1) for one exact EPUB asset generation, checked and
/// indexed before anything uses it.
///
/// Cues are `[text index, element ID, audio index, begin ms, end ms or null]` in reading
/// order (spine order, then document order), so text indices never decrease. Within one audio resource cues sorted by start may not overlap (5 ms tolerance
/// for rounded clip values), and an open-ended cue must be its audio's last. Nothing is
/// ever interpolated: between cues nothing is being read, and a place is only derived
/// from a cue that was actually reached.
public struct ReadAlongManifest: Sendable, Equatable {
    public static let version = 1
    public static let cueFields = ["text", "fragment", "audio", "begin_ms", "end_ms"]
    public static let maxCues = 200_000
    /// Audio indices are 0–1999, as `locations.readAlong.audio` allows.
    public static let maxAudio = 2_000
    public static let maxTexts = 10_000
    public static let maxMs: Int64 = 48 * 3_600_000
    public static let overlapToleranceMs: Int64 = 5
    /// A manifest with the most cues and long IDs stays well inside this.
    public static let maxBytes: Int64 = 48 << 20
    static let maxFragmentBytes = 256
    static let maxHrefBytes = 2048

    public struct Audio: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// An entry inside the same EPUB, by archive path.
            case epubResource(href: String)
            /// A file of the paired audiobook, downloaded with the existing transfer path.
            case publicationAsset(publicationId: String, assetId: String, filename: String, contentUrl: String?)
        }

        public let kind: Kind
        public let mediaType: String
        public let sizeBytes: Int64
        /// The bearer route for this audio, inside the configured server.
        public let url: String

        public var assetId: String? {
            if case let .publicationAsset(_, assetId, _, _) = kind { return assetId }
            return nil
        }

        public var href: String? {
            if case let .epubResource(href) = kind { return href }
            return nil
        }
    }

    public let generation: String
    public let source: ReadAlongSource
    public let publicationId: String?
    public let ebookAssetId: String
    /// Archive paths of the text documents cues name.
    public let texts: [String]
    public let textMediaTypes: [String]
    public let audio: [Audio]
    public let coverage: ReadAlongSummary.Coverage?

    // Cues, by index in reading order.
    let cueText: [Int32]
    let cueAudio: [Int32]
    let cueBegin: [Int64]
    /// `Int64.max` for a clip that runs to the end of its file.
    let cueEnd: [Int64]
    public let fragments: [String]
    /// Per audio, cue indices sorted by start.
    let byAudio: [[Int32]]
    /// `href#fragment` to the first cue naming that element.
    let byFragment: [String: Int32]
    /// Per text document, its cue indices in reading order.
    let byText: [[Int32]]

    public var count: Int { cueText.count }

    /// The publication's paired audiobook, for an imported alignment.
    public var audiobookPublicationId: String? {
        for track in audio {
            if case let .publicationAsset(publicationId, _, _, _) = track.kind { return publicationId }
        }
        return nil
    }

    public static func isGeneration(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }
    }

    // MARK: Parsing

    private struct Raw: Decodable {
        struct Text: Decodable {
            let href: String
            let mediaType: String?
            enum CodingKeys: String, CodingKey {
                case href
                case mediaType = "media_type"
            }
        }

        struct Track: Decodable {
            let kind: String
            let href: String?
            let publicationId: String?
            let assetId: String?
            let filename: String?
            let mediaType: String
            let sizeBytes: Int64
            let url: String
            let contentUrl: String?
            enum CodingKeys: String, CodingKey {
                case kind, href, filename, url
                case publicationId = "publication_id"
                case assetId = "asset_id"
                case mediaType = "media_type"
                case sizeBytes = "size_bytes"
                case contentUrl = "content_url"
            }
        }

        struct Cue: Decodable {
            let text: Int
            let fragment: String
            let audio: Int
            let begin: Int64
            let end: Int64?

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                text = try container.decode(Int.self)
                fragment = try container.decode(String.self)
                audio = try container.decode(Int.self)
                begin = try container.decode(Int64.self)
                end = try container.decodeNil() ? nil : try container.decode(Int64.self)
                guard container.isAtEnd else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "extra cue field")
                }
            }
        }

        let version: Int
        let generation: String
        let source: String
        let publicationId: String?
        let ebookAssetId: String
        let text: [Text]
        let audio: [Track]
        let cueFields: [String]
        let cues: [Cue]
        let coverage: ReadAlongSummary.Coverage?

        enum CodingKeys: String, CodingKey {
            case version, generation, source, text, audio, cues, coverage
            case publicationId = "publication_id"
            case ebookAssetId = "ebook_asset_id"
            case cueFields = "cue_fields"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            guard version == ReadAlongManifest.version else {
                throw ReadAlongError.unusable("This read-along data is from an unsupported version.")
            }
            generation = try container.decode(String.self, forKey: .generation)
            source = try container.decode(String.self, forKey: .source)
            publicationId = try container.decodeIfPresent(String.self, forKey: .publicationId)
            ebookAssetId = try container.decode(String.self, forKey: .ebookAssetId)
            cueFields = try container.decode([String].self, forKey: .cueFields)
            guard cueFields == ReadAlongManifest.cueFields else {
                throw ReadAlongError.unusable("This read-along data has an unknown layout.")
            }
            text = try container.decode([Text].self, forKey: .text)
            audio = try container.decode([Track].self, forKey: .audio)
            cues = try container.decode([Cue].self, forKey: .cues)
            coverage = (try? container.decodeIfPresent(ReadAlongSummary.Coverage.self, forKey: .coverage)) ?? nil
        }
    }

    /// Checks and indexes `data` for exactly this edition.
    ///
    /// - Parameters:
    ///   - ebookAssetId: the EPUB asset whose summary named the manifest.
    ///   - generation: the summary's generation, when known (a stored bundle names its own).
    ///   - publicationId: the ebook publication, checked when the manifest states it.
    ///   - server: every audio URL must resolve inside it.
    public static func parse(_ data: Data, ebookAssetId: String, generation: String?, publicationId: String?, server: ServerAddress) throws -> ReadAlongManifest {
        guard Int64(data.count) <= maxBytes else { throw ReadAlongError.unusable("This read-along data is too large.") }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch let error as ReadAlongError {
            throw error
        } catch {
            throw ReadAlongError.unusable("This read-along data couldn't be read.")
        }
        guard isGeneration(raw.generation) else { throw ReadAlongError.unusable("This read-along data has no valid generation.") }
        if let generation, raw.generation != generation { throw ReadAlongError.changed }
        guard raw.ebookAssetId == ebookAssetId else { throw ReadAlongError.changed }
        if let publicationId, let stated = raw.publicationId, stated != publicationId { throw ReadAlongError.changed }
        guard let source = ReadAlongSource(rawValue: raw.source) else { throw ReadAlongError.unusable("This read-along data names an unknown source.") }

        guard (1 ... maxTexts).contains(raw.text.count) else { throw ReadAlongError.unusable("This read-along data names no text, or too much.") }
        for text in raw.text where !safeHref(text.href) {
            throw ReadAlongError.unusable("This read-along data names an unsafe text document.")
        }
        guard (1 ... maxAudio).contains(raw.audio.count) else { throw ReadAlongError.unusable("This read-along data names no audio, or too much.") }
        var audio: [Audio] = []
        audio.reserveCapacity(raw.audio.count)
        var pairedPublication: String?
        for track in raw.audio {
            guard track.mediaType.lowercased().hasPrefix("audio/"), track.sizeBytes >= 0,
                  let url = server.resolve(track.url), server.contains(url)
            else { throw ReadAlongError.unusable("This read-along data names audio this app can't fetch from your server.") }
            switch (source, track.kind) {
            case (.mediaOverlay, "epub_resource"):
                guard let href = track.href, safeHref(href) else { throw ReadAlongError.unusable("This read-along data names an unsafe audio entry.") }
                audio.append(Audio(kind: .epubResource(href: href), mediaType: track.mediaType, sizeBytes: track.sizeBytes, url: track.url))
            case (.imported, "publication_asset"):
                guard let publication = track.publicationId, !publication.isEmpty, publication.utf8.count <= 256,
                      let asset = track.assetId, !asset.isEmpty, asset.utf8.count <= 256,
                      pairedPublication == nil || pairedPublication == publication
                else { throw ReadAlongError.unusable("This read-along data names an unknown audiobook file.") }
                if let content = track.contentUrl {
                    guard let resolved = server.resolve(content), server.contains(resolved) else {
                        throw ReadAlongError.unusable("This read-along data names audio this app can't fetch from your server.")
                    }
                }
                pairedPublication = publication
                audio.append(Audio(kind: .publicationAsset(publicationId: publication, assetId: asset, filename: track.filename ?? "", contentUrl: track.contentUrl),
                                   mediaType: track.mediaType, sizeBytes: track.sizeBytes, url: track.url))
            default:
                throw ReadAlongError.unusable("This read-along data mixes audio kinds.")
            }
        }
        if source == .imported, Set(audio.compactMap(\.assetId)).count != audio.count {
            throw ReadAlongError.unusable("This read-along data names an audiobook file twice.")
        }

        guard (1 ... maxCues).contains(raw.cues.count) else { throw ReadAlongError.unusable("This read-along data has no cues, or too many.") }
        let count = raw.cues.count
        var cueText = [Int32](repeating: 0, count: count)
        var cueAudio = [Int32](repeating: 0, count: count)
        var cueBegin = [Int64](repeating: 0, count: count)
        var cueEnd = [Int64](repeating: 0, count: count)
        var fragments = [String]()
        fragments.reserveCapacity(count)
        var byAudio = [[Int32]](repeating: [], count: audio.count)
        var byText = [[Int32]](repeating: [], count: raw.text.count)
        var byFragment: [String: Int32] = [:]
        var previousText = 0
        for (index, cue) in raw.cues.enumerated() {
            // Cues are in reading order: spine order, then document order. A cue never
            // goes back to an earlier text document.
            guard cue.text >= previousText else { throw ReadAlongError.unusable("This read-along data isn't in reading order.") }
            previousText = cue.text
            guard raw.text.indices.contains(cue.text), audio.indices.contains(cue.audio), safeFragment(cue.fragment),
                  (0 ... maxMs).contains(cue.begin), cue.end.map({ $0 > cue.begin && $0 <= maxMs }) ?? true
            else { throw ReadAlongError.unusable("This read-along data has an invalid cue.") }
            cueText[index] = Int32(cue.text)
            cueAudio[index] = Int32(cue.audio)
            cueBegin[index] = cue.begin
            cueEnd[index] = cue.end ?? .max
            fragments.append(cue.fragment)
            byAudio[cue.audio].append(Int32(index))
            byText[cue.text].append(Int32(index))
            let key = raw.text[cue.text].href + "#" + cue.fragment
            if byFragment[key] == nil { byFragment[key] = Int32(index) }
        }
        for track in byAudio.indices {
            byAudio[track].sort { cueBegin[Int($0)] < cueBegin[Int($1)] }
            let list = byAudio[track]
            for position in list.indices.dropFirst() {
                let previous = Int(list[position - 1]), next = Int(list[position])
                if cueEnd[previous] == .max { throw ReadAlongError.unusable("A cue without an end isn't the last on its audio.") }
                if cueBegin[next] < cueEnd[previous] - overlapToleranceMs { throw ReadAlongError.unusable("This read-along data has overlapping cues.") }
            }
        }
        return ReadAlongManifest(
            generation: raw.generation, source: source, publicationId: raw.publicationId, ebookAssetId: raw.ebookAssetId,
            texts: raw.text.map(\.href), textMediaTypes: raw.text.map { $0.mediaType ?? "application/xhtml+xml" },
            audio: audio, coverage: raw.coverage,
            cueText: cueText, cueAudio: cueAudio, cueBegin: cueBegin, cueEnd: cueEnd, fragments: fragments,
            byAudio: byAudio, byFragment: byFragment, byText: byText
        )
    }

    /// An archive path inside the package: relative, no `..`, no scheme, backslash or control characters.
    static func safeHref(_ href: String) -> Bool {
        guard !href.isEmpty, href.utf8.count <= maxHrefBytes, !href.hasPrefix("/"), !href.contains("://") else { return false }
        if href.unicodeScalars.contains(where: { $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) { return false }
        return !href.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    static func safeFragment(_ fragment: String) -> Bool {
        !fragment.isEmpty && fragment.utf8.count <= maxFragmentBytes
            && !fragment.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: Cues

    public func href(ofCue cue: Int) -> String { texts[Int(cueText[cue])] }
    public func audio(ofCue cue: Int) -> Int { Int(cueAudio[cue]) }
    public func beginMs(ofCue cue: Int) -> Int64 { cueBegin[cue] }
    /// Nil when the clip runs to the end of its file.
    public func endMs(ofCue cue: Int) -> Int64? { cueEnd[cue] == .max ? nil : cueEnd[cue] }

    /// The last cue on `audio` that started at or before `ms`, as an index into `byAudio[audio]`.
    private func lastStarted(_ audio: Int, _ ms: Int64) -> Int? {
        guard byAudio.indices.contains(audio) else { return nil }
        let list = byAudio[audio]
        var low = 0, high = list.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if cueBegin[Int(list[middle])] <= ms {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// The cue whose interval contains `ms` on `audio`, or nil between cues.
    public func cue(at ms: Int64, audio: Int) -> Int? {
        guard let found = lastStarted(audio, ms) else { return nil }
        let cue = Int(byAudio[audio][found])
        return ms < cueEnd[cue] ? cue : nil
    }

    /// The narration most recently reached at `ms` on `audio`: the last cue that started
    /// at or before it, even in the silence after it. Nil before the audio's first cue.
    public func cueReached(at ms: Int64, audio: Int) -> Int? {
        lastStarted(audio, ms).map { Int(byAudio[audio][$0]) }
    }

    public func cue(href: String, fragment: String) -> Int? {
        if let found = byFragment[href + "#" + fragment] { return Int(found) }
        guard let text = textIndex(href) else { return nil }
        return byFragment[texts[text] + "#" + fragment].map(Int.init)
    }

    /// The text document `href` names, comparing as reading order hrefs do.
    public func textIndex(_ href: String) -> Int? {
        if let exact = texts.firstIndex(of: href) { return exact }
        return texts.firstIndex { ReadingRestoration.same($0, href) }
    }

    /// The cues of one text document, in reading order.
    public func cues(inText href: String) -> [Int] {
        guard let text = textIndex(href) else { return [] }
        return byText[text].map(Int.init)
    }

    /// The next audio after `audio`, in manifest order, that has cues.
    public func nextAudio(after audio: Int) -> Int? {
        var next = audio + 1
        while next < byAudio.count {
            if !byAudio[next].isEmpty { return next }
            next += 1
        }
        return nil
    }

    public func hasCues(audio: Int) -> Bool { byAudio.indices.contains(audio) && !byAudio[audio].isEmpty }

    /// The first narrated cue in reading order of a text document after `href`, for a
    /// page with no narration of its own.
    public func firstCue(after href: String, spine: [String]) -> Int? {
        guard let position = spine.firstIndex(where: { ReadingRestoration.same($0, href) }) else { return nil }
        for next in spine[(position + 1)...] {
            if let cue = cues(inText: next).first { return cue }
        }
        return nil
    }

    // MARK: Places

    /// Where narration is: an audio index and an exact offset.
    public struct Point: Sendable, Equatable {
        public let audio: Int
        public let ms: Int64
        /// The cue reached at that point.
        public let cue: Int
        /// True when it is the saved exact offset, false when it is the start of an element's cue.
        public let exact: Bool

        public init(audio: Int, ms: Int64, cue: Int, exact: Bool) {
            self.audio = audio
            self.ms = ms
            self.cue = cue
            self.exact = exact
        }

        public var seconds: Double { Double(ms) / 1000 }
    }

    /// The saved place for narration heard at `ms` of `audio`: the reached cue's element
    /// with the exact offset. Nil before any cue was reached.
    public func locator(heardAt ms: Int64, audio: Int, totalProgression: Double? = nil) -> JSONValue? {
        guard let cue = cueReached(at: ms, audio: audio) else { return nil }
        var locations: [String: JSONValue] = [
            "fragments": .array([.string(fragments[cue])]),
            "readAlong": .object([
                "generation": .string(generation),
                "audio": .number(Double(audio)),
                "offset_ms": .number(Double(max(0, min(ms, Self.maxMs)))),
            ]),
        ]
        if let totalProgression, totalProgression.isFinite, (0 ... 1).contains(totalProgression) {
            locations["totalProgression"] = .number(totalProgression)
        }
        let text = Int(cueText[cue])
        return .object([
            "href": .string(texts[text]),
            "type": .string(textMediaTypes[text]),
            "locations": .object(locations),
        ])
    }

    /// Where a saved locator puts the narration: its exact offset when it was saved
    /// against this generation and that offset's cue is in the same document, otherwise
    /// the start of its element's cue. Nil when it names neither.
    public func point(from locator: JSONValue?) -> Point? {
        guard let locator, let saved = locator["href"]?.stringValue else { return nil }
        let locations = locator["locations"]
        if let exact = Self.readAlongPoint(locations?["readAlong"]), exact.generation == generation, hasCues(audio: exact.audio),
           let cue = cueReached(at: exact.offsetMs, audio: exact.audio), ReadingRestoration.same(href(ofCue: cue), saved) {
            return Point(audio: exact.audio, ms: exact.offsetMs, cue: cue, exact: true)
        }
        if case let .array(list)? = locations?["fragments"], case let .string(fragment)? = list.first,
           !fragment.contains("="), let cue = cue(href: saved, fragment: fragment) {
            return Point(audio: audio(ofCue: cue), ms: cueBegin[cue], cue: cue, exact: false)
        }
        return nil
    }

    /// Where an audiobook place (imported alignments) lands in the narration, or nil.
    public func point(audiobookAsset assetId: String, seconds: Double) -> Point? {
        guard seconds.isFinite, seconds >= 0, let track = audio.firstIndex(where: { $0.assetId == assetId }) else { return nil }
        let ms = Int64((seconds * 1000).rounded())
        guard let cue = cueReached(at: ms, audio: track) else { return nil }
        return Point(audio: track, ms: ms, cue: cue, exact: true)
    }

    /// `locations.readAlong` exactly as the server accepts it: these three keys only,
    /// a 64-hex generation, audio 0–1999 and a whole number of milliseconds up to 48 h.
    public static func readAlongPoint(_ value: JSONValue?) -> (generation: String, audio: Int, offsetMs: Int64)? {
        guard case let .object(fields)? = value, Set(fields.keys) == ["generation", "audio", "offset_ms"],
              case let .string(generation)? = fields["generation"], isGeneration(generation),
              case let .number(audio)? = fields["audio"], audio.rounded() == audio, (0 ... Double(maxAudio - 1)).contains(audio),
              case let .number(offset)? = fields["offset_ms"], offset.rounded() == offset, (0 ... Double(maxMs)).contains(offset)
        else { return nil }
        return (generation, Int(audio), Int64(offset))
    }

    /// True when `locator` is a place reached by listening (it carries `readAlong`).
    public static func isHeard(_ locator: JSONValue?) -> Bool {
        locator?["locations"]?["readAlong"] != nil
    }
}
