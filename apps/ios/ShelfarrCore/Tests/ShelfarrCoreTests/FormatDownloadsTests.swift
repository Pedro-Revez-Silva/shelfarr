import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShelfarrCore
import XCTest

/// PDF and comic downloads through the same manager, executor and events as EPUB.
final class FormatDownloadsTests: DownloadTestCase {
    private let router = TransferRouter()
    private lazy var executor = InProcessDownloadExecutor(transport: transport, router: router, scratch: root.appendingPathComponent("scratch"))
    private let pdfBytes = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 3_000)
    private let comic = ZipBuilder.comic()
    private lazy var archive = comic.build().data
    private let orderPath = "/library/comic/assets/c1/reading_order"

    private lazy var twoFormats = Publication(id: "book", title: "Book", bookType: .ebook, assets: [
        Asset(id: "e1", filename: "b.epub", mediaType: "application/epub+zip", format: "epub", sizeBytes: Int64(epub.count), contentUrl: "/files/e1"),
        Asset(id: "p1", filename: "b.pdf", mediaType: "application/pdf", format: "pdf", sizeBytes: Int64(pdfBytes.count), contentUrl: "/files/p1", position: 1),
    ], contentKind: "book")

    private func comicBook(orderURL: String? = nil) -> Publication {
        Publication(id: "comic", title: "Comic", bookType: .ebook, assets: [
            Asset(id: "c1", filename: "Issue 1.cbz", mediaType: "application/vnd.comicbook+zip", format: "cbz", sizeBytes: Int64(archive.count),
                  contentUrl: "/files/c1", pageCount: 3, readingOrderUrl: orderURL ?? orderPath),
        ], contentKind: "graphic")
    }

    override func setUp() {
        super.setUp()
        transport["/files/p1"] = .init(data: pdfBytes, etag: "\"p1\"")
        transport["/files/c1"] = .init(data: archive, etag: "\"c1\"")
        transport[orderPath] = .init(data: try! JSONEncoder().encode(comic.order(assetId: "c1")), etag: "\"o1\"")
        publications["comic"] = comicBook()
    }

    private func manager(_ folder: String = "acct") -> DownloadManager {
        manager(folder, executors: DownloadExecutors(foreground: executor), router: router)
    }

    private func gets(_ path: String) -> Int {
        transport.contentRequests.filter { $0.url?.path == path }.count
    }

    private func manifestURL(_ folder: String = "acct") -> URL { downloadsRoot(folder).appendingPathComponent("manifest.json") }

    func testAnEPUBDownloadedBeforeFormatsStaysValidWhenTheServerAddsAPDF() async throws {
        let first = manager()
        await first.start()
        await first.enqueue(book)
        _ = try await wait(first, "book", [.ready])
        await first.close()
        // Rewrite the manifest as a version without formats wrote it.
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL())) as? [String: Any])
        var records = try XCTUnwrap(manifest["records"] as? [String: [String: Any]])
        XCTAssertEqual(records["book"]?["format"] as? String, "epub")
        records["book"]?.removeValue(forKey: "format")
        manifest["records"] = records
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL())
        let before = gets("/files/e1")

        publications["book"] = twoFormats
        let downloads = manager()
        await downloads.start()
        let readyLegacy = await downloads.ready("book")
        let legacy = try XCTUnwrap(readyLegacy)
        XCTAssertNil(legacy.format)
        XCTAssertEqual(legacy.readerFormat, .epub, "worked out from the pinned file")
        XCTAssertTrue(legacy.matches(twoFormats), "another format on the server isn't a new edition")
        await downloads.enqueue(twoFormats)
        let again = try await wait(downloads, "book", [.ready])
        XCTAssertEqual(again.pinnedAssetIds, ["e1"])
        XCTAssertEqual(gets("/files/e1"), before, "nothing was fetched again")
        XCTAssertEqual(gets("/files/p1"), 0)
        let kept = await downloads.fileURL(again, assetId: "e1")
        XCTAssertNotNil(kept)
    }

    func testDownloadingAnotherFormatIsAnExplicitChoiceAndChecked() async throws {
        publications["book"] = twoFormats
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(twoFormats, format: .pdf)
        let record = try await wait(downloads, "book", [.ready, .failed])
        XCTAssertEqual(record.state, .ready)
        XCTAssertEqual(record.format, "pdf")
        XCTAssertEqual(record.pinnedAssetIds, ["p1"])
        XCTAssertEqual(gets("/files/e1"), 0, "only the chosen format is downloaded")
        let pdfFile = await downloads.fileURL(record, assetId: "p1")
        let file = try XCTUnwrap(pdfFile)
        XCTAssertEqual(try Data(contentsOf: file), pdfBytes)
        XCTAssertTrue(record.matches(twoFormats))

        // Retrying keeps the format.
        await downloads.remove("book")
        transport["/files/p1"] = .init(data: Data("<html>login</html>".utf8) + Data(repeating: 0x20, count: pdfBytes.count - 18), etag: "\"p1\"")
        await downloads.enqueue(twoFormats, format: .pdf)
        let refused = try await wait(downloads, "book", [.ready, .failed])
        XCTAssertEqual(refused.state, .failed, "bytes without a PDF header are never ready")
        XCTAssertEqual(refused.problem, .invalid)
        transport["/files/p1"] = .init(data: pdfBytes, etag: "\"p1\"")
        await downloads.retry("book")
        let retried = try await wait(downloads, "book", [.ready, .failed])
        XCTAssertEqual(retried.state, .ready)
        XCTAssertEqual(retried.pinnedAssetIds, ["p1"])
    }

    func testAComicIsReadyOnlyWithItsVerifiedPageOrderKeptBesideIt() async throws {
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(comicBook())
        let record = try await wait(downloads, "comic", [.ready, .failed])
        XCTAssertEqual(record.state, .ready, "\(String(describing: record.problem))")
        XCTAssertEqual(record.format, "cbz")
        let storedOrder = await downloads.readingOrder(record, assetId: "c1")
        XCTAssertEqual(storedOrder, comic.order(assetId: "c1"))
        let orderRequest = try XCTUnwrap(transport.contentRequests.first { $0.url?.path == orderPath })
        XCTAssertEqual(orderRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let comicFile = await downloads.fileURL(record, assetId: "c1")
        let file = try XCTUnwrap(comicFile)
        let orderForReading = await downloads.readingOrder(record, assetId: "c1")
        let opened = try ComicArchive.open(file, order: XCTUnwrap(orderForReading))
        XCTAssertEqual(try opened.page(2), DeflateVectors.png)
        opened.close()
        await downloads.close()

        // A restart keeps it ready; without its order it is missing, and trying again
        // fetches only the order.
        let restarted = manager()
        await restarted.start()
        let stillReady = await restarted.ready("comic")
        XCTAssertNotNil(stillReady)
        await restarted.close()
        let orderFile = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".order.json")
        try FileManager.default.removeItem(at: orderFile)
        let archiveGets = gets("/files/c1")
        let missing = manager()
        await missing.start()
        let afterLoss = await missing.record("comic")
        let stopped = try XCTUnwrap(afterLoss)
        XCTAssertEqual(stopped.state, .failed)
        XCTAssertEqual(stopped.problem, .missing)
        let readyWithoutOrder = await missing.ready("comic")
        XCTAssertNil(readyWithoutOrder)
        await missing.retry("comic")
        let recovered = try await wait(missing, "comic", [.ready, .failed])
        XCTAssertEqual(recovered.state, .ready)
        XCTAssertEqual(gets("/files/c1"), archiveGets, "the archive's bytes were kept")
        let refetchedOrder = await missing.readingOrder(recovered, assetId: "c1")
        XCTAssertNotNil(refetchedOrder)
    }

    func testAnOrderThatDoesntDescribeTheArchiveIsNeverReady() async throws {
        var wrong = comic.order(assetId: "c1")
        let item = wrong.items[0]
        wrong = ReadingOrder(assetId: "c1", items: [ReadingOrder.Item(position: 1, href: item.href, mediaType: item.mediaType, sizeBytes: item.sizeBytes, compressedSize: item.compressedSize, compressionMethod: item.compressionMethod, localHeaderOffset: item.localHeaderOffset, crc32: "00000000")] + wrong.items.dropFirst())
        transport[orderPath] = .init(data: try JSONEncoder().encode(wrong), etag: "\"o2\"")
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(comicBook())
        let record = try await wait(downloads, "comic", [.ready, .failed])
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.problem, .invalid)
        XCTAssertFalse(record.files.contains(where: \.complete))
        let readyAfterMismatch = await downloads.ready("comic")
        XCTAssertNil(readyAfterMismatch)
    }

    func testAReplacedComicStopsAsChanged() async throws {
        transport[orderPath] = .init(data: Data(), etag: "", status: 410)
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(comicBook())
        let record = try await wait(downloads, "comic", [.ready, .failed])
        XCTAssertEqual(record.problem, .changed)
        XCTAssertEqual(gets("/files/c1"), 0, "no byte of the old generation was fetched")
    }

    func testAnOversizedOrForeignOrderIsRefused() async throws {
        transport[orderPath] = .init(data: Data(repeating: 0x20, count: Int(ReadingOrder.maxBytes) + 10), etag: "\"big\"")
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(comicBook())
        let record = try await wait(downloads, "comic", [.ready, .failed])
        XCTAssertEqual(record.problem, .invalid)

        await downloads.remove("comic")
        let foreign = comicBook(orderURL: "https://elsewhere.example/library/comic/assets/c1/reading_order")
        publications["comic"] = foreign
        let other = manager("other")
        await other.start()
        await other.enqueue(foreign)
        let refused = try await wait(other, "comic", [.ready, .failed])
        XCTAssertEqual(refused.problem, .unsupported)
        XCTAssertFalse(transport.allRequests.contains { $0.url?.host == "elsewhere.example" }, "the token never leaves the server")
    }

    func testWithoutAFormatAComicDownloadsItsPages() async throws {
        let both = Publication(id: "comic", title: "Comic", bookType: .ebook, assets: [
            Asset(id: "p1", filename: "b.pdf", mediaType: "application/pdf", format: "pdf", sizeBytes: Int64(pdfBytes.count), contentUrl: "/files/p1"),
            comicBook().assets[0],
        ], contentKind: "graphic")
        publications["comic"] = both
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(both)
        let record = try await wait(downloads, "comic", [.ready, .failed])
        XCTAssertEqual(record.state, .ready)
        XCTAssertEqual(record.format, "cbz", "a comic suggests its pages, never a missing EPUB")
    }

    func testAnEditionUpdateKeepsTheDownloadsFormat() async throws {
        publications["book"] = twoFormats
        let downloads = manager()
        await downloads.start()
        await downloads.enqueue(twoFormats, format: .pdf)
        _ = try await wait(downloads, "book", [.ready])
        let replaced = Publication(id: "book", title: "Book", bookType: .ebook, assets: [
            twoFormats.assets[0],
            Asset(id: "p2", filename: "b.pdf", mediaType: "application/pdf", format: "pdf", sizeBytes: Int64(pdfBytes.count), contentUrl: "/files/p1", position: 1),
        ])
        publications["book"] = replaced
        await downloads.close()
        let later = manager()
        await later.start()
        let current = await later.record("book")
        let stale = try XCTUnwrap(current)
        XCTAssertFalse(stale.matches(replaced))
        await later.enqueue(replaced)
        let updated = try await wait(later, "book", [.ready, .failed])
        XCTAssertEqual(updated.state, .ready)
        XCTAssertEqual(updated.pinnedAssetIds, ["p2"], "still the PDF, now the new file")
    }
}

