import Foundation
@testable import ShelfarrCore

/// Read-along manifests as the server writes them (docs/read-along.md), with known cues.
///
/// The narrated fixture has two chapters. Chapter 1 (`OEBPS/c1.xhtml`, audio 0) has cues
/// p1 0–2000, p2 2500–4500, p3 5000–7000 ms with silent gaps between them; chapter 2
/// (`OEBPS/c2.xhtml`, audio 1) has q1 0–3000 and q2 3000 to the end of its file.
enum ReadAlongFixture {
    static let server: ServerAddress = {
        guard case let .valid(address) = ServerAddress.parse("https://books.example.org/shelf") else { fatalError() }
        return address
    }()

    static let generation = String(repeating: "a1", count: 32)
    static let otherGeneration = String(repeating: "b2", count: 32)
    static let ebookAssetId = String(repeating: "e", count: 64)
    static let base = "/shelf/api/consumer/v1/library/12/assets/\(String(repeating: "e", count: 64))/read_along"

    static func overlayObject(generation: String = generation, audioSizes: [Int64] = [1000, 2000]) -> [String: Any] {
        [
            "version": 1,
            "generation": generation,
            "source": "media_overlay",
            "publication_id": "12",
            "ebook_asset_id": ebookAssetId,
            "package_path": "OEBPS/content.opf",
            "text": [
                ["href": "OEBPS/c1.xhtml", "media_type": "application/xhtml+xml"],
                ["href": "OEBPS/c2.xhtml", "media_type": "application/xhtml+xml"],
            ],
            "audio": [
                ["kind": "epub_resource", "href": "OEBPS/audio/one.mp3", "media_type": "audio/mpeg", "size_bytes": audioSizes[0],
                 "url": "\(base)/resources/OEBPS/audio/one.mp3"],
                ["kind": "epub_resource", "href": "OEBPS/audio/two.mp3", "media_type": "audio/mpeg", "size_bytes": audioSizes[1],
                 "url": "\(base)/resources/OEBPS/audio/two.mp3"],
            ],
            "cue_fields": ["text", "fragment", "audio", "begin_ms", "end_ms"],
            "cues": [
                [0, "p1", 0, 0, 2000],
                [0, "p2", 0, 2500, 4500],
                [0, "p3", 0, 5000, 7000],
                [1, "q1", 1, 0, 3000],
                [1, "q2", 1, 3000, NSNull()],
            ],
            "coverage": ["complete": true, "text_sections": 2, "aligned_sections": 2, "unaligned_sections": [], "cues": 5, "audio_ms": 9000],
            "resources": [["href": "META-INF/container.xml", "media_type": "application/xml", "size_bytes": 249, "url": "\(base)/resources/META-INF/container.xml"]],
            "resources_bytes": 249,
            "manifest_url": base,
            "resources_url": "\(base)/resources/",
        ]
    }

    static func importedObject(generation: String = generation) -> [String: Any] {
        var object = overlayObject(generation: generation)
        object["source"] = "imported"
        object["audio"] = [
            ["kind": "publication_asset", "publication_id": "40", "asset_id": "track-a", "filename": "01.mp3", "media_type": "audio/mpeg",
             "size_bytes": 1000, "url": "\(base)/audio/track-a", "content_url": "/shelf/api/consumer/v1/library/40/assets/track-a"],
            ["kind": "publication_asset", "publication_id": "40", "asset_id": "track-b", "filename": "02.mp3", "media_type": "audio/mpeg",
             "size_bytes": 2000, "url": "\(base)/audio/track-b", "content_url": "/shelf/api/consumer/v1/library/40/assets/track-b"],
        ]
        return object
    }

    static func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func parse(_ object: [String: Any], generation: String? = generation, ebookAssetId: String = ebookAssetId) throws -> ReadAlongManifest {
        try ReadAlongManifest.parse(data(object), ebookAssetId: ebookAssetId, generation: generation, publicationId: "12", server: server)
    }

    static var overlay: ReadAlongManifest { try! parse(overlayObject()) }
    static var imported: ReadAlongManifest { try! parse(importedObject()) }

    static func summary(_ generation: String = generation, source: ReadAlongSource = .mediaOverlay) -> ReadAlongSummary {
        ReadAlongSummary(status: .available, source: source, generation: generation, manifestUrl: base,
                         coverage: .init(complete: true, textSections: 2, alignedSections: 2), textBytes: 1000, audioBytes: 3000)
    }

    /// A heard locator for `audio` at `ms`, as the app writes it.
    static func heard(_ manifest: ReadAlongManifest, audio: Int, ms: Int64) -> JSONValue {
        manifest.locator(heardAt: ms, audio: audio)!
    }

    static func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelfarr-read-along-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An EPUB whose narration files are a stored entry and a deflated entry (zlib's
    /// output, so a real encoder's dynamic codes are streamed), sized as the manifest says.
    static func epub() -> (data: Data, one: Data, two: Data) {
        let one = DeflateVectors.noise(1000, seed: 7)
        let two = LongDeflate.text
        var zip = ZipBuilder()
        zip.add(.init("mimetype", Data("application/epub+zip".utf8)))
        zip.add(.init("META-INF/container.xml", Data("<container/>".utf8), method: 8))
        zip.add(.init("OEBPS/c1.xhtml", Data("<p id=\"p1\">One</p>".utf8)))
        zip.add(.init("OEBPS/audio/one.mp3", one))
        var deflated = ZipBuilder.Entry("OEBPS/audio/two.mp3", two, method: 8)
        deflated.compressed = LongDeflate.compressed
        zip.add(deflated)
        return (zip.build().data, one, two)
    }
}
