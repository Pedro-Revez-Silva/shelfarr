import Foundation

/// Why a comic archive or one of its pages can't be shown.
public enum ComicArchiveError: Error, Equatable, Sendable {
    /// The file couldn't be read.
    case unreadable
    /// The archive uses something this reader refuses: ZIP64, encryption, links,
    /// unsafe or duplicate names, inconsistent headers, sizes past the caps.
    case unsupported(String)
    /// The server's page order doesn't describe this archive.
    case orderMismatch(String)
    /// The page's bytes don't inflate to its size or don't match its CRC-32.
    case damagedPage(Int)
    /// The page isn't the image its name says, or is larger than the reader decodes.
    case unsupportedImage(Int)
}

/// A CBZ on this device, read in place: one page at a time, never extracted.
///
/// Opening checks the same bounded ZIP32 structure the server checked before listing
/// it: exactly one end-of-central-directory record ending the file, a bounded directory
/// that ends where that record begins, no ZIP64, stored or deflate entries only, no
/// encryption, links, special files, unsafe or duplicate (also Unicode-equivalent)
/// names, and local headers that repeat their directory entries (allowing data
/// descriptors) without overlapping. `verify(_:)` then requires the reading order to
/// be exactly this archive's pages. A page is inflated only up to its declared size,
/// must use all of its compressed bytes and match its CRC-32, and its image header must
/// be its declared type within `ImageProbe`'s pixel limits before anything decodes it.
public final class ComicArchive: @unchecked Sendable {
    public static let maxEntries = 10_000
    public static let maxDirectoryBytes = 2 << 20
    public static let maxImageBytes: Int64 = 32 << 20
    public static let maxTotalBytes: Int64 = 2 << 30
    public static let maxNameBytes = 1024

    /// Deflate can grow incompressible data slightly; anything beyond this isn't a page.
    public static func maxCompressedBytes(forSize size: Int64) -> Int64 {
        size + size / 100 + 1024
    }

    struct Entry {
        let name: String
        let rawName: [UInt8]
        let flags: UInt16
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int64
        let size: Int64
        let offset: Int64
        let isDirectory: Bool
        var dataStart: Int64 = 0
    }

    private static let eocdBytes = 22
    private static let centralBytes = 46
    private static let localBytes = 30
    private static let allowedFlags: UInt16 = 0x080E
    private static let descriptorFlag: UInt16 = 0x0008
    private static let utf8Flag: UInt16 = 0x0800
    private static let refusedExtras: Set<UInt16> = [0x0001, 0x7075, 0x9901]

    public let fileSize: Int64
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var entries: [Entry] = []
    private var pages: [String: Entry] = [:]
    private var verifiedOrder: ReadingOrder?

