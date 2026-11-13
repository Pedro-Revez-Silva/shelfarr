import Foundation

/// A CBZ's authoritative page order for one exact file generation, from
/// `GET /library/:id/assets/:asset_id/reading_order`.
///
/// The server read it from the archive's bounded ZIP metadata. The app checks its shape
/// here, then against the archive's own directory and local headers (`ComicArchive`)
/// before the comic is offered for reading, and never reorders it.
public struct ReadingOrder: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let position: Int
        /// The ZIP-root entry name, percent-escaped as the server escapes it.
        public let href: String
        public let mediaType: String
        public let sizeBytes: Int64
        public let compressedSize: Int64
        public let compressionMethod: Int
        public let localHeaderOffset: Int64
        /// Eight lower-case hex digits.
        public let crc32: String

        public init(position: Int, href: String, mediaType: String, sizeBytes: Int64, compressedSize: Int64, compressionMethod: Int, localHeaderOffset: Int64, crc32: String) {
            self.position = position
            self.href = href
            self.mediaType = mediaType
            self.sizeBytes = sizeBytes
            self.compressedSize = compressedSize
            self.compressionMethod = compressionMethod
            self.localHeaderOffset = localHeaderOffset
            self.crc32 = crc32
        }

        enum CodingKeys: String, CodingKey {
            case position, href
            case mediaType = "media_type"
            case sizeBytes = "size_bytes"
            case compressedSize = "compressed_size"
            case compressionMethod = "compression_method"
            case localHeaderOffset = "local_header_offset"
            case crc32
        }

        public var crcValue: UInt32? {
            guard crc32.count == 8, crc32.allSatisfy({ ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }) else { return nil }
            return UInt32(crc32, radix: 16)
        }
    }

    public let assetId: String
    public let format: String
    public let items: [Item]

    public init(assetId: String, format: String = "cbz", items: [Item]) {
        self.assetId = assetId
        self.format = format
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case format, items
    }

    /// The response bound: anything larger is refused before it is parsed.
    public static let maxBytes: Int64 = 8 << 20

    public enum Invalid: Error, Equatable, Sendable {
        case malformed
        case wrongAsset
        case shape(String)
    }

    /// Decodes and checks a reading order received for `assetId`.
    public static func decode(_ data: Data, assetId: String) throws -> ReadingOrder {
        guard Int64(data.count) <= maxBytes else { throw Invalid.malformed }
        let order: ReadingOrder
        do {
            order = try JSONDecoder().decode(ReadingOrder.self, from: data)
        } catch {
            throw Invalid.malformed
        }
        try order.validate(assetId: assetId)
        return order
    }

    /// The shape the contract promises, before any byte of the archive is read: pages
    /// 1…N in order, canonical unique hrefs whose media types match their names, sizes and
    /// methods within the caps, and lower-case CRCs.
    public func validate(assetId: String) throws {
        guard self.assetId == assetId, format == "cbz" else { throw Invalid.wrongAsset }
        guard (1 ... ComicArchive.maxEntries).contains(items.count) else { throw Invalid.shape("page count") }
        var hrefs: Set<String> = []
        var total: Int64 = 0
        for (index, item) in items.enumerated() {
            guard item.position == index + 1 else { throw Invalid.shape("positions") }
            guard let name = ComicNames.unescape(item.href), ComicNames.escape(name) == item.href,
                  hrefs.insert(item.href).inserted
            else { throw Invalid.shape("href") }
            guard ComicNames.mediaType(forName: name) == item.mediaType else { throw Invalid.shape("media type") }
            guard (1 ... ComicArchive.maxImageBytes).contains(item.sizeBytes) else { throw Invalid.shape("page size") }
            total += item.sizeBytes
            guard total <= ComicArchive.maxTotalBytes else { throw Invalid.shape("total size") }
            guard [0, 8].contains(item.compressionMethod),
                  (0 ..< 0xFFFF_FFFF).contains(item.compressedSize),
                  (0 ..< 0xFFFF_FFFF).contains(item.localHeaderOffset),
                  item.compressionMethod == 8 || item.compressedSize == item.sizeBytes,
                  item.compressedSize <= ComicArchive.maxCompressedPageBytes
            else { throw Invalid.shape("compression") }
            guard item.crcValue != nil else { throw Invalid.shape("crc32") }
        }
    }
}

/// ZIP entry names as the server writes them into a reading order.
public enum ComicNames {
    /// Every byte outside `A-Z a-z 0-9 - . _ ~ /` as `%XX`, upper-case hex.
    public static func escape(_ name: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        for byte in name {
            switch byte {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39, 0x2D, 0x2E, 0x5F, 0x7E, 0x2F:
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// The name bytes an escaped href stands for; nil for a malformed escape.
    public static func unescape(_ href: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        let source = Array(href.utf8)
        var index = 0
        while index < source.count {
            if source[index] == 0x25 {
                guard index + 2 < source.count,
                      let value = UInt8(String(decoding: source[index + 1 ... index + 2], as: UTF8.self), radix: 16)
                else { return nil }
                bytes.append(value)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return bytes.isEmpty ? nil : bytes
    }

    public static let imageTypes = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp"]

    /// The page media type for an entry name, by its extension; nil when it is no page.
    public static func mediaType(forName name: [UInt8]) -> String? {
        guard let dot = name.lastIndex(of: 0x2E), !name[(dot + 1)...].contains(0x2F) else { return nil }
        let ext = String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
        return imageTypes[ext]
    }
}
