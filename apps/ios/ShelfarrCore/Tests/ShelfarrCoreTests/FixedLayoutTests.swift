import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// Publications as the server serializes them for a client that declares reader formats.
enum FormatFixtures {
    static let epub = Asset(id: "e1", filename: "b.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: 100, contentUrl: "/files/e1", position: 0)
    static let pdf = Asset(id: "p1", filename: "b.pdf", mediaType: "application/pdf", format: "pdf", sizeBytes: 100, contentUrl: "/files/p1", position: 1)
    static let cbz = Asset(id: "c1", filename: "b.cbz", mediaType: "application/vnd.comicbook+zip", format: "cbz", sizeBytes: 100, contentUrl: "/files/c1", position: 2, pageCount: 3, readingOrderUrl: "/library/x/assets/c1/reading_order")

    static func book(_ assets: [Asset], kind: String? = "book", progress: ReadingProgress? = nil) -> Publication {
        Publication(id: "x", title: "X", bookType: .ebook, assets: assets, progress: progress, contentKind: kind)
    }
}

final class FormatModelTests: XCTestCase {
    func testDecodesTheOptionalFormatFieldsAndKeepsThemOffline() throws {
        let json = """
        {"id":"42","title":"Issue 1","book_type":"ebook","content_kind":"graphic","assets":[
          {"id":"g1","filename":"Issue 1.cbz","format":"cbz","media_type":"application/vnd.comicbook+zip","size_bytes":4821,
           "position":0,"content_url":"/api/consumer/v1/library/42/assets/g1","page_count":24,
           "reading_order_url":"/api/consumer/v1/library/42/assets/g1/reading_order"}]}
        """
        let publication = try JSONDecoder().decode(Publication.self, from: Data(json.utf8))
        XCTAssertEqual(publication.bookType, .ebook, "a comic is still an ebook")
        XCTAssertTrue(publication.isGraphic)
        XCTAssertEqual(publication.assets.first?.pageCount, 24)
        XCTAssertEqual(publication.readerFormats, [.cbz])
        // The offline caches store publications as JSON: the new fields survive.
        let again = try JSONDecoder().decode(Publication.self, from: JSONEncoder().encode(publication))
        XCTAssertEqual(again, publication)
        XCTAssertEqual(again.assets.first?.readingOrderUrl, "/api/consumer/v1/library/42/assets/g1/reading_order")
    }

    func testOldResponsesAndMalformedOptionalFieldsStillDecode() throws {
        let old = #"{"id":"1","title":"T","book_type":"ebook","assets":[{"id":"e","format":"epub","content_url":"/c"}]}"#
        let publication = try JSONDecoder().decode(Publication.self, from: Data(old.utf8))
        XCTAssertNil(publication.contentKind)
        XCTAssertEqual(publication.playableAssets.map(\.id), ["e"], "an EPUB-only book resolves exactly as before")
        let odd = #"{"id":"1","title":"T","book_type":"ebook","content_kind":7,"assets":[{"id":"c","format":"cbz","content_url":"/c","page_count":"many","reading_order_url":5}]}"#
        let tolerant = try JSONDecoder().decode(Publication.self, from: Data(odd.utf8))
        XCTAssertNil(tolerant.contentKind)
        XCTAssertNil(tolerant.assets[0].pageCount)
        XCTAssertTrue(tolerant.readerFormats.isEmpty, "a CBZ without a reading order isn't offered")
    }

