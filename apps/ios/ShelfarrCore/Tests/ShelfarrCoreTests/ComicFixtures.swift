import Foundation
@testable import ShelfarrCore

/// Raw DEFLATE streams made by Python's zlib (`compressobj(9, DEFLATED, -15)`), so the
/// decoder is checked against a real encoder's dynamic and fixed Huffman output.
enum DeflateVectors {
    /// 120 lines of `Line N: the quick brown fox jumps over the lazy dog.\n`; dynamic codes.
    static let text9 = "ndjHUQNBAEXBO1FMBNR4QwwkgREgjAQC4aKnIAP6vPVP27U78863u02IZ+HtbhNejturh3B52H/sws3+M9wfn55fw/59c/h7/Hjx/RWu97enJ+e/oySjLKMioyqjJqMuoyGjKaNFL9dIkIlEKBKpSMQikYtEMBLJSEQjkY1MNrJ9L8hGJhuZbGSykclGJhuZbGSyUchGIRvFfiZko5CNQjYK2Shko5CNQjYq2ahko5KNaicNslHJRiUblWxUslHJRiMbjWw0stHIRrNjKNloZKORjUY2GtnoZKOTjU42OtnoZKPbHYVsdLLRyUYnG4NsDLIxyMYgG4NsDLIx7AJLNgbZGGRjko1JNibZmGRjko1JNibZmFY3yMYkG4tsLLKxyMYiG4tsLLKxyMYiG8vSF7Yvi1/R6le0/BWtf0ULYNEKWLQEFq2BRYtg0ZRoIjUlGEmxkmImxU6KoRRLKabSf7fSHw=="
    static let text9CRC: UInt32 = 0x2774_877A
    /// The same text with `Z_FIXED`: fixed codes with matches.
    static let textFixed = "88nMS1UwsFIoyUhVKCzNTM5WSCrKL89TSMuvUMgqzS0oVsgvSy0CS+ckVlUqpOSn63H5gDQZkqPJiBxNxuRoMiFHkyk5mszI0WROjiYLcjRZkhW55CUJstKEIVmJwpCsVGFIVrIwJCtdGJKVMAzJShmGZCUNQ7LShhFZacOIvPKCrLRhRFbaMCIrbRiRlTaMyEobRmSlDSOy0oYRWWnDmKy0YUxW2jAmrzIhK20Yk5U2jMlKG8ZkpQ1jstKGMVlpw5istGFCVtowISttmJCVNkzIa2mQlTZMyEobJmSlDROy0oYJWWnDhKy0YUpW2jAlK22YkpU2TMlKG6bkNUPJShumZKUNU7LShilZacOUrLRhRlbaMCMrbZiRlTbMyEobZmSlDTPy+ihkpQ0zstKGGVlpw4ystGFOVtowJyttmJOVNszJShvmZKUNc7LShjl5HViy0oY5WWnDnKy0YUFW2rAgK21YkJU2LMhKGxZkpQ0LstKGBVlpw4K80Q2y0oYFWWnDkqy0YUlW2rAkK21YkpU2LMlKG5ZkpQ1LstKGJVlpw5K8oS8yx77IG/wyIG/0y4C84S8D8sa/DMgbADMgbwTMgLwhMAPyxsAMyBsEMyAvlZA7REpeKiFzkJTMUVIyh0nJHCclc6CUzJFSModKSR4rBQA="
    /// A PNG signature and 40×60 IHDR, then `IDAT` and the text above: an image page.
    static let png9 = "ndjNSlRhAMfhwVUMeAOtzrKVvN8f0UYQUpCI6AbUxo8+HDUt6w6668SuoOfAcBbDfzUPZ97z+/P+3dvd9cv1arXaPTo8+PB0f/X0efNiZ/XvOjrY/3h8db1Zwuvl/nKz3D5cnX1ZTu+2P6+X8+3j8vnh2833Zftjc/f89deT37+WT9uLvfXzKMooySjLqMioyqjJqMtoyGjSj2skyEQkFJFURGIRyUUkGJFkRKIRyUYiG8meF2QjkY1ENhLZSGQjkY1ENhLZyGQjk41sfyZkI5ONTDYy2chkI5ONTDYK2Shko5CNYicNslHIRiEbhWwUslHIRiUblWxUslHJRrVjKNmoZKOSjUo2KtloZKORjUY2GtloZKPZOwrZaGSjkY1GNjrZ6GSjk41ONjrZ6GSj2wss2ehko5ONQTYG2RhkY5CNQTYG2RhkY1jdIBuDbEyyMcnGJBuTbEyyMcnGJBuTbExLX9i+LH4Fq1/B8lew/hUsgAUrYMESWLAGFiyCBVOiidSUYCTFSoqZFDsphlIspZhK/7uV/gU="
    static let png9CRC: UInt32 = 0x53CF_33A8
    static let abc = "S0xKBgA="
    static let empty = "AwA="

    static func data(_ base64: String) -> Data { Data(base64Encoded: base64)! }

    static var text: Data {
        Data((0 ..< 120).map { "Line \($0): the quick brown fox jumps over the lazy dog.\n" }.joined().utf8)
    }

