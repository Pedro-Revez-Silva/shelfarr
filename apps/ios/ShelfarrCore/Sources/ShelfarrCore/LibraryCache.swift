import Foundation

/// One title as this device last saw it from the server.
public struct CachedTitle: Codable, Equatable, Sendable {
    public var publication: Publication
    /// When the request that returned this copy started. An older response never
    /// replaces a newer copy, so a slow page can't undo a status change.
    public var seenAt: Date
    /// Its place in the server's recently-added order when last listed, if known.
    public var recentRank: Int?
}

/// How much of the library this device can show offline. It never claims the whole
/// server library: only titles it has seen or downloaded.
public struct LibraryCoverage: Equatable, Sendable {
    /// Titles saved on this device in total, downloads included.
    public let titles: Int
    public let downloaded: Int
    /// The oldest and newest time a saved title was seen from the server.
    public let oldest: Date?
    public let newest: Date?

    public var isEmpty: Bool { titles == 0 }
}

public struct OfflinePage: Equatable, Sendable {
    public let items: [Publication]
    /// Offset of the next page, or nil at the end.
    public let nextOffset: Int?
    /// Matches in the saved titles, not on the server.
    public let total: Int
    public let coverage: LibraryCoverage
}

/// Canonical metadata for titles this account has seen: library pages, details,
/// status changes and Continue. Used to browse, search, filter and sort while the
/// server can't be reached. Bounded: the least recently seen titles are evicted first,
/// except downloaded ones, whose records also come from the downloads manifest.
public actor LibraryCache {
    private struct Stored: Codable {
        var version: Int
        var titles: [String: CachedTitle]
    }

    private let file: URL
    private let limit: Int
    private var titles: [String: CachedTitle] = [:]
    private var pinned: Set<String> = []
    private var loaded = false
    private var closed = false

    public init(file: URL, limit: Int = 600) {
        self.file = file
        self.limit = max(1, limit)
    }

    /// Records titles from one response. `recentOffset` is the position of the first item
    /// in the server's unfiltered recently-added listing, when the response was one.
    public func record(_ publications: [Publication], seenAt: Date, recentOffset: Int? = nil) {
        guard !closed, !publications.isEmpty else { return }
        load()
        var changed = false
        for (index, publication) in publications.enumerated() {
            if let existing = titles[publication.id], existing.seenAt > seenAt { continue }
            let rank = recentOffset.map { $0 + index } ?? titles[publication.id]?.recentRank
            let entry = CachedTitle(publication: publication, seenAt: seenAt, recentRank: rank)
            if titles[publication.id] != entry {
                titles[publication.id] = entry
                changed = true
            }
        }
        guard changed else { return }
        evict()
        persist()
    }

    /// Titles that must not be evicted, such as downloads.
    public func pin(_ ids: Set<String>) {
        pinned = ids
    }

    public func title(_ id: String) -> CachedTitle? {
        load()
        return titles[id]
    }

    /// Answers a library query from saved titles alone. `downloads` are merged in, and
    /// win only when this cache has no copy of their own.
    public func query(_ query: LibraryQuery, downloads: [Publication] = [], offset: Int = 0, limit: Int = 30) -> OfflinePage {
        load()
        var merged = titles
        for publication in downloads where merged[publication.id] == nil {
            merged[publication.id] = CachedTitle(publication: publication, seenAt: .distantPast, recentRank: nil)
        }
        let downloaded = Set(downloads.map(\.id))
        let seen = merged.values.map(\.seenAt).filter { $0 != .distantPast }
        let coverage = LibraryCoverage(titles: merged.count, downloaded: downloaded.count, oldest: seen.min(), newest: seen.max())

        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = merged.values.filter { entry in
            let publication = entry.publication
            switch query.filter {
            case .all: break
            case .ebook: if publication.bookType != .ebook { return false }
            case .audiobook: if publication.bookType != .audiobook { return false }
            }
            if let status = query.status, publication.status != status { return false }
            if !text.isEmpty, !Self.matches(text, publication) { return false }
            return true
        }
        let sorted: [CachedTitle]
        switch query.sort {
        case .title:
            sorted = matches.sorted { a, b in
                let order = a.publication.title.compare(b.publication.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
                return order == .orderedSame ? a.publication.id < b.publication.id : order == .orderedAscending
            }
        case .recent:
            // The server's last-seen order first, then titles it never listed, newest first.
            sorted = matches.sorted { a, b in
                switch (a.recentRank, b.recentRank) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if a.seenAt != b.seenAt { return a.seenAt > b.seenAt }
                    return a.publication.id < b.publication.id
                }
            }
        }
        let start = min(max(0, offset), sorted.count)
        let end = min(start + max(1, limit), sorted.count)
        return OfflinePage(
            items: sorted[start ..< end].map(\.publication),
            nextOffset: end < sorted.count ? end : nil,
            total: sorted.count,
            coverage: coverage
        )
    }

    /// Stops all writes. The caller may then delete the file.
    public func close() {
        closed = true
        titles.removeAll()
    }

    private static func matches(_ text: String, _ publication: Publication) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return publication.title.range(of: text, options: options) != nil
            || (publication.author?.range(of: text, options: options) != nil)
    }

    private func evict() {
        guard titles.count > limit else { return }
        let removable = titles.values
            .filter { !pinned.contains($0.publication.id) }
            .sorted { $0.seenAt < $1.seenAt }
        for entry in removable.prefix(titles.count - limit) {
            titles[entry.publication.id] = nil
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1
        else { return }
        titles = stored.titles
    }

    private func persist() {
        guard !closed else { return }
        // Never recreate an account folder that sign-out removed.
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        try? JSONEncoder().encode(Stored(version: 1, titles: titles)).write(to: file, options: .atomic)
    }
}