    func testOneReadableFileIsPickedPerFormatWithinTheCaps() {
        let second = Asset(id: "e2", format: "epub", sizeBytes: 1, contentUrl: "/files/e2", position: 5)
        let hugePDF = Asset(id: "p2", mediaType: "application/pdf", format: "pdf", sizeBytes: ReaderFormat.maxPDFBytes + 1, contentUrl: "/files/p2", position: 0)
        let audio = Asset(id: "a", mediaType: "audio/mpeg", format: "mp3", contentUrl: "/files/a")
        let book = FormatFixtures.book([second, FormatFixtures.epub, hugePDF, FormatFixtures.cbz, audio])
        XCTAssertEqual(book.readableAssets.map(\.id), ["e1", "c1"], "first of each, oversized PDFs skipped, audio never read")
        XCTAssertEqual(book.downloadableAssets(format: .cbz).map(\.id), ["c1"])
        XCTAssertEqual(book.downloadableAssets(format: .pdf).map(\.id), [])
        let audiobook = Publication(id: "a", title: "A", bookType: .audiobook, assets: [audio, FormatFixtures.pdf])
        XCTAssertTrue(audiobook.readableAssets.isEmpty)
        XCTAssertEqual(audiobook.downloadableAssets(format: nil).map(\.id), ["a"])
    }

    func testWholeNumbersEncodeAsJSONIntegers() throws {
        let locator = PageLocator.pdf(page: 12, pageCount: 34)
        let json = try XCTUnwrap(locator.jsonString())
        XCTAssertTrue(json.contains(#""position":12"#), json)
        XCTAssertFalse(json.contains("12.0"), json)
        XCTAssertEqual(JSONValue.number(0.5).jsonString(), "0.5")
    }

    func testServerFactsListReaderFormatsWhenPresent() throws {
        let facts = try JSONDecoder().decode(ServerFacts.self, from: Data(#"{"consumer_features":["requests"],"reader_formats":["cbz","epub","pdf"]}"#.utf8))
        XCTAssertEqual(facts.readerFormats, ["cbz", "epub", "pdf"])
        XCTAssertNil(try JSONDecoder().decode(ServerFacts.self, from: Data("{}".utf8)).readerFormats)
    }
}

final class PageLocatorTests: XCTestCase {
    func testPDFPlacesMatchTheContract() throws {
        let place = PageLocator.pdf(page: 12, pageCount: 33)
        XCTAssertEqual(place.jsonString(), #"{"href":"document.pdf","locations":{"fragments":["page=12"],"position":12,"totalProgression":0.3333333333333333},"type":"application\/pdf"}"#)
        XCTAssertEqual(PageLocator.pdfPage(place, pageCount: 33), 12)
        XCTAssertEqual(PageLocator.pdf(page: 1, pageCount: 1)["locations"]?["totalProgression"], .number(0))
    }

    func testPDFPlacesThisFileCantShowAreNotRestored() {
        func place(_ locations: [String: JSONValue], href: String = "document.pdf", extra: [String: JSONValue] = [:]) -> JSONValue {
            .object(["href": .string(href), "type": .string("application/pdf"), "locations": .object(locations)].merging(extra) { $1 })
        }
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(40)]), pageCount: 33), "past the end")
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(2.5)]), pageCount: 33), "not a page")
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(0)]), pageCount: 33))
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(3), "cfi": .string("/4/2")]), pageCount: 33), "a text position")
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(3), "fragments": .array([.string("page=4")])]), pageCount: 33))
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(3)], href: "OEBPS/c1.xhtml"), pageCount: 33), "another file's place")
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(3)], extra: ["otherLocations": .object([:])]), pageCount: 33))
        XCTAssertNil(PageLocator.pdfPage(place(["position": .number(3), "progression": .number(2)]), pageCount: 33))
        XCTAssertNil(PageLocator.pdfPage(nil, pageCount: 33))
        XCTAssertEqual(PageLocator.pdfPage(place(["position": .number(3)]), pageCount: 33), 3, "fragments and fractions are optional")
    }

    func testComicPlacesNameExactlyOnePageOfThisOrder() throws {
        let order = ZipBuilder.comic().order()
        let place = try XCTUnwrap(PageLocator.comic(page: 3, order: order))
        XCTAssertEqual(place.jsonString(), #"{"href":"Issue%201\/page%2010.jpg","locations":{"position":3,"totalProgression":0.6666666666666666},"type":"image\/jpeg"}"#)
        XCTAssertEqual(PageLocator.comicPage(place, order: order), 3)
        XCTAssertNil(PageLocator.comic(page: 4, order: order))

        let shifted: JSONValue = .object(["href": .string(order.items[1].href), "type": .string("image/png"), "locations": .object(["position": .number(3)])])
        XCTAssertNil(PageLocator.comicPage(shifted, order: order), "an href that isn't item N")
        let fragment: JSONValue = .object(["href": .string(order.items[0].href), "type": .string("image/png"), "locations": .object(["position": .number(1), "fragments": .array([.string("page=1")])])])
        XCTAssertNil(PageLocator.comicPage(fragment, order: order), "comic places have no fragments")
        XCTAssertNil(PageLocator.comicPage(PageLocator.pdf(page: 1, pageCount: 3), order: order), "a PDF place")
    }
}