final class FormatCacheTests: XCTestCase {
    private let transport = FileServer()
    private var root: URL!
    private var cache: EpubCache!
    private let comic = ZipBuilder.comic()

    private var server: ServerAddress {
        guard case let .valid(address) = ServerAddress.parse("https://example.org") else { fatalError() }
        return address
    }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = self.server
        let api = ConsumerAPI(transport: transport, credential: { Credential(server: server, accessToken: "secret") })
        cache = EpubCache(root: root, transport: transport, authorize: { api.authorized($0) })
        transport["/files/c1"] = .init(data: comic.build().data, etag: "\"c1\"")
        transport["/order/c1"] = .init(data: try! JSONEncoder().encode(comic.order(assetId: "c1")), etag: "\"o\"")
        transport["/files/p1"] = .init(data: Data("%PDF-1.4 tiny".utf8), etag: "\"p1\"")
        transport["/files/e1"] = .init(data: Data("PK-epub".utf8), etag: "\"e1\"")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var comicAsset: Asset {
        Asset(id: "c1", format: "cbz", sizeBytes: Int64(comic.build().data.count), contentUrl: "/files/c1", readingOrderUrl: "/order/c1")
    }

    func testEachFormatKeepsItsOwnFileNameAndEPUBsKeepTheirs() async throws {
        let epub = try await cache.obtain(accountKey: "acct", server: server, asset: Asset(id: "e1", format: "epub", sizeBytes: 7, contentUrl: "/files/e1"))
        XCTAssertEqual(epub.file.lastPathComponent, "book.epub")
        let pdf = try await cache.obtain(accountKey: "acct", server: server, asset: Asset(id: "p1", mediaType: "application/pdf", format: "pdf", sizeBytes: 13, contentUrl: "/files/p1"))
        XCTAssertEqual(pdf.file.lastPathComponent, "book.pdf")
        XCTAssertNil(pdf.readingOrder)
        transport["/files/p2"] = .init(data: Data("not a pdf at all".utf8), etag: "\"p2\"")
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: Asset(id: "p2", format: "pdf", sizeBytes: 16, contentUrl: "/files/p2"))
            XCTFail("a file without a PDF header is refused")
        } catch let error as APIError {
            XCTAssertEqual(error, .protocolError)
        }
    }

    func testAComicCopyHasItsCheckedOrderAndOpensOffline() async throws {
        let copy = try await cache.obtain(accountKey: "acct", server: server, asset: comicAsset)
        XCTAssertEqual(copy.file.lastPathComponent, "book.cbz")
        XCTAssertEqual(copy.readingOrder, comic.order(assetId: "c1"))
        let copied = await cache.hasCopy(accountKey: "acct", asset: comicAsset)
        XCTAssertTrue(copied)
        let otherAccount = await cache.hasCopy(accountKey: "other", asset: comicAsset)
        XCTAssertFalse(otherAccount, "per account")

        transport["/files/c1"]?.failure = .offline(certificate: false)
        let offline = try await cache.obtain(accountKey: "acct", server: server, asset: comicAsset)
        XCTAssertTrue(offline.unverified)
        XCTAssertEqual(offline.readingOrder, comic.order(assetId: "c1"))

        try FileManager.default.removeItem(at: copy.file.deletingLastPathComponent().appendingPathComponent("book.order.json"))
        let withoutOrder = await cache.hasCopy(accountKey: "acct", asset: comicAsset)
        XCTAssertFalse(withoutOrder)
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: comicAsset)
            XCTFail("a comic without its order can't open offline")
        } catch let error as APIError {
            XCTAssertEqual(error, .offline(certificate: false))
        }
    }

    func testAComicWhoseOrderDisagreesIsNotKept() async throws {
        var order = comic.order(assetId: "c1")
        order = ReadingOrder(assetId: "c1", items: Array(order.items.prefix(2)))
        transport["/order/c1"] = .init(data: try JSONEncoder().encode(order), etag: "\"o\"")
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: comicAsset)
            XCTFail("an order missing a page is refused")
        } catch let error as APIError {
            XCTAssertEqual(error, .protocolError)
        }
        let keptAfterMismatch = await cache.hasCopy(accountKey: "acct", asset: comicAsset)
        XCTAssertFalse(keptAfterMismatch)
        transport["/order/c1"] = .init(data: Data(), etag: "", status: 410)
        do {
            _ = try await cache.obtain(accountKey: "acct", server: server, asset: comicAsset)
            XCTFail("a replaced generation is gone")
        } catch let error as APIError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