    static var png: Data { pngHeader(width: 40, height: 60) + Data("IDAT".utf8) + text }

    static func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data += Data("IHDR".utf8)
        data += be32(width) + be32(height) + Data([8, 2, 0, 0, 0]) + Data([0, 0, 0, 0])
        return data
    }

    static func be32(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }

    /// A valid DEFLATE stream of stored blocks (at most 65,535 bytes each).
    static func stored(_ data: Data, blockSize: Int = 65_535) -> Data {
        var out = Data()
        var offset = 0
        repeat {
            let length = min(blockSize, data.count - offset)
            let final = offset + length == data.count
            out.append(final ? 1 : 0)
            out += le16(UInt16(length)) + le16(~UInt16(length))
            out += data[data.startIndex + offset ..< data.startIndex + offset + length]
            offset += length
        } while offset < data.count
        return out
    }

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data { le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16)) }

    /// Deterministic noise that doesn't compress.
    static func noise(_ count: Int, seed: UInt32 = 1) -> Data {
        var state = seed
        return Data((0 ..< count).map { _ in
            state = state &* 1_103_515_245 &+ 12345
            return UInt8(state >> 16 & 0xFF)
        })
    }
}

/// Writes fixed-Huffman DEFLATE by hand, for streams no encoder would produce.
struct FixedHuffmanWriter {
    private(set) var bytes: [UInt8] = []
    private var bit = 0

    mutating func bits(_ value: Int, _ count: Int) {
        for index in 0 ..< count {
            if bit == 0 { bytes.append(0) }
            if value >> index & 1 == 1 { bytes[bytes.count - 1] |= UInt8(1 << bit) }
            bit = (bit + 1) % 8
        }
    }

    /// A Huffman code, most significant bit first.
    mutating func code(_ value: Int, _ length: Int) {
        for index in stride(from: length - 1, through: 0, by: -1) { bits(value >> index & 1, 1) }
    }

    mutating func header(final: Bool) {
        bits(final ? 1 : 0, 1)
        bits(1, 2)
    }

    mutating func literal(_ symbol: Int) {
        switch symbol {
        case 0 ... 143: code(0x30 + symbol, 8)
        case 144 ... 255: code(0x190 + symbol - 144, 9)
        case 256 ... 279: code(symbol - 256, 7)
        default: code(0xC0 + symbol - 280, 8)
        }
    }

    /// A length of 3 (symbol 257) at `distanceCode` (no extra bits for codes 0–3).
    mutating func copy3(distanceCode: Int) {
        literal(257)
        code(distanceCode, 5)
    }

    var data: Data { Data(bytes) }
}

/// Builds ZIP archives entry by entry, including ones a real comic must never be.
struct ZipBuilder {
    struct Entry {
        var name: [UInt8]
        var payload: Data
        var method: UInt16 = 0
        /// For method 8: the raw DEFLATE stream; defaults to stored blocks of `payload`.
        var compressed: Data?
        var flags: UInt16 = 0
        var madeBy: UInt16 = 20
        var external: UInt32 = 0
        var extra: Data = Data()
        var localExtra: Data?
        /// Write a data descriptor after the data; `true` with its signature.
        var descriptor: Bool?
        /// Change the local header after it is built, for headers that disagree.
        var localName: [UInt8]?
        var localMethod: UInt16?
        var localCRC: UInt32?
        var centralCRC: UInt32?
        var centralSize: UInt32?
        var directoryOffset: UInt32?

        init(_ name: String, _ payload: Data, method: UInt16 = 0) {
            self.name = Array(name.utf8)
            self.payload = payload
            self.method = method
            if !name.unicodeScalars.allSatisfy(\.isASCII) { flags |= 0x0800 }
        }

        var stream: Data { method == 8 ? (compressed ?? DeflateVectors.stored(payload)) : payload }
        var crc: UInt32 { CRC32.checksum(payload) }
    }

    var entries: [Entry] = []
    var comment = Data()
    var prefix = Data()
    var trailing = Data()
    var zip64Locator = false

    mutating func add(_ entry: Entry) { entries.append(entry) }

    /// The local header, name, extra field, data and any data descriptor of `entry`.
    static func localRecord(_ entry: Entry) -> Data {
        let stream = entry.stream
        let hasDescriptor = entry.descriptor != nil
        let flags = entry.flags | (hasDescriptor ? 0x0008 : 0)
        let localName = entry.localName ?? entry.name
        let localExtra = entry.localExtra ?? entry.extra
        var local = DeflateVectors.le32(0x0403_4B50) + DeflateVectors.le16(20) + DeflateVectors.le16(flags)
        local += DeflateVectors.le16(entry.localMethod ?? entry.method) + DeflateVectors.le32(0)
        if hasDescriptor {
            local += DeflateVectors.le32(0) + DeflateVectors.le32(0) + DeflateVectors.le32(0)
        } else {
            local += DeflateVectors.le32(entry.localCRC ?? entry.crc) + DeflateVectors.le32(UInt32(stream.count)) + DeflateVectors.le32(UInt32(entry.payload.count))
        }
        local += DeflateVectors.le16(UInt16(localName.count)) + DeflateVectors.le16(UInt16(localExtra.count))
        local += Data(localName) + localExtra + stream
        if let signed = entry.descriptor {
            if signed { local += DeflateVectors.le32(0x0807_4B50) }
            local += DeflateVectors.le32(entry.crc) + DeflateVectors.le32(UInt32(stream.count)) + DeflateVectors.le32(UInt32(entry.payload.count))
        }
        return local
    }

