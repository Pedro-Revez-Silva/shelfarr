import Foundation
@testable import ShelfarrCore
import XCTest

/// Offline read-along bundles: ready only with the manifest and every audio file of one
/// generation, honest about what is missing, and never losing ready data to a failed update.
final class ReadAlongLibraryTests: XCTestCase {
    private typealias F = ReadAlongFixture

    private func overlay(_ generation: String = F.generation) -> (Data, ReadAlongManifest) {
        let object = F.overlayObject(generation: generation, audioSizes: [1000, Int64(LongDeflate.text.count)])
        let data = F.data(object)
        return (data, try! ReadAlongManifest.parse(data, ebookAssetId: F.ebookAssetId, generation: generation, publicationId: "12", server: F.server))
    }

    private func epubFile(_ directory: URL, _ data: Data? = nil) -> URL {
        let url = directory.appendingPathComponent("book-\(UUID().uuidString).epub")
        try! (data ?? F.epub().data).write(to: url)
        return url
    }

    func testAMediaOverlayIsReadyOnlyOnceItsNarrationIsCopiedOut() async throws {
        let directory = F.temporaryDirectory("overlay-bundle")
        let library = ReadAlongLibrary(root: directory.appendingPathComponent("read-along"))
        let (data, manifest) = overlay()
        let stored = try await library.save(manifestData: data, manifest: manifest, publicationId: "12")
        let before = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil)
        XCTAssertEqual(before, .none, "a manifest alone is not current, so not ready")