final class PageRestorationTests: XCTestCase {
    func testOpeningSettlesWithoutRecordingAndOnlyNewPagesAreTurns() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertTrue(restoration.isRestoring)
        XCTAssertEqual(restoration.observe(5), .settled)
        XCTAssertEqual(restoration.observe(5), .none, "a re-layout of the same page (rotation, zoom, spread change)")
        XCTAssertEqual(restoration.observe(6), .record(6))
        XCTAssertEqual(restoration.observe(6), .none)
        XCTAssertEqual(restoration.observe(4), .record(4))
    }

    func testAWrongFirstReportIsCorrectedThenGivenUpOn() {
        var restoration = PageRestoration(opening: 9)
        XCTAssertEqual(restoration.observe(1), .correct(9), "the view laid out page one first")
        XCTAssertEqual(restoration.observe(1), .correct(9))
        XCTAssertEqual(restoration.observe(1), .gaveUp)
        XCTAssertEqual(restoration.observe(1), .none, "giving up records nothing")
        XCTAssertEqual(restoration.observe(2), .none, "nor does the view moving on its own")
        XCTAssertTrue(restoration.readerNavigates())
        XCTAssertEqual(restoration.anchor, 9, "page 9 stays the saved place")
        XCTAssertEqual(restoration.observe(3), .record(3), "the reader turning does")
    }

    func testASpreadKeepsTheAnchorUntilTheReaderTurnsAway() {
        var restoration = PageRestoration(opening: 5)
        XCTAssertEqual(restoration.observe(4 ... 5), .settled, "page 5 is the right half of a spread")
        XCTAssertEqual(restoration.anchor, 5)
        XCTAssertEqual(restoration.observe(5), .none, "back to one page: still page 5")
        XCTAssertEqual(restoration.observe(4 ... 5), .none, "and two again")
        XCTAssertEqual(restoration.observe(6 ... 7), .record(6))
        XCTAssertEqual(restoration.observe(6), .none, "a narrower layout shows the page being read")
        XCTAssertEqual(restoration.observe(7), .record(7), "showing another page alone is a turn")
        XCTAssertEqual(restoration.observe(4 ... 5), .record(4))
    }

    func testAnOpeningPageThatCantDisplayIsGivenUpOnWithoutRecording() {
        var restoration = PageRestoration(opening: 4)
        XCTAssertEqual(restoration.couldNotShow(3), .none, "another page")
        XCTAssertEqual(restoration.couldNotShow(4), .gaveUp)
        XCTAssertEqual(restoration.couldNotShow(4), .none, "given up once")
        XCTAssertTrue(restoration.stalled)
        XCTAssertNil(restoration.anchor, "nothing was shown, so nothing new is anchored or saved")
        XCTAssertTrue(restoration.readerNavigates(), "the reader turns past it")
        XCTAssertEqual(restoration.observe(5), .record(5), "the next page they reach that displays is a turn")
    }

    func testGoingToAnotherDevicesPlaceIsNotReading() {
        var restoration = PageRestoration(opening: 2)
        _ = restoration.observe(2)
        XCTAssertEqual(restoration.reopen(at: 7), .correct(7))
        XCTAssertEqual(restoration.observe(7), .settled)
        XCTAssertEqual(restoration.observe(8), .record(8))
    }
}