    func build() -> (data: Data, offsets: [Int]) {
        var body = prefix
        var central = Data()
        var offsets: [Int] = []
        for entry in entries {
            let stream = entry.stream
            let offset = body.count - prefix.count
            offsets.append(Int(entry.directoryOffset ?? UInt32(offset)))
            let flags = entry.flags | (entry.descriptor != nil ? 0x0008 : 0)
            body += Self.localRecord(entry)
            var record = DeflateVectors.le32(0x0201_4B50) + DeflateVectors.le16(entry.madeBy) + DeflateVectors.le16(20)
            record += DeflateVectors.le16(flags) + DeflateVectors.le16(entry.method) + DeflateVectors.le32(0)
            record += DeflateVectors.le32(entry.centralCRC ?? entry.crc) + DeflateVectors.le32(UInt32(stream.count))
            record += DeflateVectors.le32(entry.centralSize ?? UInt32(entry.payload.count))
            record += DeflateVectors.le16(UInt16(entry.name.count)) + DeflateVectors.le16(UInt16(entry.extra.count)) + DeflateVectors.le16(0)
            record += DeflateVectors.le16(0) + DeflateVectors.le16(0) + DeflateVectors.le32(entry.external)
            record += DeflateVectors.le32(entry.directoryOffset ?? UInt32(offset))
            record += Data(entry.name) + entry.extra
            central += record
        }
        let directoryOffset = body.count - prefix.count
        body += central
        if zip64Locator { body += DeflateVectors.le32(0x0706_4B50) + Data(count: 16) }
        var eocd = DeflateVectors.le32(0x0605_4B50) + DeflateVectors.le16(0) + DeflateVectors.le16(0)
        eocd += DeflateVectors.le16(UInt16(entries.count)) + DeflateVectors.le16(UInt16(entries.count))
        eocd += DeflateVectors.le32(UInt32(central.count)) + DeflateVectors.le32(UInt32(directoryOffset))
        eocd += DeflateVectors.le16(UInt16(comment.count)) + comment
        body += eocd + trailing
        return (body, offsets)
    }

    /// The reading order the server would serve: images outside hidden folders, in the
    /// natural order these fixtures already use.
    func order(assetId: String = "cbz-1", archive: Data? = nil) -> ReadingOrder {
        let offsets = build().offsets
        var items: [ReadingOrder.Item] = []
        for (index, entry) in entries.enumerated() {
            let name = String(decoding: entry.name, as: UTF8.self)
            guard !name.hasSuffix("/"),
                  !name.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }),
                  let type = ComicNames.mediaType(forName: entry.name)
            else { continue }
            items.append(ReadingOrder.Item(
                position: items.count + 1, href: ComicNames.escape(entry.name), mediaType: type,
                sizeBytes: Int64(entry.payload.count), compressedSize: Int64(entry.stream.count),
                compressionMethod: Int(entry.method), localHeaderOffset: Int64(offsets[index]),
                crc32: String(format: "%08x", entry.crc)
            ))
        }
        return ReadingOrder(assetId: assetId, items: items)
    }

    /// Three pages: a stored PNG, a deflated PNG (zlib's dynamic codes) behind a data
    /// descriptor, and a JPEG in a folder, plus a hidden file, macOS metadata, a folder
    /// entry and a non-image file that are not pages.
    static func comic() -> ZipBuilder {
        var zip = ZipBuilder()
        zip.add(Entry("Issue 1/", Data()))
        zip.add(Entry("Issue 1/page1.png", DeflateVectors.pngHeader(width: 600, height: 900) + DeflateVectors.noise(3000)))
        var second = Entry("Issue 1/page2.png", DeflateVectors.png, method: 8)
        second.compressed = DeflateVectors.data(DeflateVectors.png9)
        second.descriptor = true
        zip.add(second)
        zip.add(Entry("Issue 1/page 10.jpg", jpeg(width: 800, height: 1200)))
        zip.add(Entry("Issue 1/.thumb.png", DeflateVectors.pngHeader(width: 10, height: 10)))
        zip.add(Entry("__MACOSX/Issue 1/._page1.png", Data(repeating: 0, count: 20)))
        zip.add(Entry("ComicInfo.xml", Data("<ComicInfo/>".utf8), method: 8))
        return zip
    }

    static func jpeg(width: UInt16, height: UInt16) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data("JFIF\0".utf8) + Data([1, 1, 0, 0, 1, 0, 1, 0, 0])
        data += Data([0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 0x03])
        data += Data([1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        data += DeflateVectors.noise(500) + Data([0xFF, 0xD9])
        return data
    }
}