        let fixture = F.epub()
        let complete = try await library.prepareAudio(stored, epub: epubFile(directory, fixture.data))
        let audio = try XCTUnwrap(complete.overlayAudio)
        XCTAssertEqual(try Data(contentsOf: audio[0]), fixture.one, "a stored entry, copied as it is")
        XCTAssertEqual(try Data(contentsOf: audio[1]), fixture.two, "a deflated entry, streamed through the decoder")
        XCTAssertEqual(audio.map(\.pathExtension), ["mp3", "mp3"])
        guard case let .ready(ready, files) = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil) else {
            return XCTFail("not ready")
        }
        XCTAssertEqual(ready.manifest.generation, F.generation)
        XCTAssertEqual(files, audio)

        // A file lost or cut short since is reported, not trusted.
        let handle = try FileHandle(forWritingTo: audio[1])
        try handle.truncate(atOffset: 10)
        try handle.close()
        guard case .audioMissing = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil) else {
            return XCTFail("a short narration file still counted as ready")
        }
        // Preparing again repairs only what is missing.
        let found = await library.current("12", ebookAssetId: F.ebookAssetId, server: F.server)
        let current = try XCTUnwrap(found)
        _ = try await library.prepareAudio(current, epub: epubFile(directory, fixture.data))
        guard case .ready = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil) else {
            return XCTFail("not repaired")
        }
    }

    func testDamagedOrMissingNarrationIsNeverReady() async throws {
        let directory = F.temporaryDirectory("damaged")
        let library = ReadAlongLibrary(root: directory.appendingPathComponent("read-along"))
        let (data, manifest) = overlay()
        let stored = try await library.save(manifestData: data, manifest: manifest, publicationId: "12")

        // A deflated entry whose CRC doesn't match.
        var zip = ZipBuilder()
        zip.add(.init("OEBPS/audio/one.mp3", DeflateVectors.noise(1000, seed: 7)))
        var bad = ZipBuilder.Entry("OEBPS/audio/two.mp3", LongDeflate.text, method: 8)
        bad.compressed = LongDeflate.compressed
        bad.centralCRC = 0xDEAD_BEEF
        bad.localCRC = 0xDEAD_BEEF
        zip.add(bad)
        do {
            _ = try await library.prepareAudio(stored, epub: epubFile(directory, zip.build().data))
            XCTFail("a damaged entry was accepted")
        } catch let error as ReadAlongLibrary.Failure {
            guard case .audio = error else { return XCTFail("\(error)") }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: stored.directory.path)
        XCTAssertFalse(leftovers.contains("audio-001.mp3"), "nothing unverified is left in place")
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".part") })
        let readiness = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil)
        XCTAssertEqual(readiness, .none)

        // An EPUB without the entry at all.
        var missing = ZipBuilder()
        missing.add(.init("OEBPS/audio/one.mp3", DeflateVectors.noise(1000, seed: 7)))
        do {
            _ = try await library.prepareAudio(stored, epub: epubFile(directory, missing.build().data))
            XCTFail("a missing entry was accepted")
        } catch {}
        // A file that isn't an archive.
        do {
            _ = try await library.prepareAudio(stored, epub: epubFile(directory, Data("not a zip".utf8)))
            XCTFail("accepted")
        } catch {}
    }

    func testAFailedUpdateKeepsThePreviousReadyGeneration() async throws {
        let directory = F.temporaryDirectory("update")
        let library = ReadAlongLibrary(root: directory.appendingPathComponent("read-along"))
        let (data, manifest) = overlay()
        let epub = epubFile(directory)
        _ = try await library.prepareAudio(try await library.save(manifestData: data, manifest: manifest, publicationId: "12"), epub: epub)

        // A new generation whose audio can't be prepared.
        let (newer, newManifest) = overlay(F.otherGeneration)
        let pending = try await library.save(manifestData: newer, manifest: newManifest, publicationId: "12")
        do {
            _ = try await library.prepareAudio(pending, epub: epubFile(directory, Data("broken".utf8)))
            XCTFail("accepted")
        } catch {}
        guard case let .ready(still, _) = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil) else {
            return XCTFail("the previous ready bundle was lost")
        }
        XCTAssertEqual(still.manifest.generation, F.generation)

        // Once the update succeeds it replaces the old generation, which is deleted.
        _ = try await library.prepareAudio(pending, epub: epub)
        let current = await library.current("12", ebookAssetId: F.ebookAssetId, server: F.server)
        XCTAssertEqual(current?.manifest.generation, F.otherGeneration)
        let old = await library.stored("12", generation: F.generation, ebookAssetId: F.ebookAssetId, server: F.server)
        XCTAssertNil(old)
    }

    func testAnImportIsReadyOnlyWithEveryPairedAudiobookFile() async throws {
        let directory = F.temporaryDirectory("imported")
        let library = ReadAlongLibrary(root: directory.appendingPathComponent("read-along"))
        let data = F.data(F.importedObject())
        let stored = try await library.save(manifestData: data, manifest: F.imported, publicationId: "12")
        try await library.promote(stored)
        let trackA = directory.appendingPathComponent("a.mp3"), trackB = directory.appendingPathComponent("b.mp3")
        try Data([1]).write(to: trackA)
        let missing = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: ["track-a": trackA])
        guard case .audiobookMissing = missing else { return XCTFail("\(missing)") }
        let notOnDisk = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: ["track-a": trackA, "track-b": trackB])
        guard case .audiobookMissing = notOnDisk else { return XCTFail("a file named but not on disk counted") }
        try Data([2]).write(to: trackB)
        guard case let .ready(_, audio) = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: ["track-b": trackB, "track-a": trackA]) else {
            return XCTFail("not ready")
        }
        XCTAssertEqual(audio, [trackA, trackB], "in the manifest's audio order")
    }

    func testAnotherEditionOrAnUnreadableBundleIsNotReady() async throws {
        let directory = F.temporaryDirectory("edition")
        let library = ReadAlongLibrary(root: directory.appendingPathComponent("read-along"))
        let (data, manifest) = overlay()
        let stored = try await library.prepareAudio(try await library.save(manifestData: data, manifest: manifest, publicationId: "12"), epub: epubFile(directory))
        let other = await library.readiness("12", ebookAssetId: "replaced-epub", server: F.server, audiobookFiles: nil)
        XCTAssertEqual(other, .otherEdition, "a bundle for a replaced EPUB is never used")
        try Data("{".utf8).write(to: stored.directory.appendingPathComponent("manifest.json"))
        let corrupt = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil)
        XCTAssertEqual(corrupt, .otherEdition, "a corrupt manifest is not usable")
        await library.remove("12")
        let removed = await library.readiness("12", ebookAssetId: F.ebookAssetId, server: F.server, audiobookFiles: nil)
        XCTAssertEqual(removed, .none)
        // Accounts never share a library, and a closed one writes nothing more.
        await library.close()
        do {
            _ = try await library.save(manifestData: data, manifest: manifest, publicationId: "12")
            XCTFail("a closed library wrote")
        } catch {
            XCTAssertEqual(error as? ReadAlongLibrary.Failure, .closed)
        }
    }
}

final class InflateStreamTests: XCTestCase {
    private func stream(_ compressed: Data, expected: Int, chunk: Int) throws -> (Data, UInt32) {
        var offset = 0
        var output = Data()
        let crc = try Inflate.stream(compressedSize: Int64(compressed.count), expectedSize: Int64(expected), read: { limit in
            let length = min(limit, chunk, compressed.count - offset)
            defer { offset += length }
            return compressed.subdata(in: offset ..< offset + length)
        }, write: { output.append($0) })
        return (output, crc)
    }

    func testStreamingMatchesTheWholeDecoderOnEveryVector() throws {
        let vectors: [(Data, Data)] = [
            (DeflateVectors.data(DeflateVectors.text9), DeflateVectors.text),
            (DeflateVectors.data(DeflateVectors.textFixed), DeflateVectors.text),
            (DeflateVectors.data(DeflateVectors.png9), DeflateVectors.png),
            (DeflateVectors.data(DeflateVectors.abc), Data("abc".utf8)),
            (DeflateVectors.data(DeflateVectors.empty), Data()),
            (DeflateVectors.stored(DeflateVectors.noise(200_000), blockSize: 50_000), DeflateVectors.noise(200_000)),
            (LongDeflate.compressed, LongDeflate.text),
        ]
        for (compressed, plain) in vectors {
            for chunk in [1, 7, 4096, 1 << 16] {
                let (output, crc) = try stream(compressed, expected: plain.count, chunk: chunk)
                XCTAssertEqual(output, plain, "chunk \(chunk)")
                XCTAssertEqual(crc, CRC32.checksum(plain))
            }
        }
        XCTAssertEqual(CRC32.checksum(LongDeflate.text), LongDeflate.crc, "the vector is what zlib compressed")
    }