extension APIError {
    /// No connection at all. Only this may fall back to what the device saved; sign-in,
    /// certificate, redirect and server errors stay visible.
    public var allowsOfflineFallback: Bool {
        if case let .offline(certificate) = self { return !certificate }
        return false
    }
}

/// Where the next page of a listing comes from. A listing that fell back to the device
/// stays on the device until it is reloaded.
public enum LibraryCursor: Equatable, Sendable {
    case server(String)
    case device(Int)
}

public struct LibraryListing: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case server
        /// Saved titles only; never the whole server library.
        case device(LibraryCoverage)
    }

    public let items: [Publication]
    public let next: LibraryCursor?
    public let source: Source
}

/// Loads one library page from the server, keeping what it returns, or from the
/// device when, and only when, the connection is down.
public struct LibrarySource: Sendable {
    public typealias Fetch = @Sendable (LibraryQuery, String?) async throws -> LibraryPage

    private let fetch: Fetch
    private let cache: LibraryCache
    private let pageSize: Int

    public init(cache: LibraryCache, pageSize: Int = 30, fetch: @escaping Fetch) {
        self.cache = cache
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// `shown` is how many items of this listing are already on screen.
    public func load(_ query: LibraryQuery, after cursor: LibraryCursor? = nil, shown: Int = 0, downloads: [Publication] = []) async throws -> LibraryListing {
        if case let .device(offset) = cursor {
            return await device(query, offset: offset, downloads: downloads)
        }
        let started = Date()
        let serverCursor: String?
        if case let .server(value) = cursor { serverCursor = value } else { serverCursor = nil }
        do {
            let page = try await fetch(query, serverCursor)
            // Only the unfiltered recently-added listing states the server's order.
            let ranked = query.filter == .all && query.status == nil && query.sort == .recent
                && query.text.trimmingCharacters(in: .whitespaces).isEmpty
            await cache.record(page.items, seenAt: started, recentOffset: ranked ? shown : nil)
            return LibraryListing(items: page.items, next: page.nextCursor.map(LibraryCursor.server), source: .server)
        } catch let error as APIError where error.allowsOfflineFallback && cursor == nil {
            return await device(query, offset: 0, downloads: downloads)
        }
    }

    private func device(_ query: LibraryQuery, offset: Int, downloads: [Publication]) async -> LibraryListing {
        let page = await cache.query(query, downloads: downloads, offset: offset, limit: pageSize)
        return LibraryListing(items: page.items, next: page.nextOffset.map(LibraryCursor.device), source: .device(page.coverage))
    }
}