    public init(file: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: file)
            fileSize = Int64(try handle.seekToEnd())
        } catch {
            throw ComicArchiveError.unreadable
        }
        do {
            try load()
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    public func close() {
        lock.withLock { try? handle.close() }
    }

    /// The pages in order, once verified.
    public var order: ReadingOrder? { lock.withLock { verifiedOrder } }

    // MARK: Reading the file

    private func read(_ length: Int, at offset: Int64) throws -> [UInt8] {
        guard length >= 0, offset >= 0, offset + Int64(length) <= fileSize else { throw ComicArchiveError.unsupported("truncated") }
        if length == 0 { return [] }
        return try lock.withLock {
            do {
                try handle.seek(toOffset: UInt64(offset))
                var result = Data()
                while result.count < length {
                    guard let chunk = try handle.read(upToCount: length - result.count), !chunk.isEmpty else { break }
                    result.append(chunk)
                }
                guard result.count == length else { throw ComicArchiveError.unsupported("truncated") }
                return [UInt8](result)
            } catch let error as ComicArchiveError {
                throw error
            } catch {
                throw ComicArchiveError.unreadable
            }
        }
    }

    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { UInt32(u16(b, at)) | UInt32(u16(b, at + 2)) << 16 }

    // MARK: Structure

    private func load() throws {
        let (directoryOffset, count, directory) = try centralDirectory()
        entries = try parseDirectory(directory, count: count)
        try checkLocalRecords(directoryOffset: directoryOffset)
    }

    private func centralDirectory() throws -> (Int64, Int, [UInt8]) {
        guard fileSize >= Int64(Self.eocdBytes) else { throw ComicArchiveError.unsupported("too small") }
        let tailLength = Int(min(fileSize, Int64(Self.eocdBytes + 65_535)))
        let tailStart = fileSize - Int64(tailLength)
        let tail = try read(tailLength, at: tailStart)
        // Only a record whose comment reaches the end of the file; two are ambiguous.
        var candidates: [Int] = []
        var index = tail.count - Self.eocdBytes
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06,
               index + Self.eocdBytes + Int(Self.u16(tail, index + 20)) == tail.count {
                candidates.append(index)
            }
            index -= 1
        }
        guard candidates.count == 1, let record = candidates.first else { throw ComicArchiveError.unsupported("no unambiguous directory") }
        let disk = Self.u16(tail, record + 4), directoryDisk = Self.u16(tail, record + 6)
        let diskEntries = Self.u16(tail, record + 8), entries = Int(Self.u16(tail, record + 10))
        let directorySize = Int64(Self.u32(tail, record + 12)), directoryOffset = Int64(Self.u32(tail, record + 16))
        let eocdOffset = tailStart + Int64(record)
        guard disk == 0, directoryDisk == 0, Int(diskEntries) == entries, (1 ... Self.maxEntries).contains(entries),
              directorySize >= Int64(Self.centralBytes * entries), directorySize <= Int64(Self.maxDirectoryBytes),
              directoryOffset + directorySize == eocdOffset
        else { throw ComicArchiveError.unsupported("directory") }
        if eocdOffset >= 20, try read(4, at: eocdOffset - 20) == [0x50, 0x4B, 0x06, 0x07] {
            throw ComicArchiveError.unsupported("ZIP64")
        }
        return (directoryOffset, entries, try read(Int(directorySize), at: directoryOffset))
    }

    private func parseDirectory(_ directory: [UInt8], count: Int) throws -> [Entry] {
        var found: [Entry] = []
        var names: Set<String> = [] // Swift compares strings by canonical equivalence.
        var cursor = 0
        for _ in 0 ..< count {
            guard cursor + Self.centralBytes <= directory.count, Self.u32(directory, cursor) == 0x0201_4B50 else {
                throw ComicArchiveError.unsupported("directory entry")
            }
            let madeBy = Self.u16(directory, cursor + 4), needed = Self.u16(directory, cursor + 6)
            let flags = Self.u16(directory, cursor + 8), method = Self.u16(directory, cursor + 10)
            let crc = Self.u32(directory, cursor + 16)
            let compressed = Self.u32(directory, cursor + 20), size = Self.u32(directory, cursor + 24)
            let nameLength = Int(Self.u16(directory, cursor + 28)), extraLength = Int(Self.u16(directory, cursor + 30))
            let commentLength = Int(Self.u16(directory, cursor + 32)), disk = Self.u16(directory, cursor + 34)
            let external = Self.u32(directory, cursor + 38), offset = Self.u32(directory, cursor + 42)
            cursor += Self.centralBytes
            guard cursor + nameLength + extraLength + commentLength <= directory.count else { throw ComicArchiveError.unsupported("directory entry") }
            let raw = Array(directory[cursor ..< cursor + nameLength])
            let extras = Array(directory[cursor + nameLength ..< cursor + nameLength + extraLength])
            cursor += nameLength + extraLength + commentLength
            guard flags & ~Self.allowedFlags == 0, method == 0 || method == 8, needed & 0xFF <= 45, disk == 0,
                  ![compressed, size, offset].contains(0xFFFF_FFFF), method == 8 || compressed == size,
                  Self.safeExtras(extras)
            else { throw ComicArchiveError.unsupported("ZIP features") }
            if madeBy >> 8 == 3 {
                let type = (external >> 16) & 0o170000
                guard type == 0 || type == 0o100000 || type == 0o040000 else { throw ComicArchiveError.unsupported("link or special file") }
            }
            let name = try Self.entryName(raw, flags)
            let isDirectory = name.hasSuffix("/")
            guard !isDirectory || size == 0 else { throw ComicArchiveError.unsupported("folder with data") }
            guard names.insert(name).inserted else { throw ComicArchiveError.unsupported("duplicate name") }
            found.append(Entry(name: name, rawName: raw, flags: flags, method: method, crc: crc,
                               compressedSize: Int64(compressed), size: Int64(size), offset: Int64(offset), isDirectory: isDirectory))
        }
        guard cursor == directory.count else { throw ComicArchiveError.unsupported("directory data") }
        return found
    }

    /// UTF-8 when flagged, otherwise ASCII only. No absolute, drive, backslash, control,
    /// empty, `.` or `..` parts.
    static func entryName(_ raw: [UInt8], _ flags: UInt16) throws -> String {
        guard (1 ... maxNameBytes).contains(raw.count) else { throw ComicArchiveError.unsupported("name length") }
        guard flags & utf8Flag != 0 || raw.allSatisfy({ $0 < 0x80 }) else { throw ComicArchiveError.unsupported("name encoding") }
        var scalars = String.UnicodeScalarView()
        var iterator = raw.makeIterator()
        var codec = UTF8()
        decoding: while true {
            switch codec.decode(&iterator) {
            case let .scalarValue(scalar): scalars.append(scalar)
            case .emptyInput: break decoding
            case .error: throw ComicArchiveError.unsupported("name encoding")
            }
        }
        let name = String(scalars)
        let forbidden = name.unicodeScalars.contains { $0 == "\\" || $0 == ":" || $0.value < 0x20 || $0.value == 0x7F }
        let trimmed = name.hasSuffix("/") ? String(name.dropLast()) : name
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !forbidden, !name.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ComicArchiveError.unsupported("unsafe name")
        }
        return name
    }

    private static func safeExtras(_ extras: [UInt8]) -> Bool {
        var cursor = 0
        while cursor < extras.count {
            guard cursor + 4 <= extras.count else { return false }
            let id = u16(extras, cursor), length = Int(u16(extras, cursor + 2))
            guard !refusedExtras.contains(id), cursor + 4 + length <= extras.count else { return false }
            cursor += 4 + length
        }
        return true
    }

    private func checkLocalRecords(directoryOffset: Int64) throws {
        var ranges: [(Int64, Int64)] = []
        for index in entries.indices {
            let entry = entries[index]
            let header = try read(Self.localBytes, at: entry.offset)
            let flags = Self.u16(header, 6), method = Self.u16(header, 8)
            let crc = Self.u32(header, 14), compressed = Int64(Self.u32(header, 18)), size = Int64(Self.u32(header, 22))
            let nameLength = Int(Self.u16(header, 26)), extraLength = Int(Self.u16(header, 28))
            let descriptor = entry.flags & Self.descriptorFlag != 0
            let stated = (crc, compressed, size)
            let central = (entry.crc, entry.compressedSize, entry.size)
            let sizesAgree = descriptor
                ? (stated == (0, 0, 0) || stated == central)
                : stated == central
            guard Self.u32(header, 0) == 0x0403_4B50, flags == entry.flags, method == entry.method,
                  nameLength == entry.rawName.count, sizesAgree,
                  try read(nameLength, at: entry.offset + Int64(Self.localBytes)) == entry.rawName,
                  Self.safeExtras(try read(extraLength, at: entry.offset + Int64(Self.localBytes + nameLength)))
            else { throw ComicArchiveError.unsupported("local header") }
            let dataStart = entry.offset + Int64(Self.localBytes + nameLength + extraLength)
            let dataEnd = dataStart + entry.compressedSize
            var finish = dataEnd
            if descriptor {
                // The descriptor repeats the directory's CRC and sizes, with or without its signature.
                guard dataEnd + 12 <= directoryOffset else { throw ComicArchiveError.unsupported("data descriptor") }
                let available = Int(min(16, directoryOffset - dataEnd))
                let trailer = try read(available, at: dataEnd)
                let plain = (Self.u32(trailer, 0), Int64(Self.u32(trailer, 4)), Int64(Self.u32(trailer, 8)))
                if plain == central {
                    finish = dataEnd + 12
                } else if available == 16, Self.u32(trailer, 0) == 0x0807_4B50,
                          (Self.u32(trailer, 4), Int64(Self.u32(trailer, 8)), Int64(Self.u32(trailer, 12))) == central {
                    finish = dataEnd + 16
                } else {
                    throw ComicArchiveError.unsupported("data descriptor")
                }
            }
            guard finish <= directoryOffset else { throw ComicArchiveError.unsupported("entry overlaps the directory") }
            entries[index].dataStart = dataStart
            ranges.append((entry.offset, finish))
        }
        ranges.sort { $0.0 < $1.0 }
        for (previous, next) in zip(ranges, ranges.dropFirst()) where next.0 < previous.1 {
            throw ComicArchiveError.unsupported("overlapping entries")
        }
    }

    /// Operating-system metadata, such as macOS `._` files, is not a page.
    private static func hidden(_ name: String) -> Bool {
        name.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
    }

    /// The archive's page entries by escaped href: images outside hidden folders, within the caps.
    func pageEntries() throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        var total: Int64 = 0
        for entry in entries where !entry.isDirectory && !Self.hidden(entry.name) {
            guard ComicNames.mediaType(forName: entry.rawName) != nil else { continue }
            guard (1 ... Self.maxImageBytes).contains(entry.size) else { throw ComicArchiveError.unsupported("page size") }
            total += entry.size
            guard total <= Self.maxTotalBytes else { throw ComicArchiveError.unsupported("total size") }
            result[ComicNames.escape(entry.rawName)] = entry
        }
        guard !result.isEmpty else { throw ComicArchiveError.unsupported("no pages") }
        return result
    }

    // MARK: Pages

    /// Requires `order` to list exactly this archive's pages with their directory's sizes,
    /// methods, offsets and CRCs. Only then can pages be read.
    public func verify(_ order: ReadingOrder) throws {
        let available = try pageEntries()
        guard order.items.count == available.count else { throw ComicArchiveError.orderMismatch("page count") }
        for item in order.items {
            guard let entry = available[item.href] else { throw ComicArchiveError.orderMismatch("href") }
            guard ComicNames.mediaType(forName: entry.rawName) == item.mediaType, entry.size == item.sizeBytes,
                  entry.compressedSize == item.compressedSize, Int(entry.method) == item.compressionMethod,
                  entry.offset == item.localHeaderOffset, item.crcValue == entry.crc,
                  entry.compressedSize <= Self.maxCompressedBytes(forSize: entry.size)
            else { throw ComicArchiveError.orderMismatch("page \(item.position)") }
        }
        lock.withLock {
            pages = available
            verifiedOrder = order
        }
    }

    /// The verified bytes of one page of the verified order.
    public func page(_ position: Int) throws -> Data {
        let (item, entry): (ReadingOrder.Item, Entry) = try lock.withLock {
            guard let order = verifiedOrder, order.items.indices.contains(position - 1),
                  let entry = pages[order.items[position - 1].href]
            else { throw ComicArchiveError.orderMismatch("unverified") }
            return (order.items[position - 1], entry)
        }
        let compressed = Data(try read(Int(entry.compressedSize), at: entry.dataStart))
        let data: Data
        if entry.method == 0 {
            data = compressed
        } else {
            do {
                data = try Inflate.decode(compressed, expectedSize: Int(entry.size))
            } catch {
                throw ComicArchiveError.damagedPage(position)
            }
        }
        guard Int64(data.count) == entry.size, CRC32.checksum(data) == entry.crc else { throw ComicArchiveError.damagedPage(position) }
        guard let probe = ImageProbe.probe(data), probe.mediaType == item.mediaType, probe.withinLimits else {
            throw ComicArchiveError.unsupportedImage(position)
        }
        return data
    }

    /// Opens `file` and checks it against `order`, closing it again on failure.
    public static func open(_ file: URL, order: ReadingOrder) throws -> ComicArchive {
        let archive = try ComicArchive(file: file)
        do {
            try archive.verify(order)
        } catch {
            archive.close()
            throw error
        }
        return archive
    }
}
