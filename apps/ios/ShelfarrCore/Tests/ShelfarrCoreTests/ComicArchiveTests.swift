import Foundation
@testable import ShelfarrCore
import XCTest

final class InflateTests: XCTestCase {
    func testDecodesZlibDynamicAndFixedCodes() throws {
        XCTAssertEqual(try Inflate.decode(DeflateVectors.data(DeflateVectors.text9), expectedSize: DeflateVectors.text.count), DeflateVectors.text)
        XCTAssertEqual(try Inflate.decode(DeflateVectors.data(DeflateVectors.textFixed), expectedSize: DeflateVectors.text.count), DeflateVectors.text)
        XCTAssertEqual(try Inflate.decode(DeflateVectors.data(DeflateVectors.png9), expectedSize: DeflateVectors.png.count), DeflateVectors.png)
        XCTAssertEqual(try Inflate.decode(DeflateVectors.data(DeflateVectors.abc), expectedSize: 3), Data("abc".utf8))
        XCTAssertEqual(try Inflate.decode(DeflateVectors.data(DeflateVectors.empty), expectedSize: 0), Data())
        XCTAssertEqual(CRC32.checksum(DeflateVectors.text), DeflateVectors.text9CRC)
        XCTAssertEqual(CRC32.checksum(DeflateVectors.png), DeflateVectors.png9CRC)
    }

    func testDecodesStoredBlocksAcrossTheirSizeLimit() throws {
        let noise = DeflateVectors.noise(150_000)
        XCTAssertEqual(try Inflate.decode(DeflateVectors.stored(noise), expectedSize: noise.count), noise)
        XCTAssertEqual(try Inflate.decode(DeflateVectors.stored(noise, blockSize: 7), expectedSize: noise.count), noise)
    }

    func testRefusesOutputBeyondOrShortOfTheDeclaredSize() {
        let stream = DeflateVectors.data(DeflateVectors.text9)
        XCTAssertThrowsError(try Inflate.decode(stream, expectedSize: DeflateVectors.text.count - 1)) { XCTAssertEqual($0 as? Inflate.Failure, .tooLong) }
        XCTAssertThrowsError(try Inflate.decode(stream, expectedSize: DeflateVectors.text.count + 1)) { XCTAssertEqual($0 as? Inflate.Failure, .tooShort) }
        let stored = DeflateVectors.stored(DeflateVectors.noise(1000))
        XCTAssertThrowsError(try Inflate.decode(stored, expectedSize: 999)) { XCTAssertEqual($0 as? Inflate.Failure, .tooLong) }
    }

    func testRefusesTruncatedTrailingAndInvalidStreams() {
        let stream = DeflateVectors.data(DeflateVectors.text9)
        XCTAssertThrowsError(try Inflate.decode(stream.prefix(stream.count - 20), expectedSize: DeflateVectors.text.count))
        XCTAssertThrowsError(try Inflate.decode(stream + Data([0]), expectedSize: DeflateVectors.text.count)) { XCTAssertEqual($0 as? Inflate.Failure, .trailingData) }
        // Block type 3 is reserved.
        XCTAssertThrowsError(try Inflate.decode(Data([0x07]), expectedSize: 0)) { XCTAssertEqual($0 as? Inflate.Failure, .invalid("block type")) }
        // LEN and NLEN that don't complement each other.
        XCTAssertThrowsError(try Inflate.decode(Data([0x01, 0x05, 0x00, 0x00, 0x00]) + Data(count: 5), expectedSize: 5))
        // A non-final block with nothing after it.
        XCTAssertThrowsError(try Inflate.decode(Data([0x00, 0x00, 0x00, 0xFF, 0xFF]), expectedSize: 0)) { XCTAssertEqual($0 as? Inflate.Failure, .truncated) }
    }

    func testRefusesADistanceBeforeTheStart() {
        var writer = FixedHuffmanWriter()
        writer.header(final: true)
        writer.literal(0x41)
        writer.copy3(distanceCode: 1) // distance 2, but only one byte so far
        writer.literal(256)
        XCTAssertThrowsError(try Inflate.decode(writer.data, expectedSize: 4)) { XCTAssertEqual($0 as? Inflate.Failure, .invalid("distance")) }

        var valid = FixedHuffmanWriter()
        valid.header(final: true)
        valid.literal(0x41)
        valid.copy3(distanceCode: 0) // overlapping copy of the one byte
        valid.literal(256)
        XCTAssertEqual(try Inflate.decode(valid.data, expectedSize: 4), Data("AAAA".utf8))
    }

