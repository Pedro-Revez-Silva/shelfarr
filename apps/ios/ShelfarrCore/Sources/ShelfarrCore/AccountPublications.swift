import Foundation

public struct PublicationMetadata: Sendable {
    public let publication: Publication
    public let unverified: Bool
}

/// Last known metadata for books opened by this account. An offline reader needs
/// both this record and its EPUB; authentication and TLS errors never use it.
public actor AccountPublications {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func file(_ id: String) -> URL {
        directory.appendingPathComponent(SHA256.hexDigest(Data(id.utf8)) + ".json")
    }

    public func load(id: String, server: ServerAddress, api: ConsumerAPI) async throws -> PublicationMetadata {
        do {
            let publication = try await api.publication(server: server, id: id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(publication) {
                try? data.write(to: file(id), options: .atomic)
            }
            return PublicationMetadata(publication: publication, unverified: false)
        } catch let APIError.offline(certificate) where !certificate {
            guard let data = try? Data(contentsOf: file(id)),
                  let publication = try? JSONDecoder().decode(Publication.self, from: data)
            else { throw APIError.offline(certificate: false) }
            return PublicationMetadata(publication: publication, unverified: true)
        }
    }
}
