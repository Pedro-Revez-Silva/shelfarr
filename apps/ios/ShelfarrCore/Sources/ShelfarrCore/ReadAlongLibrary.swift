import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-along data kept on this device for one account: each book's manifest, bound to
/// its generation, and for EPUB 3 Media Overlays the narration files copied out of the
/// EPUB. An imported alignment's audio is the paired audiobook's own download, kept by
/// `DownloadManager` like any other audiobook.
///
/// Layout, under `root`:
///
///     <publication hash>/current.json          the generation in use, written last
///     <publication hash>/<generation>/manifest.json
///     <publication hash>/<generation>/bundle.json
///     <publication hash>/<generation>/audio-NNN.<ext>
///
/// A generation becomes current only once its manifest is stored and (for a media
/// overlay) every narration file is copied and verified, so a failed or interrupted
/// update leaves the previous ready data in use. Nothing is ever reported ready unless
/// it is all on disk now: missing, short or unreadable files make the bundle incomplete
/// and retryable. One instance serves the durable downloads (Application Support) and
/// another the evictable reading cache (Caches); both live under the account and are
/// deleted with it.
public actor ReadAlongLibrary {
    /// What is kept for one generation besides its manifest.
    public struct Bundle: Codable, Equatable, Sendable {
        public let publicationId: String
        public let ebookAssetId: String
        public let generation: String
        public let source: ReadAlongSource
        /// Local narration file names for a media overlay, by audio index. Empty for an import.
        public var audioFiles: [String]
        /// True once every media overlay narration file was copied and verified.
        public var audioComplete: Bool
        public var savedAt: Date
    }

    /// A stored generation, parsed again from disk for exactly its edition.
    public struct Stored: Sendable, Equatable {
        public let bundle: Bundle
        public let manifest: ReadAlongManifest
        public let directory: URL

        /// The verified local narration files of a media overlay, in audio order; nil until all are present.
        public var overlayAudio: [URL]? {
            guard manifest.source == .mediaOverlay, bundle.audioComplete, bundle.audioFiles.count == manifest.audio.count else { return nil }
            var found: [URL] = []
            for (index, name) in bundle.audioFiles.enumerated() {
                let url = directory.appendingPathComponent(name)
                guard ReadAlongLibrary.size(of: url) == manifest.audio[index].sizeBytes else { return nil }
                found.append(url)
            }
            return found
        }
    }

    /// Whether a book's narration can be used on this device right now.
    public enum Readiness: Sendable, Equatable {
        /// The manifest and every audio file for one generation are here.
        case ready(Stored, audio: [URL])
        /// Nothing was ever stored for this book.
        case none
        /// The stored manifest is for another edition of the EPUB than the one here.
        case otherEdition
        /// A media overlay's narration hasn't been copied out of the EPUB yet (or it was lost).
        case audioMissing(Stored)
        /// The paired audiobook isn't downloaded (or not every file it needs is).
        case audiobookMissing(Stored)
    }

    private let root: URL
    private let files = FileManager.default
    private var closed = false

    public init(root: URL) {
        self.root = root
    }

    /// Stops all further writes; the caller may then delete `root`.
    public func close() {
        closed = true
    }

    private func folder(_ publicationId: String) -> URL {
        root.appendingPathComponent(String(SHA256.hexDigest(Data(publicationId.utf8)).prefix(32)), isDirectory: true)
    }

    private func generationFolder(_ publicationId: String, _ generation: String) -> URL {
        folder(publicationId).appendingPathComponent(generation, isDirectory: true)
    }

    // MARK: Reading

    /// The current generation for `publicationId`, if it is stored, readable and for
    /// `ebookAssetId`. Corrupt files read as absent.
    public func current(_ publicationId: String, ebookAssetId: String, server: ServerAddress) -> Stored? {
        guard let generation = currentGeneration(publicationId) else { return nil }
        return stored(publicationId, generation: generation, ebookAssetId: ebookAssetId, server: server)
    }

    /// A stored generation, current or not.
    public func stored(_ publicationId: String, generation: String, ebookAssetId: String, server: ServerAddress) -> Stored? {
        guard ReadAlongManifest.isGeneration(generation) else { return nil }
        let directory = generationFolder(publicationId, generation)
        guard let bundleData = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")),
              let bundle = try? JSONDecoder().decode(Bundle.self, from: bundleData),
              bundle.publicationId == publicationId, bundle.generation == generation, bundle.ebookAssetId == ebookAssetId,
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? ReadAlongManifest.parse(data, ebookAssetId: ebookAssetId, generation: generation, publicationId: publicationId, server: server)
        else { return nil }
        return Stored(bundle: bundle, manifest: manifest, directory: directory)
    }

    /// The most recently saved generation for this edition, current or still being
    /// prepared (an update whose audio isn't complete yet).
    public func latest(_ publicationId: String, ebookAssetId: String, server: ServerAddress) -> Stored? {
        let names = ((try? files.contentsOfDirectory(atPath: folder(publicationId).path)) ?? []).filter(ReadAlongManifest.isGeneration)
        return names
            .compactMap { stored(publicationId, generation: $0, ebookAssetId: ebookAssetId, server: server) }
            .max { $0.bundle.savedAt < $1.bundle.savedAt }
    }

    /// The generation in use, if any.
    public func currentGenerationName(_ publicationId: String) -> String? {
        currentGeneration(publicationId)
    }

    private func currentGeneration(_ publicationId: String) -> String? {
        guard let data = try? Data(contentsOf: folder(publicationId).appendingPathComponent("current.json")),
              let value = try? JSONDecoder().decode([String: String].self, from: data),
              let generation = value["generation"], ReadAlongManifest.isGeneration(generation)
        else { return nil }
        return generation
    }

    /// Readiness of the current generation against the EPUB on this device and, for an
    /// imported alignment, the paired audiobook's local files by asset id.
    public func readiness(_ publicationId: String, ebookAssetId: String, server: ServerAddress, audiobookFiles: [String: URL]?) -> Readiness {
        guard let generation = currentGeneration(publicationId) else { return .none }
        guard let stored = stored(publicationId, generation: generation, ebookAssetId: ebookAssetId, server: server) else {
            // Stored for an EPUB this device no longer holds, or unreadable.
            return files.fileExists(atPath: generationFolder(publicationId, generation).path) ? .otherEdition : .none
        }
        return Self.readiness(stored, audiobookFiles: audiobookFiles)
    }

    /// Readiness of one stored generation against the paired audiobook's local files.
    public static func readiness(_ stored: Stored, audiobookFiles: [String: URL]?) -> Readiness {
        switch stored.manifest.source {
        case .mediaOverlay:
            guard let audio = stored.overlayAudio else { return .audioMissing(stored) }
            return .ready(stored, audio: audio)
        case .imported:
            var audio: [URL] = []
            for track in stored.manifest.audio {
                guard let id = track.assetId, let url = audiobookFiles?[id], FileManager.default.fileExists(atPath: url.path) else {
                    return .audiobookMissing(stored)
                }
                audio.append(url)
            }
            return .ready(stored, audio: audio)
        }
    }

    // MARK: Writing

    public enum Failure: Error, Equatable, Sendable {
        case closed
        case storage
        /// A narration file couldn't be copied out of the EPUB (missing, damaged, too large).
        case audio(String)
    }

    /// Stores a fetched manifest for its generation. It becomes current at once when
    /// nothing else is usable for this edition and it needs no copied audio; otherwise
    /// `prepareAudio` (media overlay) or `promote` makes it current once it is complete.
    /// Returns the stored generation.
    @discardableResult
    public func save(manifestData data: Data, manifest: ReadAlongManifest, publicationId: String) throws -> Stored {
        // Always stored: the check below never refuses.
        try save(manifestData: data, manifest: manifest, publicationId: publicationId, while: { true })!
    }

    /// `save`, only while `valid()` holds when the write starts. It is checked inside this
    /// actor, so whatever invalidates it (a cancelled download) and then cleans up here is
    /// ordered after a write that already passed. Nil when it no longer held.
    public func save(manifestData data: Data, manifest: ReadAlongManifest, publicationId: String, while valid: @Sendable () -> Bool) throws -> Stored? {
        guard !closed else { throw Failure.closed }
        guard valid() else { return nil }
        let directory = generationFolder(publicationId, manifest.generation)
        let bundle = Bundle(
            publicationId: publicationId, ebookAssetId: manifest.ebookAssetId, generation: manifest.generation,
            source: manifest.source, audioFiles: [], audioComplete: manifest.source == .imported, savedAt: Date()
        )
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(root)
            try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
            // A bundle that already has verified audio for this generation keeps it.
            if let existing = try? Data(contentsOf: directory.appendingPathComponent("bundle.json")),
               let previous = try? JSONDecoder().decode(Bundle.self, from: existing), previous.ebookAssetId == bundle.ebookAssetId, previous.audioComplete {
                return Stored(bundle: previous, manifest: manifest, directory: directory)
            }
            try JSONEncoder().encode(bundle).write(to: directory.appendingPathComponent("bundle.json"), options: .atomic)
        } catch {
            throw Failure.storage
        }
        return Stored(bundle: bundle, manifest: manifest, directory: directory)
    }

    /// Copies a media overlay's narration out of `epub` (which must be the manifest's EPUB
    /// generation), streaming each entry and checking its size and CRC-32, then makes the
    /// generation current. A failure leaves the previous current generation in place.
    public func prepareAudio(_ stored: Stored, epub: URL) throws -> Stored {
        try prepareAudio(stored, epub: epub, while: { true })!
    }

    /// `prepareAudio`, stopping without promoting as soon as `valid()` no longer holds
    /// (checked before each file and before the generation becomes current). Nil then; the
    /// files already copied stay in that generation's folder, which is not current.
    public func prepareAudio(_ stored: Stored, epub: URL, while valid: @Sendable () -> Bool) throws -> Stored? {
        guard !closed else { throw Failure.closed }
        guard stored.manifest.source == .mediaOverlay else { return stored }
        guard valid() else { return nil }
        if stored.overlayAudio != nil {
            return try promote(stored, while: valid) ? stored : nil
        }
        let archive: ComicArchive
        do {
            archive = try ComicArchive(file: epub)
        } catch {
            throw Failure.audio("This EPUB's archive couldn't be read to prepare its narration.")
        }
        defer { archive.close() }
        var names: [String] = []
        for (index, track) in stored.manifest.audio.enumerated() {
            guard !closed else { throw Failure.closed }
            guard valid() else { return nil }
            guard let href = track.href else { throw Failure.audio("Unexpected narration entry.") }
            let name = String(format: "audio-%03d", index) + "." + Self.fileExtension(href)
            let target = stored.directory.appendingPathComponent(name)
            if Self.size(of: target) != track.sizeBytes {
                do {
                    let copied = try archive.copyEntry(href, to: target, maxBytes: max(track.sizeBytes, 0))
                    guard copied == track.sizeBytes else {
                        try? files.removeItem(at: target)
                        throw Failure.audio("A narration file in this EPUB isn't the size its manifest says.")
                    }
                } catch let error as Failure {
                    throw error
                } catch ArchiveEntryError.unwritable {
                    throw Failure.storage
                } catch {
                    throw Failure.audio("A narration file in this EPUB is missing or damaged.")
                }
            }
            names.append(name)
        }
        var bundle = stored.bundle
        bundle.audioFiles = names
        bundle.audioComplete = true
        guard valid() else { return nil }
        do {
            try JSONEncoder().encode(bundle).write(to: stored.directory.appendingPathComponent("bundle.json"), options: .atomic)
        } catch {
            throw Failure.storage
        }
        let complete = Stored(bundle: bundle, manifest: stored.manifest, directory: stored.directory)
        return try promote(complete, while: valid) ? complete : nil
    }

    /// Makes `stored` the generation in use, then deletes every other generation of the book.
    public func promote(_ stored: Stored) throws {
        _ = try promote(stored, while: { true })
    }

    /// `promote`, only while `valid()` holds when it starts. False when it no longer held.
    @discardableResult
    public func promote(_ stored: Stored, while valid: @Sendable () -> Bool) throws -> Bool {
        guard !closed else { throw Failure.closed }
        guard valid() else { return false }
        let book = folder(stored.bundle.publicationId)
        do {
            try JSONEncoder().encode(["generation": stored.bundle.generation]).write(to: book.appendingPathComponent("current.json"), options: .atomic)
        } catch {
            throw Failure.storage
        }
        let others = (try? files.contentsOfDirectory(at: book, includingPropertiesForKeys: nil)) ?? []
        for other in others where other.lastPathComponent != stored.bundle.generation && other.lastPathComponent != "current.json" {
            try? files.removeItem(at: other)
        }
        return true
    }

    /// Deletes everything kept for one book, when `valid()` holds at that moment.
    public func remove(_ publicationId: String, while valid: @Sendable () -> Bool = { true }) {
        guard valid() else { return }
        try? files.removeItem(at: folder(publicationId))
    }

    /// Deletes a book's generations that never became current (an update or first
    /// download that was stopped), keeping the one in use, when `valid()` holds at that moment.
    public func discardPending(_ publicationId: String, while valid: @Sendable () -> Bool = { true }) {
        guard valid() else { return }
        let book = folder(publicationId)
        guard let current = currentGeneration(publicationId) else {
            try? files.removeItem(at: book)
            return
        }
        let entries = (try? files.contentsOfDirectory(at: book, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent != current && entry.lastPathComponent != "current.json" {
            try? files.removeItem(at: entry)
        }
    }

    /// Keeps at most `limit` books, dropping the least recently saved (for the reading cache).
    public func trim(keeping limit: Int, except publicationId: String? = nil) {
        let books = ((try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { publicationId == nil || $0.lastPathComponent != folder(publicationId!).lastPathComponent }
            .sorted { modified($0) > modified($1) }
        for book in books.dropFirst(max(0, limit)) { try? files.removeItem(at: book) }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.appendingPathComponent("current.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { $0 } ?? .distantPast
    }

    private func excludeFromBackup(_ url: URL) {
        #if os(iOS)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        #endif
    }

    static func size(of url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()).map(Int64.init)
    }

    /// A short safe extension for a copied file, so AVFoundation recognises it.
    static func fileExtension(_ href: String) -> String {
        let ext = (href as NSString).pathExtension.lowercased()
        return (1 ... 5).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? ext : "audio"
    }
}

/// Fetches a read-along manifest with the bearer, inside the configured server, bounded
/// to `ReadAlongManifest.maxBytes`, and maps the server's statuses.
public enum ReadAlongFetch {
    /// GETs `summary.manifestUrl` and checks it for exactly this edition and generation.
    /// Throws `ReadAlongError` for the contract's refusals, `APIError` for transport ones.
    public static func manifest(
        _ summary: ReadAlongSummary,
        ebookAssetId: String,
        publicationId: String,
        server: ServerAddress,
        transport: HTTPTransport,
        authorize: @Sendable (URL) -> URLRequest,
        scratch: URL
    ) async throws -> (data: Data, manifest: ReadAlongManifest) {
        guard summary.isAvailable, let reference = summary.manifestUrl, let url = server.resolve(reference), server.contains(url) else {
            throw ReadAlongError.unusable("This book's read-along data isn't on your server.")
        }
        var request = authorize(url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let response: HTTPURLResponse
        let body: Data?
        do {
            (response, body) = try await BoundedFetch.fetch(transport, request, scratch: scratch, limit: ReadAlongManifest.maxBytes)
        } catch is BoundedFetch.TooLarge {
            throw ReadAlongError.unusable("This read-along data is too large.")
        }
        switch response.statusCode {
        case 200:
            guard let body else { throw APIError.protocolError }
            let manifest = try ReadAlongManifest.parse(body, ebookAssetId: ebookAssetId, generation: summary.generation, publicationId: publicationId, server: server)
            return (body, manifest)
        case 404: throw ReadAlongError.unaligned(nil)
        case 409: throw ReadAlongError.stale(nil)
        case 422: throw ReadAlongError.invalid(nil)
        case 410: throw ReadAlongError.changed
        case 401: throw APIError.unauthorized
        case 403: throw APIError.forbidden
        case 500 ..< 600: throw APIError.server(response.statusCode)
        default: throw APIError.protocolError
        }
    }
}