    func testRefusesReservedFixedCodes() {
        var writer = FixedHuffmanWriter()
        writer.header(final: true)
        writer.literal(286)
        XCTAssertThrowsError(try Inflate.decode(writer.data, expectedSize: 10))
        var distance = FixedHuffmanWriter()
        distance.header(final: true)
        distance.literal(0x41)
        distance.copy3(distanceCode: 30)
        XCTAssertThrowsError(try Inflate.decode(distance.data, expectedSize: 10))
    }

    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }
}

final class ImageProbeTests: XCTestCase {
    func testReadsSizesFromHeadersOnly() {
        XCTAssertEqual(ImageProbe.probe(DeflateVectors.pngHeader(width: 600, height: 900)), ImageProbe(mediaType: "image/png", width: 600, height: 900))
        XCTAssertEqual(ImageProbe.probe(ZipBuilder.jpeg(width: 800, height: 1200)), ImageProbe(mediaType: "image/jpeg", width: 800, height: 1200))

        var lossy = Data("RIFF".utf8) + DeflateVectors.le32(100) + Data("WEBPVP8 ".utf8) + DeflateVectors.le32(80)
        lossy += Data([0x10, 0x02, 0x00, 0x9D, 0x01, 0x2A]) + DeflateVectors.le16(640) + DeflateVectors.le16(480) + Data(count: 10)
        XCTAssertEqual(ImageProbe.probe(lossy), ImageProbe(mediaType: "image/webp", width: 640, height: 480))

        let packed = UInt32(320 - 1) | UInt32(200 - 1) << 14
        var lossless = Data("RIFF".utf8) + DeflateVectors.le32(100) + Data("WEBPVP8L".utf8) + DeflateVectors.le32(80)
        lossless += Data([0x2F]) + DeflateVectors.le32(packed) + Data(count: 10)
        XCTAssertEqual(ImageProbe.probe(lossless), ImageProbe(mediaType: "image/webp", width: 320, height: 200))

        var extended = Data("RIFF".utf8) + DeflateVectors.le32(100) + Data("WEBPVP8X".utf8) + DeflateVectors.le32(10)
        extended += Data(count: 4) + Data([0x1F, 0x03, 0x00]) + Data([0xDF, 0x01, 0x00]) + Data(count: 4)
        XCTAssertEqual(ImageProbe.probe(extended), ImageProbe(mediaType: "image/webp", width: 800, height: 480))

        XCTAssertNil(ImageProbe.probe(Data("GIF89a".utf8) + Data(count: 40)))
        XCTAssertNil(ImageProbe.probe(Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02])), "scan data before a frame header")
    }

    func testBoundsDecodedPixels() {
        XCTAssertTrue(ImageProbe(mediaType: "image/png", width: 800, height: 30_000).withinLimits, "a long strip")
        XCTAssertFalse(ImageProbe(mediaType: "image/png", width: 30_001, height: 10).withinLimits)
        XCTAssertFalse(ImageProbe(mediaType: "image/png", width: 8_000, height: 8_000).withinLimits, "64 megapixels")
        XCTAssertFalse(ImageProbe(mediaType: "image/png", width: 0, height: 10).withinLimits)
    }
}

final class ReadingOrderTests: XCTestCase {
    private func item(_ position: Int, _ href: String, type: String = "image/png", size: Int64 = 10, method: Int = 0, compressed: Int64? = nil, crc: String = "0000abcd") -> ReadingOrder.Item {
        ReadingOrder.Item(position: position, href: href, mediaType: type, sizeBytes: size, compressedSize: compressed ?? size, compressionMethod: method, localHeaderOffset: 0, crc32: crc)
    }