final class PageSpreadsTests: XCTestCase {
    func testTheCoverStandsAloneThenPagesPair() {
        XCTAssertEqual(PageSpreads.layout(pageCount: 6, paired: true), [1 ... 1, 2 ... 3, 4 ... 5, 6 ... 6])
        XCTAssertEqual(PageSpreads.layout(pageCount: 3, paired: false), [1 ... 1, 2 ... 2, 3 ... 3])
        XCTAssertEqual(PageSpreads.layout(pageCount: 1, paired: true), [1 ... 1])
        XCTAssertEqual(PageSpreads.layout(pageCount: 0, paired: true), [])
        let spreads = PageSpreads.layout(pageCount: 6, paired: true)
        XCTAssertEqual(PageSpreads.index(of: 5, in: spreads), 2)
        XCTAssertEqual(PageSpreads.index(of: 1, in: spreads), 0)
        XCTAssertEqual(PageSpreads.index(of: 99, in: spreads), 3)
    }
}

final class FormatDecisionTests: XCTestCase {
    private func place(_ assetId: String) -> ReadingProgress {
        ReadingProgress(assetId: assetId, locator: PageLocator.pdf(page: 2, pageCount: 3), version: 1)
    }

    func testASavedPlaceKeepsItsFormat() {
        let book = FormatFixtures.book([FormatFixtures.epub, FormatFixtures.pdf])
        XCTAssertEqual(FormatDecision.decide(publication: book, placeAssetId: "p1", readyDownload: .epub, local: [.epub], offline: false), .open(.pdf))
    }

    func testThenADownloadThenTheOnlyFormatThenAsk() {
        let both = FormatFixtures.book([FormatFixtures.epub, FormatFixtures.pdf])
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: nil, readyDownload: .pdf, local: [.pdf], offline: false), .open(.pdf))
        XCTAssertEqual(FormatDecision.decide(publication: FormatFixtures.book([FormatFixtures.pdf]), placeAssetId: nil, readyDownload: nil, local: [], offline: false), .open(.pdf))
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: nil, readyDownload: nil, local: [], offline: false), .ask([.epub, .pdf]))
        let comic = FormatFixtures.book([FormatFixtures.pdf, FormatFixtures.cbz], kind: "graphic")
        XCTAssertEqual(FormatDecision.decide(publication: comic, placeAssetId: nil, readyDownload: nil, local: [], offline: false), .ask([.cbz, .pdf]), "comics suggest their pages first")
        XCTAssertNil(FormatDecision.decide(publication: FormatFixtures.book([]), placeAssetId: nil, readyDownload: nil, local: [], offline: false))
    }

    func testAPlaceOnAFileThisEditionLacksDoesntChooseAFormat() {
        let both = FormatFixtures.book([FormatFixtures.epub, FormatFixtures.pdf])
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: "gone", readyDownload: nil, local: [], offline: false), .ask([.epub, .pdf]))
    }

    func testOfflineOffersTheFormatsOnThisDevice() {
        let both = FormatFixtures.book([FormatFixtures.epub, FormatFixtures.pdf, FormatFixtures.cbz])
        XCTAssertEqual(
            FormatDecision.decide(publication: both, placeAssetId: "p1", readyDownload: .epub, local: [.epub, .cbz], offline: true),
            .savedFormatUnavailable(saved: .pdf, alternatives: [.epub, .cbz])
        )
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: "p1", readyDownload: nil, local: [.pdf], offline: true), .open(.pdf))
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: "p1", readyDownload: nil, local: [], offline: true), .open(.pdf), "nothing else to offer: try the saved format")
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: nil, readyDownload: nil, local: [.cbz], offline: true), .open(.cbz))
        XCTAssertEqual(FormatDecision.decide(publication: both, placeAssetId: nil, readyDownload: nil, local: [.cbz, .pdf], offline: true), .ask([.pdf, .cbz]))
    }

    func testResumeDecisionsAcceptPlacesInAnyReadableFormat() {
        let saved = ReadingProgress(assetId: "c1", locator: PageLocator.pdf(page: 2, pageCount: 3), version: 4, observedAt: "2026-11-08T10:00:00Z")
        let book = FormatFixtures.book([FormatFixtures.epub, FormatFixtures.cbz], progress: saved)
        guard case let .resume(position, base, _) = ResumeDecision.decide(publication: book, server: saved, local: nil) else {
            return XCTFail("a comic place resumes")
        }
        XCTAssertEqual(position.assetId, "c1")
        XCTAssertEqual(base, 4)
        let epubOnly = FormatFixtures.book([FormatFixtures.epub], progress: saved)
        XCTAssertEqual(ResumeDecision.decide(publication: epubOnly, server: saved, local: nil), .editionChanged(staleVersion: 4))
    }

    func testPDFSniffing() {
        XCTAssertTrue(PDFSniff.hasHeader(Data("%PDF-1.7\n".utf8)))
        XCTAssertTrue(PDFSniff.hasHeader(Data(repeating: 0x20, count: 500) + Data("%PDF-2.0".utf8)), "within the first KiB")
        XCTAssertFalse(PDFSniff.hasHeader(Data(repeating: 0x20, count: 1020) + Data("%PDF-1.4".utf8)))
        XCTAssertFalse(PDFSniff.hasHeader(Data("PK\u{3}\u{4}".utf8)))
        XCTAssertFalse(PDFSniff.hasHeader(Data("%PDF-x".utf8)))
    }
}

