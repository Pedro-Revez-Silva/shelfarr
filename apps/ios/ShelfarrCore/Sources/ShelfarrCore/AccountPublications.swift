import Foundation

public struct PublicationMetadata: Sendable {
    public let publication: Publication
    public let unverified: Bool
}

/// Last known metadata for books opened by this account. An offline reader needs
/// both this record and its EPUB; authentication and TLS errors never use it.
public actor AccountPublications {
    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private let directory: URL
    private let cache: LibraryCache?

    /// With a `cache`, fetched details are kept for offline browsing too, and a title
    /// that was only ever seen in a listing still has offline details.
    public init(directory: URL, cache: LibraryCache? = nil) {
        self.directory = directory
        self.cache = cache
    }

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent(SHA256.hexDigest(Data(id.utf8)) + ".json")
    }

    public func load(id: String, server: ServerAddress, api: ConsumerAPI) async throws -> PublicationMetadata {
        let started = Date()
        do {
            let publication = try await api.publication(server: server, id: id)
            await cache?.record([publication], seenAt: started)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(publication) {
                try? data.write(to: file(id), options: .atomic)
            }
            return PublicationMetadata(publication: publication, unverified: false)
        } catch let APIError.offline(certificate) where !certificate {
            let saved = (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode(Publication.self, from: $0) }
            let listed = await cache?.title(id)
            // The newer of the two copies this account saw.
            let newest: Publication?
            if let listed, let saved {
                newest = listed.seenAt > (Self.modified(file(id)) ?? .distantPast) ? listed.publication : saved
            } else {
                newest = saved ?? listed?.publication
            }
            guard let newest else { throw APIError.offline(certificate: false) }
            return PublicationMetadata(publication: newest, unverified: true)
        }
    }
}
