import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

final class ReadAlongManifestTests: XCTestCase {
    private typealias F = ReadAlongFixture

    private func refused(_ object: [String: Any], generation: String? = F.generation, ebookAssetId: String = F.ebookAssetId,
                         file: StaticString = #filePath, line: UInt = #line) -> ReadAlongError? {
        do {
            _ = try F.parse(object, generation: generation, ebookAssetId: ebookAssetId)
            XCTFail("accepted", file: file, line: line)
            return nil
        } catch let error as ReadAlongError {
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    private func isUnusable(_ error: ReadAlongError?) -> Bool {
        if case .unusable = error { return true }
        return false
    }

    func testAMediaOverlayManifestIsIndexedInReadingOrder() throws {
        let manifest = try F.parse(F.overlayObject())
        XCTAssertEqual(manifest.source, .mediaOverlay)
        XCTAssertEqual(manifest.count, 5)
        XCTAssertEqual(manifest.texts, ["OEBPS/c1.xhtml", "OEBPS/c2.xhtml"])
        XCTAssertEqual(manifest.audio.map(\.href), ["OEBPS/audio/one.mp3", "OEBPS/audio/two.mp3"])
        XCTAssertEqual(manifest.cues(inText: "OEBPS/c1.xhtml").map { manifest.fragments[$0] }, ["p1", "p2", "p3"])
        XCTAssertEqual(manifest.cues(inText: "/OEBPS/c2.xhtml").map { manifest.fragments[$0] }, ["q1", "q2"], "hrefs compare as reading order hrefs")
        XCTAssertEqual(manifest.coverage?.description, "Narration covers all 2 sections.")
        XCTAssertNil(manifest.audiobookPublicationId)
    }

    func testCuesAreFoundOnlyWhereTheyAreHeard() throws {
        let manifest = F.overlay
        XCTAssertEqual(manifest.cue(at: 0, audio: 0), 0)
        XCTAssertEqual(manifest.cue(at: 1999, audio: 0), 0)
        XCTAssertNil(manifest.cue(at: 2000, audio: 0), "a clip ends exclusively")
        XCTAssertNil(manifest.cue(at: 2300, audio: 0), "nothing is heard between cues")
        XCTAssertEqual(manifest.cueReached(at: 2300, audio: 0), 0, "the gap still belongs to the narration last reached")
        XCTAssertEqual(manifest.cue(at: 2500, audio: 0), 1)
        XCTAssertNil(manifest.cue(at: 9000, audio: 0), "after the last cue of a file")
        XCTAssertEqual(manifest.cue(at: 3_600_000, audio: 1), 4, "an open-ended clip runs to the end of its file")
        XCTAssertNil(manifest.cue(at: 0, audio: 7))
        XCTAssertEqual(manifest.nextAudio(after: 0), 1)
        XCTAssertNil(manifest.nextAudio(after: 1))
    }

    func testNothingIsReachedBeforeAFilesFirstCue() throws {
        var object = F.overlayObject()
        object["cues"] = [[0, "p1", 0, 1500, 2000], [1, "q1", 1, 0, 1000]]
        let manifest = try F.parse(object)
        XCTAssertNil(manifest.cueReached(at: 1499, audio: 0))
        XCTAssertNil(manifest.locator(heardAt: 1000, audio: 0), "no place is written before the first cue")
        XCTAssertEqual(manifest.cueReached(at: 1500, audio: 0), 0)
    }

    func testAHeardPlaceIsTheReachedElementWithTheExactOffset() throws {
        let manifest = F.overlay
        let locator = try XCTUnwrap(manifest.locator(heardAt: 3743, audio: 0, totalProgression: 0.25))
        XCTAssertEqual(locator["href"]?.stringValue, "OEBPS/c1.xhtml")
        XCTAssertEqual(locator["type"]?.stringValue, "application/xhtml+xml")
        XCTAssertEqual(locator["locations"]?["fragments"], .array([.string("p2")]))
        XCTAssertEqual(locator["locations"]?["totalProgression"], .number(0.25))
        let point = try XCTUnwrap(ReadAlongManifest.readAlongPoint(locator["locations"]?["readAlong"]))
        XCTAssertEqual(point.generation, F.generation)
        XCTAssertEqual(point.audio, 0)
        XCTAssertEqual(point.offsetMs, 3743)
        // The server checks integers and exact keys.
        let text = try XCTUnwrap(locator.jsonString())
        XCTAssertTrue(text.contains("\"readAlong\":{\"audio\":0,\"generation\":\"\(F.generation)\",\"offset_ms\":3743}"), text)
        // In the silence after p2, the place is still p2's element, with the gap's offset.
        let gap = try XCTUnwrap(manifest.locator(heardAt: 4800, audio: 0))
        XCTAssertEqual(gap["locations"]?["fragments"], .array([.string("p2")]))
        XCTAssertEqual(ReadAlongManifest.readAlongPoint(gap["locations"]?["readAlong"])?.offsetMs, 4800)
    }

    func testRestoringTrustsTheOffsetOnlyForThisGenerationAndDocument() throws {
        let manifest = F.overlay
        let heard = F.heard(manifest, audio: 0, ms: 3743)
        XCTAssertEqual(manifest.point(from: heard), .init(audio: 0, ms: 3743, cue: 1, exact: true))

        // Another generation: the element's cue start, never the stale offset.
        let other = try F.parse(F.overlayObject(generation: F.otherGeneration), generation: F.otherGeneration)
        XCTAssertEqual(other.point(from: heard), .init(audio: 0, ms: 2500, cue: 1, exact: false))

        // The offset's cue is in another document than the locator names: its element instead.
        guard case var .object(fields) = heard else { return XCTFail() }
        fields["href"] = .string("OEBPS/c2.xhtml")
        fields["locations"] = .object([
            "fragments": .array([.string("q2")]),
            "readAlong": .object(["generation": .string(F.generation), "audio": .number(0), "offset_ms": .number(3743)]),
        ])
        XCTAssertEqual(manifest.point(from: .object(fields)), .init(audio: 1, ms: 3000, cue: 4, exact: false))

        // An ordinary reading place with no element names no narration.
        XCTAssertNil(manifest.point(from: .object(["href": .string("OEBPS/c1.xhtml"), "locations": .object(["progression": .number(0.5)])])))
        XCTAssertNil(manifest.point(from: nil))
    }

    func testReadAlongPointsMatchTheServersValidation() {
        let good: JSONValue = .object(["generation": .string(F.generation), "audio": .number(1999), "offset_ms": .number(172_800_000)])
        XCTAssertNotNil(ReadAlongManifest.readAlongPoint(good))
        for bad: JSONValue in [
            .object(["generation": .string(F.generation), "audio": .number(2000), "offset_ms": .number(0)]),
            .object(["generation": .string(F.generation), "audio": .number(0), "offset_ms": .number(172_800_001)]),
            .object(["generation": .string(F.generation), "audio": .number(0), "offset_ms": .number(1.5)]),
            .object(["generation": .string(F.generation), "audio": .number(-1), "offset_ms": .number(0)]),
            .object(["generation": .string("ABC"), "audio": .number(0), "offset_ms": .number(0)]),
            .object(["generation": .string(F.generation), "audio": .number(0), "offset_ms": .number(0), "cue": .number(1)]),
            .object(["generation": .string(F.generation), "audio": .string("0"), "offset_ms": .number(0)]),
            .null,
        ] {
            XCTAssertNil(ReadAlongManifest.readAlongPoint(bad), "\(bad)")
        }
    }

    func testAnImportedManifestNamesThePairedAudiobooksFiles() throws {
        let manifest = try F.parse(F.importedObject())
        XCTAssertEqual(manifest.source, .imported)
        XCTAssertEqual(manifest.audiobookPublicationId, "40")
        XCTAssertEqual(manifest.audio.map(\.assetId), ["track-a", "track-b"])
        XCTAssertEqual(manifest.point(audiobookAsset: "track-b", seconds: 3.5), .init(audio: 1, ms: 3500, cue: 4, exact: true))
        XCTAssertNil(manifest.point(audiobookAsset: "elsewhere", seconds: 1))
        XCTAssertNil(manifest.point(audiobookAsset: "track-a", seconds: .nan))
    }

    func testTheEditionAndGenerationMustBeTheOnesTheDetailsNamed() {
        XCTAssertEqual(refused(F.overlayObject(), generation: F.otherGeneration), .changed)
        XCTAssertEqual(refused(F.overlayObject(), ebookAssetId: "another-asset"), .changed)
        var object = F.overlayObject()
        object["publication_id"] = "13"
        XCTAssertEqual(refused(object), .changed)
        // A stored bundle names its own generation; nil accepts the manifest's.
        XCTAssertNoThrow(try F.parse(F.overlayObject(), generation: nil))
    }

    func testUnknownVersionsLayoutsAndSourcesAreRefused() {
        var object = F.overlayObject()
        object["version"] = 2
        XCTAssertTrue(isUnusable(refused(object)))
        object = F.overlayObject()
        object["cue_fields"] = ["text", "audio", "fragment", "begin_ms", "end_ms"]
        XCTAssertTrue(isUnusable(refused(object)))
        object = F.overlayObject()
        object["source"] = "tts"
        XCTAssertTrue(isUnusable(refused(object)), "speech synthesis is never a source")
        object = F.overlayObject()
        object["generation"] = String(repeating: "A1", count: 32)
        XCTAssertTrue(isUnusable(refused(object, generation: nil)))
        XCTAssertTrue(isUnusable(refused(["version": 1])))
    }

    func testUnsafeReferencesAndForeignURLsAreRefused() {
        for href in ["../c1.xhtml", "/OEBPS/c1.xhtml", "OEBPS//c1.xhtml", "https://evil.example/c1.xhtml", "OEBPS\\c1.xhtml", "OEBPS/c1\u{1}.xhtml"] {
            var object = F.overlayObject()
            object["text"] = [["href": href, "media_type": "application/xhtml+xml"], ["href": "OEBPS/c2.xhtml"]]
            XCTAssertTrue(isUnusable(refused(object)), href)
        }
        for url in ["https://evil.example/shelf/api/consumer/v1/x", "http://books.example.org/shelf/x", "https://books.example.org/other/x", "//evil.example/x"] {
            var object = F.overlayObject()
            var audio = object["audio"] as! [[String: Any]]
            audio[0]["url"] = url
            object["audio"] = audio
            XCTAssertTrue(isUnusable(refused(object)), url)
        }
        var object = F.importedObject()
        var audio = object["audio"] as! [[String: Any]]
        audio[1]["content_url"] = "https://evil.example/shelf/api/consumer/v1/library/40/assets/track-b"
        object["audio"] = audio
        XCTAssertTrue(isUnusable(refused(object)), "a foreign content_url")
        // An absolute URL inside the server is fine.
        object = F.overlayObject()
        audio = object["audio"] as! [[String: Any]]
        audio[0]["url"] = "https://books.example.org/shelf/api/consumer/v1/library/12/x"
        object["audio"] = audio
        XCTAssertNoThrow(try F.parse(object))
    }

    func testAudioKindsMustMatchTheSourceAndOneAudiobook() {
        var object = F.overlayObject()
        object["audio"] = (F.importedObject()["audio"] as! [[String: Any]])
        XCTAssertTrue(isUnusable(refused(object)), "an overlay never names audiobook files")
        object = F.importedObject()
        var audio = object["audio"] as! [[String: Any]]
        audio[1]["publication_id"] = "41"
        object["audio"] = audio
        XCTAssertTrue(isUnusable(refused(object)), "one paired audiobook")
        audio[1]["publication_id"] = "40"
        audio[1]["asset_id"] = "track-a"
        object["audio"] = audio
        XCTAssertTrue(isUnusable(refused(object)), "one audiobook file twice")
        object = F.overlayObject()
        audio = object["audio"] as! [[String: Any]]
        audio[0]["media_type"] = "text/html"
        object["audio"] = audio
        XCTAssertTrue(isUnusable(refused(object)))
    }

    func testCuesMustBeWellFormedAndInRange() {
        let bad: [[Any]] = [
            [2, "p1", 0, 0, 100],              // text out of range
            [0, "p1", 2, 0, 100],              // audio out of range
            [0, "", 0, 0, 100],                // empty element
            [0, String(repeating: "x", count: 257), 0, 0, 100],
            [0, "p1", 0, 100, 100],            // empty interval
            [0, "p1", 0, 200, 100],            // reversed
            [0, "p1", 0, -1, 100],
            [0, "p1", 0, 0, 172_800_001],      // past 48 h
            [0, "p1", 0, 1.5, 100],            // not whole milliseconds
            [0, "p1", 0, true, 100],           // not a number
            [0, "p1", 0, 0, 100, "extra"],
            [0, "p1", 0, 0],
        ]
        for cue in bad {
            var object = F.overlayObject()
            object["cues"] = [cue]
            XCTAssertTrue(isUnusable(refused(object)), "\(cue)")
        }
    }

    func testOverlapsAndOpenEndsFollowTheServersRules() throws {
        var object = F.overlayObject()
        object["cues"] = [[0, "p1", 0, 0, 2000], [0, "p2", 0, 1996, 3000]]
        XCTAssertNoThrow(try F.parse(object), "rounded clip values may touch within 5 ms")
        object["cues"] = [[0, "p1", 0, 0, 2000], [0, "p2", 0, 1994, 3000]]
        XCTAssertTrue(isUnusable(refused(object)), "a real overlap")
        object["cues"] = [[0, "p2", 0, 2000, 3000], [0, "p1", 0, 0, 2100]]
        XCTAssertTrue(isUnusable(refused(object)), "overlap is checked by start, whatever the reading order")
        object["cues"] = [[0, "p1", 0, 0, NSNull()], [0, "p2", 0, 2500, 3000]]
        XCTAssertTrue(isUnusable(refused(object)), "an open-ended clip must be its file's last")
        object["cues"] = [[0, "p1", 0, 0, 2000], [1, "q1", 1, 0, NSNull()]]
        XCTAssertNoThrow(try F.parse(object))
        object["cues"] = []
        XCTAssertTrue(isUnusable(refused(object)))
    }

    func testCuesMustBeInReadingOrder() throws {
        var object = F.overlayObject()
        object["cues"] = [[1, "q1", 1, 0, 1000], [0, "p1", 0, 0, 1000]]
        XCTAssertTrue(isUnusable(refused(object)), "a cue never returns to an earlier document")
        // Audio order and clip times are independent of reading order.
        object["cues"] = [[0, "p1", 1, 5000, 6000], [0, "p2", 0, 0, 1000], [1, "q1", 1, 0, 1000]]
        let manifest = try F.parse(object)
        XCTAssertEqual(manifest.cue(at: 5500, audio: 1), 0)
        XCTAssertEqual(manifest.cue(at: 500, audio: 1), 2)
    }

    func testAtMostTwoThousandAudioFiles() throws {
        func manifest(audioCount: Int) -> [String: Any] {
            var object = F.overlayObject()
            object["audio"] = (0 ..< audioCount).map { index -> [String: Any] in
                ["kind": "epub_resource", "href": "OEBPS/audio/\(index).mp3", "media_type": "audio/mpeg", "size_bytes": 10,
                 "url": "\(F.base)/resources/OEBPS/audio/\(index).mp3"]
            }
            object["cues"] = [[0, "p1", audioCount - 1, 0, 1000]]
            return object
        }
        let largest = try F.parse(manifest(audioCount: 2000))
        XCTAssertEqual(largest.audio.count, 2000)
        XCTAssertEqual(largest.cue(at: 10, audio: 1999), 0, "audio index 1999 is the last allowed")
        XCTAssertTrue(isUnusable(refused(manifest(audioCount: 2001))), "track 2000 is never accepted")
    }

    func testOversizedManifestsAreRefusedBeforeDecoding() {
        let huge = Data(repeating: 0x20, count: Int(ReadAlongManifest.maxBytes) + 1)
        XCTAssertThrowsError(try ReadAlongManifest.parse(huge, ebookAssetId: F.ebookAssetId, generation: nil, publicationId: nil, server: F.server)) {
            XCTAssertEqual($0 as? ReadAlongError, .unusable("This read-along data is too large."))
        }
    }

    // MARK: Summaries and the opt-in

    func testSummariesAreReadLenientlyAndOnlyOnEPUBs() throws {
        let json = """
        {"id":"12","title":"T","book_type":"ebook","assets":[
          {"id":"e","format":"epub","media_type":"application/epub+zip","content_url":"/a","read_along":{
            "status":"available","source":"imported","generation":"\(F.generation)","manifest_url":"/m",
            "coverage":{"complete":false,"text_sections":3,"aligned_sections":2,"cues":812,"audio_ms":3605000},
            "text_bytes":1840211,"audio_bytes":61022451,"audiobook":{"id":"40","title":"Heard"}}},
          {"id":"p","format":"pdf","media_type":"application/pdf","content_url":"/p","read_along":{"status":"available"}},
          {"id":"e2","format":"epub","content_url":"/b","read_along":{"status":"nonsense"}},
          {"id":"e3","format":"epub","content_url":"/c","read_along":{"status":"available","source":"media_overlay","generation":"zz","manifest_url":"/m"}},
          {"id":"e4","format":"epub","content_url":"/d","read_along":{"status":"unaligned","reason":"No narration","audiobook":{"id":"41","title":"Other"}}}
        ]}
        """
        let publication = try JSONDecoder().decode(Publication.self, from: Data(json.utf8))
        let summary = try XCTUnwrap(publication.assets[0].readAlong)
        XCTAssertTrue(summary.isAvailable)
        XCTAssertEqual(summary.source, .imported)
        XCTAssertEqual(summary.audiobook?.title, "Heard")
        XCTAssertEqual(summary.coverage?.description, "Narration covers 2 of 3 sections; the others show text only.")
        XCTAssertNil(publication.assets[1].readAlong, "only an EPUB carries read-along")
        XCTAssertNil(publication.assets[2].readAlong, "an unknown status reads as no read-along")
        XCTAssertEqual(publication.assets[3].readAlong?.isAvailable, false, "a malformed generation is never usable")
        XCTAssertEqual(publication.assets[4].readAlong?.status, .unaligned)
        XCTAssertEqual(publication.assets[4].readAlong?.audiobook?.id, "41")
        // Cached copies keep the summary.
        let again = try JSONDecoder().decode(Publication.self, from: JSONEncoder().encode(publication))
        XCTAssertEqual(again, publication)
    }

    func testOnlyDetailsDeclareTheFeature() async throws {
        let transport = FakeTransport()
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: F.server, accessToken: "token") })
        transport.enqueue(200, #"{"id":"12","title":"T","book_type":"ebook","assets":[]}"#)
        _ = try await api.publication(server: F.server, id: "12")
        transport.enqueue(200, #"{"items":[],"next_cursor":null}"#)
        _ = try await api.library(server: F.server)
        transport.enqueue(200, #"{"items":[]}"#)
        _ = try await api.continueReading(server: F.server)
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Shelfarr-Reader-Features"), "read-along")
        XCTAssertNil(transport.requests[1].value(forHTTPHeaderField: "X-Shelfarr-Reader-Features"), "listings never carry it")
        XCTAssertNil(transport.requests[2].value(forHTTPHeaderField: "X-Shelfarr-Reader-Features"), "Continue never carries it")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Shelfarr-Reader-Formats"), "epub,pdf,cbz", "formats are still declared")
    }

    // MARK: Fetching

    func testManifestStatusesMapToTheContract() async throws {
        let scratch = F.temporaryDirectory("fetch").appendingPathComponent("manifest.part")
        let cases: [(Int, ReadAlongError)] = [(404, .unaligned(nil)), (409, .stale(nil)), (422, .invalid(nil)), (410, .changed)]
        for (status, expected) in cases {
            let transport = FakeTransport()
            transport.enqueue(status, #"{"error":"x"}"#)
            do {
                _ = try await ReadAlongFetch.manifest(F.summary(), ebookAssetId: F.ebookAssetId, publicationId: "12", server: F.server,
                                                      transport: transport, authorize: { URLRequest(url: $0) }, scratch: scratch)
                XCTFail("\(status) accepted")
            } catch {
                XCTAssertEqual(error as? ReadAlongError, expected, "\(status)")
            }
        }
        let transport = FakeTransport()
        transport.enqueue(200, String(decoding: F.data(F.overlayObject()), as: UTF8.self))
        let fetched = try await ReadAlongFetch.manifest(F.summary(), ebookAssetId: F.ebookAssetId, publicationId: "12", server: F.server,
                                                        transport: transport, authorize: { URLRequest(url: $0) }, scratch: scratch)
        XCTAssertEqual(fetched.manifest.generation, F.generation)
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://books.example.org" + F.base)
    }

    func testAManifestURLOutsideTheServerIsNeverRequested() async {
        let transport = FakeTransport()
        let summary = ReadAlongSummary(status: .available, source: .mediaOverlay, generation: F.generation, manifestUrl: "https://evil.example/m")
        do {
            _ = try await ReadAlongFetch.manifest(summary, ebookAssetId: F.ebookAssetId, publicationId: "12", server: F.server, transport: transport,
                                                  authorize: { URLRequest(url: $0) }, scratch: F.temporaryDirectory("foreign").appendingPathComponent("m"))
            XCTFail("accepted")
        } catch {
            XCTAssertTrue(transport.requests.isEmpty, "no request, so no bearer, ever left the server")
        }
    }
}