    func testStreamingRefusesWhatTheWholeDecoderRefuses() {
        let compressed = LongDeflate.compressed
        XCTAssertThrowsError(try stream(compressed, expected: LongDeflate.text.count - 1, chunk: 4096), "more output than declared")
        XCTAssertThrowsError(try stream(compressed, expected: LongDeflate.text.count + 1, chunk: 4096), "less output than declared")
        XCTAssertThrowsError(try stream(compressed.prefix(compressed.count - 10), expected: LongDeflate.text.count, chunk: 4096), "truncated")
        XCTAssertThrowsError(try stream(compressed + Data([0]), expected: LongDeflate.text.count, chunk: 4096), "trailing data")
        var early = FixedHuffmanWriter()
        early.header(final: true)
        early.literal(65)
        early.copy3(distanceCode: 1)
        early.literal(256)
        XCTAssertThrowsError(try stream(early.data, expected: 4, chunk: 1), "a distance before the start")
    }
}

final class ReadingRestorationElementTests: XCTestCase {
    private let target: JSONValue = .object([
        "href": .string("OEBPS/c1.xhtml"), "type": .string("application/xhtml+xml"),
        "locations": .object([
            "fragments": .array([.string("p4")]),
            "readAlong": .object(["generation": .string(ReadAlongFixture.generation), "audio": .number(0), "offset_ms": .number(9000)]),
        ]),
    ])

    private func report(_ href: String, _ from: Double, _ to: Double) -> ReadingObservation {
        ReadingObservation(
            locator: .object(["href": .string(href), "locations": .object(["progression": .number(from)])]),
            viewport: ReadingViewport(resources: [.init(href: href, progression: from ... to)])
        )
    }

    func testAHeardPlaceIsRestoredOnlyWhenItsElementIsOnScreen() {
        XCTAssertTrue(ReadingRestoration.isElementTarget(target))
        var restoring = ReadingRestoration(opening: target)
        // The chapter's first page: its document, but is the element there?
        let first = report("OEBPS/c1.xhtml", 0, 0.2)
        XCTAssertEqual(restoring.observe(first), .confirm(target: target))
        XCTAssertEqual(restoring.elementShown(false, for: first), .correct(target: target, attempt: 1), "sent to the element, input off")
        XCTAssertTrue(restoring.isCorrecting)
        // The jump lands; that page is checked too.
        let landed = report("OEBPS/c1.xhtml", 0.4, 0.6)
        XCTAssertEqual(restoring.observe(landed), .confirm(target: target))
        XCTAssertTrue(restoring.isCorrecting, "input stays off while checking")
        XCTAssertEqual(restoring.elementShown(true, for: first), .none, "an answer about an older report changes nothing")
        XCTAssertEqual(restoring.elementShown(true, for: landed), .settled)
        XCTAssertEqual(restoring.observe(landed), .none, "the same page again is not reading")
        XCTAssertEqual(restoring.observe(report("OEBPS/c1.xhtml", 0.6, 0.8)), .record, "a real turn afterwards is")
    }

    func testAnotherDocumentIsCorrectedWithoutAsking() {
        var restoring = ReadingRestoration(opening: target)
        XCTAssertEqual(restoring.observe(report("OEBPS/c0.xhtml", 0, 0.1)), .correct(target: target, attempt: 1))
        XCTAssertEqual(restoring.observe(report("OEBPS/c0.xhtml", 0, 0.1)), .none)
        XCTAssertEqual(restoring.timedOut(attempt: 1), .correct(target: target, attempt: 2))
        let shown = report("OEBPS/c1.xhtml", 0.4, 0.6)
        XCTAssertEqual(restoring.observe(shown), .confirm(target: target))
        // No answer in time: the retry's timeout gives up, input on, nothing saved.
        XCTAssertEqual(restoring.timedOut(attempt: 2), .gaveUp)
        XCTAssertFalse(restoring.isCorrecting)
        XCTAssertEqual(restoring.elementShown(true, for: shown), .none, "a late answer after giving up changes nothing")
    }

    func testAnOrdinaryPlaceIsUnaffected() {
        let reading: JSONValue = .object(["href": .string("OEBPS/c1.xhtml"), "locations": .object(["fragments": .array([.string("p4")]), "progression": .number(0.5)])])
        XCTAssertFalse(ReadingRestoration.isElementTarget(reading), "a progression is checked as before")
        var restoring = ReadingRestoration(opening: reading)
        XCTAssertEqual(restoring.observe(report("OEBPS/c1.xhtml", 0.4, 0.6)), .settled)
        XCTAssertFalse(ReadingRestoration.isElementTarget(.object(["href": .string("doc.pdf"), "locations": .object(["fragments": .array([.string("page=3")])])])))
    }
}