    func testEscapesAsTheServerDoes() {
        XCTAssertEqual(ComicNames.escape(Array("Issue 1/page01.jpg".utf8)), "Issue%201/page01.jpg")
        XCTAssertEqual(ComicNames.escape(Array("Été/ü~_-.png".utf8)), "%C3%89t%C3%A9/%C3%BC~_-.png")
        XCTAssertEqual(ComicNames.unescape("Issue%201/page01.jpg"), Array("Issue 1/page01.jpg".utf8))
        XCTAssertNil(ComicNames.unescape("bad%2"))
    }

    func testAcceptsTheContractShape() throws {
        let order = ReadingOrder(assetId: "a", items: [item(1, "p1.png"), item(2, "p%202.jpg", type: "image/jpeg", method: 8, compressed: 8)])
        let data = try JSONEncoder().encode(order)
        XCTAssertEqual(try ReadingOrder.decode(data, assetId: "a"), order)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"local_header_offset\"") && json.contains("\"compression_method\""), json)
    }

    func testRefusesOrdersThatDontMatchTheContract() {
        let cases: [(String, ReadingOrder)] = [
            ("another asset", ReadingOrder(assetId: "b", items: [item(1, "p1.png")])),
            ("not a comic", ReadingOrder(assetId: "a", format: "pdf", items: [item(1, "p1.png")])),
            ("no pages", ReadingOrder(assetId: "a", items: [])),
            ("positions out of order", ReadingOrder(assetId: "a", items: [item(2, "p1.png"), item(1, "p2.png")])),
            ("an unescaped space", ReadingOrder(assetId: "a", items: [item(1, "p 1.png")])),
            ("lower-case escapes", ReadingOrder(assetId: "a", items: [item(1, "%c3%a9.png")])),
            ("a duplicate page", ReadingOrder(assetId: "a", items: [item(1, "p1.png"), item(2, "p1.png")])),
            ("a type that isn't the name's", ReadingOrder(assetId: "a", items: [item(1, "p1.png", type: "image/jpeg")])),
            ("not an image", ReadingOrder(assetId: "a", items: [item(1, "info.xml", type: "text/xml")])),
            ("an empty page", ReadingOrder(assetId: "a", items: [item(1, "p1.png", size: 0)])),
            ("a page over 32 MiB", ReadingOrder(assetId: "a", items: [item(1, "p1.png", size: (32 << 20) + 1)])),
            ("an unknown method", ReadingOrder(assetId: "a", items: [item(1, "p1.png", method: 12)])),
            ("stored with another size", ReadingOrder(assetId: "a", items: [item(1, "p1.png", compressed: 11)])),
            ("an upper-case CRC", ReadingOrder(assetId: "a", items: [item(1, "p1.png", crc: "0000ABCD")])),
            ("a short CRC", ReadingOrder(assetId: "a", items: [item(1, "p1.png", crc: "abcd")])),
        ]
        for (reason, order) in cases {
            XCTAssertThrowsError(try ReadingOrder.decode(JSONEncoder().encode(order), assetId: "a"), reason)
        }
        XCTAssertThrowsError(try ReadingOrder.decode(Data("{\"asset_id\":\"a\"".utf8), assetId: "a"))
        XCTAssertThrowsError(try ReadingOrder.decode(Data(count: Int(ReadingOrder.maxBytes) + 1), assetId: "a"))
    }
}