final class ReaderFormatsAPITests: XCTestCase {
    private let transport = FakeTransport()

    private var server: ServerAddress {
        guard case let .valid(address) = ServerAddress.parse("https://example.org") else { fatalError() }
        return address
    }

    private var api: ConsumerAPI {
        let server = self.server
        return ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "token") })
    }

    func testDeclaresFormatsOnlyOnLibraryDetailsContinueAndStatus() async throws {
        let item = #"{"id":"p","title":"T","book_type":"ebook"}"#
        transport.enqueue(200, #"{"items":[],"next_cursor":null}"#)
        _ = try await api.library(server: server, query: LibraryQuery())
        transport.enqueue(200, item)
        _ = try await api.publication(server: server, id: "p")
        transport.enqueue(200, #"{"items":[]}"#)
        _ = try await api.continueReading(server: server)
        transport.enqueue(200, item)
        _ = try await api.setReadingStatus(server: server, publicationId: "p", status: .finished)
        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Shelfarr-Reader-Formats"), "epub,pdf,cbz", request.url?.path ?? "")
        }
        let declared = transport.requests.count

        transport.enqueue(200, #"{"id":"u"}"#)
        _ = try await api.me(server: server)
        transport.enqueue(200, #"{"progress":{"asset_id":"a","version":1}}"#)
        _ = try await api.saveProgress(server: server, publicationId: "p", update: ProgressUpdate(assetId: "a", locator: nil, positionSeconds: 1, expectedVersion: 0, clientMutationId: "m"))
        transport.enqueue(200, "{}")
        _ = try await api.serverFacts(server: server)
        for request in transport.requests.dropFirst(declared) {
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Shelfarr-Reader-Formats"), request.url?.path ?? "")
        }
        XCTAssertNil(api.authorized(server.api("library")).value(forHTTPHeaderField: "X-Shelfarr-Reader-Formats"), "asset and progress requests don't need it")
    }

    func testAReplayedRequestStillDeclaresItsFormats() async throws {
        final class Box: @unchecked Sendable { var token = "old" }
        let box = Box()
        let server = self.server
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: box.token) }, replaysAfterHandover: true)
        transport.beforeResponse = { box.token = "new" }
        transport.enqueue(401, #"{"error":"invalid_token"}"#)
        transport.enqueue(200, #"{"id":"p","title":"T","book_type":"ebook"}"#)
        _ = try await api.publication(server: server, id: "p")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "X-Shelfarr-Reader-Formats"), "epub,pdf,cbz")
    }
}
