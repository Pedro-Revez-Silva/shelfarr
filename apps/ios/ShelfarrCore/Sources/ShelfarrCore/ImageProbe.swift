import Foundation

/// The type and pixel size an image's header declares, read before any decoder is
/// given the bytes, so an oversized page is refused before memory is allocated for it.
public struct ImageProbe: Equatable, Sendable {
    public let mediaType: String
    public let width: Int
    public let height: Int

    /// Each side at most 30,000 pixels and 40 megapixels in all: about 160 MB decoded,
    /// before the reader scales it down to the screen.
    public static let maxSide = 30_000
    public static let maxPixels = 40_000_000

    public init(mediaType: String, width: Int, height: Int) {
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }

    public var withinLimits: Bool { Self.withinLimits(width: width, height: height) }

    public static func withinLimits(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide && width * height <= maxPixels
    }

    /// Nil when the bytes are not a JPEG, PNG or WebP with a readable size.
    public static func probe(_ data: Data) -> ImageProbe? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ImageProbe? in
            let bytes = raw.bindMemory(to: UInt8.self)
            return png(bytes) ?? jpeg(bytes) ?? webp(bytes)
        }
    }

    private static func be16(_ b: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
    private static func be32(_ b: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int { be16(b, at) << 16 | be16(b, at + 2) }
    private static func le16(_ b: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    private static func le24(_ b: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int { le16(b, at) | Int(b[at + 2]) << 16 }

    private static func png(_ b: UnsafeBufferPointer<UInt8>) -> ImageProbe? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count >= 24, Array(b[0 ..< 8]) == signature,
              be32(b, 8) == 13, Array(b[12 ..< 16]) == Array("IHDR".utf8)
        else { return nil }
        return ImageProbe(mediaType: "image/png", width: be32(b, 16), height: be32(b, 20))
    }

    private static func jpeg(_ b: UnsafeBufferPointer<UInt8>) -> ImageProbe? {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= b.count {
            guard b[index] == 0xFF else { return nil }
            let marker = b[index + 1]
            if marker == 0xFF { index += 1; continue } // fill byte
            if marker == 0x01 || (0xD0 ... 0xD7).contains(marker) { index += 2; continue } // no length
            if marker == 0xD9 || marker == 0xDA { return nil } // image data before any frame header
            let length = be16(b, index + 2)
            guard length >= 2 else { return nil }
            // Start of frame: every SOFn except DHT (C4), JPG (C8) and DAC (CC).
            if (0xC0 ... 0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard index + 9 <= b.count, length >= 7 else { return nil }
                return ImageProbe(mediaType: "image/jpeg", width: be16(b, index + 7), height: be16(b, index + 5))
            }
            index += 2 + length
        }
        return nil
    }

    private static func webp(_ b: UnsafeBufferPointer<UInt8>) -> ImageProbe? {
        guard b.count >= 30, Array(b[0 ..< 4]) == Array("RIFF".utf8), Array(b[8 ..< 12]) == Array("WEBP".utf8) else { return nil }
        let chunk = String(decoding: b[12 ..< 16], as: UTF8.self)
        switch chunk {
        case "VP8 ":
            // Key frame start code, then 14-bit width and height.
            guard b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A else { return nil }
            return ImageProbe(mediaType: "image/webp", width: le16(b, 26) & 0x3FFF, height: le16(b, 28) & 0x3FFF)
        case "VP8L":
            guard b[20] == 0x2F else { return nil }
            let packed = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
            return ImageProbe(mediaType: "image/webp", width: (packed & 0x3FFF) + 1, height: ((packed >> 14) & 0x3FFF) + 1)
        case "VP8X":
            return ImageProbe(mediaType: "image/webp", width: le24(b, 24) + 1, height: le24(b, 27) + 1)
        default:
            return nil
        }
    }
}