final class ComicArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data) throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString + ".cbz")
        try data.write(to: file)
        return file
    }

    private func open(_ zip: ZipBuilder) throws -> ComicArchive {
        try ComicArchive.open(write(zip.build().data), order: zip.order())
    }

    private func assertRefused(_ zip: ZipBuilder, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ComicArchive(file: write(zip.build().data)), reason, file: file, line: line) { error in
            guard case .unsupported = error as? ComicArchiveError else {
                return XCTFail("\(reason): \(error)", file: file, line: line)
            }
        }
    }

    func testReadsVerifiedPagesInTheServersOrder() throws {
        let zip = ZipBuilder.comic()
        let order = zip.order()
        XCTAssertEqual(order.items.map(\.href), ["Issue%201/page1.png", "Issue%201/page2.png", "Issue%201/page%2010.jpg"])
        let archive = try open(zip)
        defer { archive.close() }
        XCTAssertEqual(try archive.page(1), zip.entries[1].payload, "a stored page")
        XCTAssertEqual(try archive.page(2), DeflateVectors.png, "a deflated page behind a data descriptor")
        XCTAssertEqual(try archive.page(3), zip.entries[3].payload)
        XCTAssertThrowsError(try archive.page(4))
        XCTAssertThrowsError(try archive.page(0))
    }

    func testAcceptsADataDescriptorWithoutItsSignature() throws {
        var zip = ZipBuilder.comic()
        zip.entries[2].descriptor = false
        XCTAssertEqual(try open(zip).page(2), DeflateVectors.png)
    }

    func testRefusesADataDescriptorThatDisagrees() throws {
        var zip = ZipBuilder.comic()
        zip.entries[2].descriptor = true
        var data = zip.build().data
        // Change the descriptor's CRC: the bytes right after the deflated page.
        let offset = zip.build().offsets[2] + 30 + zip.entries[2].name.count + zip.entries[2].stream.count + 4
        data[offset] ^= 0xFF
        XCTAssertThrowsError(try ComicArchive(file: write(data)))
    }

    func testAnOrderMustDescribeExactlyThisArchive() throws {
        let zip = ZipBuilder.comic()
        let file = try write(zip.build().data)
        let order = zip.order()
        func refused(_ items: [ReadingOrder.Item], _ reason: String) {
            XCTAssertThrowsError(try ComicArchive.open(file, order: ReadingOrder(assetId: "cbz-1", items: items)), reason) { error in
                guard case .orderMismatch = error as? ComicArchiveError else { return XCTFail("\(reason): \(error)") }
            }
        }
        refused(Array(order.items.prefix(2)), "a page missing")
        let moved = order.items[1]
        refused([order.items[0], ReadingOrder.Item(position: 2, href: moved.href, mediaType: moved.mediaType, sizeBytes: moved.sizeBytes, compressedSize: moved.compressedSize, compressionMethod: moved.compressionMethod, localHeaderOffset: moved.localHeaderOffset + 1, crc32: moved.crc32), order.items[2]], "another offset")
        refused([order.items[0], ReadingOrder.Item(position: 2, href: moved.href, mediaType: moved.mediaType, sizeBytes: moved.sizeBytes, compressedSize: moved.compressedSize, compressionMethod: moved.compressionMethod, localHeaderOffset: moved.localHeaderOffset, crc32: "00000000"), order.items[2]], "another CRC")
        refused([order.items[0], ReadingOrder.Item(position: 2, href: "Issue%201/.thumb.png", mediaType: "image/png", sizeBytes: 1, compressedSize: 1, compressionMethod: 0, localHeaderOffset: 0, crc32: "00000000"), order.items[2]], "a hidden file")
    }

    func testAPageThatDoesntMatchItsCRCIsDamaged() throws {
        var zip = ZipBuilder.comic()
        // Directory, local header and order all claim another CRC than the bytes have.
        zip.entries[1].centralCRC = 0x1234_5678
        zip.entries[1].localCRC = 0x1234_5678
        var order = zip.order()
        order = ReadingOrder(assetId: order.assetId, items: order.items.enumerated().map { index, item in
            index == 0 ? ReadingOrder.Item(position: 1, href: item.href, mediaType: item.mediaType, sizeBytes: item.sizeBytes, compressedSize: item.compressedSize, compressionMethod: item.compressionMethod, localHeaderOffset: item.localHeaderOffset, crc32: "12345678") : item
        })
        let archive = try ComicArchive.open(write(zip.build().data), order: order)
        XCTAssertThrowsError(try archive.page(1)) { XCTAssertEqual($0 as? ComicArchiveError, .damagedPage(1)) }
        XCTAssertNoThrow(try archive.page(3), "other pages still open")
    }

    func testAPageThatInflatesPastItsSizeIsDamaged() throws {
        var zip = ZipBuilder()
        var entry = ZipBuilder.Entry("p1.png", DeflateVectors.png, method: 8)
        entry.compressed = DeflateVectors.data(DeflateVectors.png9)
        entry.centralSize = UInt32(DeflateVectors.png.count - 100)
        zip.add(entry)
        // The local header states the same smaller size.
        var data = zip.build().data
        let smaller = DeflateVectors.le32(UInt32(DeflateVectors.png.count - 100))
        data.replaceSubrange(22 ..< 26, with: smaller)
        let file = try write(data)
        let item = zip.order().items[0]
        let order = ReadingOrder(assetId: "cbz-1", items: [ReadingOrder.Item(position: 1, href: item.href, mediaType: item.mediaType, sizeBytes: Int64(DeflateVectors.png.count - 100), compressedSize: item.compressedSize, compressionMethod: 8, localHeaderOffset: 0, crc32: item.crc32)])
        let archive = try ComicArchive.open(file, order: order)
        XCTAssertThrowsError(try archive.page(1)) { XCTAssertEqual($0 as? ComicArchiveError, .damagedPage(1)) }
    }

    func testRefusesPagesThatArentTheirImageOrAreTooLarge() throws {
        var zip = ZipBuilder()
        zip.add(ZipBuilder.Entry("a.jpg", DeflateVectors.pngHeader(width: 10, height: 10)))
        zip.add(ZipBuilder.Entry("b.png", DeflateVectors.pngHeader(width: 9_000, height: 9_000)))
        zip.add(ZipBuilder.Entry("c.png", Data("not an image at all".utf8)))
        let archive = try open(zip)
        XCTAssertThrowsError(try archive.page(1)) { XCTAssertEqual($0 as? ComicArchiveError, .unsupportedImage(1)) }
        XCTAssertThrowsError(try archive.page(2)) { XCTAssertEqual($0 as? ComicArchiveError, .unsupportedImage(2)) }
        XCTAssertThrowsError(try archive.page(3)) { XCTAssertEqual($0 as? ComicArchiveError, .unsupportedImage(3)) }
    }

    func testRefusesUnsafeOrAmbiguousNames() {
        for name in ["../escape.png", "/absolute.png", "Issue\\page.png", "C:page.png", "a//b.png", "./a.png", "a/../b.png", "tab\tname.png"] {
            var zip = ZipBuilder()
            zip.add(ZipBuilder.Entry(name, DeflateVectors.pngHeader(width: 1, height: 1)))
            assertRefused(zip, name)
        }
        var duplicate = ZipBuilder()
        duplicate.add(ZipBuilder.Entry("p1.png", DeflateVectors.pngHeader(width: 1, height: 1)))
        duplicate.add(ZipBuilder.Entry("p1.png", DeflateVectors.pngHeader(width: 1, height: 1)))
        assertRefused(duplicate, "a duplicate name")

        var equivalent = ZipBuilder()
        equivalent.add(ZipBuilder.Entry("\u{E9}.png", DeflateVectors.pngHeader(width: 1, height: 1)))
        equivalent.add(ZipBuilder.Entry("e\u{301}.png", DeflateVectors.pngHeader(width: 1, height: 1)))
        assertRefused(equivalent, "Unicode-equivalent names")

        var unflagged = ZipBuilder()
        var latin = ZipBuilder.Entry("x.png", DeflateVectors.pngHeader(width: 1, height: 1))
        latin.name = [0xE9] + Array(".png".utf8)
        latin.flags = 0
        unflagged.add(latin)
        assertRefused(unflagged, "a legacy code page name")

        var invalid = ZipBuilder()
        var broken = ZipBuilder.Entry("x.png", DeflateVectors.pngHeader(width: 1, height: 1))
        broken.name = [0xC3, 0x28] + Array(".png".utf8)
        broken.flags = 0x0800
        invalid.add(broken)
        assertRefused(invalid, "invalid UTF-8")
    }

    func testRefusesEncryptionLinksAndUnsupportedFeatures() {
        func one(_ change: (inout ZipBuilder.Entry) -> Void) -> ZipBuilder {
            var zip = ZipBuilder()
            var entry = ZipBuilder.Entry("p1.png", DeflateVectors.pngHeader(width: 1, height: 1))
            change(&entry)
            zip.add(entry)
            return zip
        }
        assertRefused(one { $0.flags |= 0x0001 }, "encrypted")
        assertRefused(one { $0.flags |= 0x0040 }, "strong encryption")
        assertRefused(one { $0.flags |= 0x2000 }, "masked headers")
        assertRefused(one { $0.method = 12 }, "bzip2")
        assertRefused(one { $0.extra = DeflateVectors.le16(0x0001) + DeflateVectors.le16(0) }, "ZIP64 extra")
        assertRefused(one { $0.extra = DeflateVectors.le16(0x7075) + DeflateVectors.le16(0) }, "Unicode path extra")
        assertRefused(one { $0.extra = DeflateVectors.le16(0x9901) + DeflateVectors.le16(0) }, "AES")
        assertRefused(one { $0.extra = DeflateVectors.le16(0x5455) + DeflateVectors.le16(9) }, "a truncated extra field")
        assertRefused(one {
            $0.madeBy = 3 << 8 | 20
            $0.external = 0o120777 << 16
        }, "a symbolic link")
        assertRefused(one {
            $0.madeBy = 3 << 8 | 20
            $0.external = 0o060644 << 16
        }, "a block device")
        assertRefused(one { $0.localName = Array("p2.png".utf8) }, "a local name that disagrees")
        assertRefused(one { $0.localMethod = 8 }, "a local method that disagrees")
        assertRefused(one { $0.localCRC = 1 }, "a local CRC that disagrees")
        assertRefused(one { $0.localExtra = DeflateVectors.le16(0x0001) + DeflateVectors.le16(0) }, "a local ZIP64 extra")
        var folder = ZipBuilder()
        folder.add(ZipBuilder.Entry("dir/", Data("data".utf8)))
        assertRefused(folder, "a folder with data")

        var unix = one {
            $0.madeBy = 3 << 8 | 20
            $0.external = 0o100644 << 16
        }
        unix.add(ZipBuilder.Entry("dir/", Data()))
        XCTAssertNoThrow(try ComicArchive(file: write(unix.build().data)), "regular Unix files and folders are fine")
    }

    func testRefusesAmbiguousOrDisplacedDirectories() throws {
        var trailing = ZipBuilder.comic()
        trailing.trailing = Data("junk".utf8)
        assertRefused(trailing, "data after the directory record")

        var prefixed = ZipBuilder.comic()
        prefixed.prefix = Data(repeating: 0x20, count: 64)
        assertRefused(prefixed, "a prefix whose offsets weren't moved")

        var zip64 = ZipBuilder.comic()
        zip64.zip64Locator = true
        assertRefused(zip64, "a ZIP64 locator")

        // A second record hidden in the comment: either could be the real one.
        var hidden = ZipBuilder.comic()
        let inner = ZipBuilder.comic().build().data.suffix(22)
        hidden.comment = Data(inner)
        assertRefused(hidden, "two end-of-directory records")

        XCTAssertThrowsError(try ComicArchive(file: write(Data("PK".utf8))))
        XCTAssertThrowsError(try ComicArchive(file: directory.appendingPathComponent("missing.cbz"))) {
            XCTAssertEqual($0 as? ComicArchiveError, .unreadable)
        }

        var commented = ZipBuilder.comic()
        commented.comment = Data("Scanned by nobody".utf8)
        XCTAssertNoThrow(try open(commented), "an ordinary comment is fine")
    }

    func testRefusesOverlappingEntries() throws {
        // B's local record lives inside A's data: each header matches, the bytes are shared.
        let inner = ZipBuilder.Entry("b.png", DeflateVectors.pngHeader(width: 1, height: 1))
        var zip = ZipBuilder()
        let outer = ZipBuilder.Entry("a.bin", ZipBuilder.localRecord(inner))
        zip.add(outer)
        var shared = inner
        shared.directoryOffset = UInt32(30 + outer.name.count)
        zip.entries.append(shared)
        var data = zip.build().data
        // Drop the second, separately written copy of B so only the shared one remains.
        let separate = ZipBuilder.localRecord(inner)
        let start = 30 + outer.name.count + outer.payload.count
        data.removeSubrange(start ..< start + separate.count)
        // Directory offset in the end record moved back by that much.
        let eocd = data.count - 22
        let directoryOffset = UInt32(start)
        data.replaceSubrange(eocd + 16 ..< eocd + 20, with: DeflateVectors.le32(directoryOffset))
        XCTAssertThrowsError(try ComicArchive(file: write(data))) { error in
            XCTAssertEqual(error as? ComicArchiveError, .unsupported("overlapping entries"))
        }
    }
}
