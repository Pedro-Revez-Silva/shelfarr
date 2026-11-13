import Foundation

/// CRC-32 (ISO-HDLC, as ZIP uses it).
public enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0 ..< 8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    public static func checksum(_ data: Data, initial: UInt32 = 0) -> UInt32 {
        var crc = ~initial
        table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return ~crc
    }
}

/// A raw DEFLATE (RFC 1951) decoder for one ZIP entry, bounded by the size the entry
/// declares. It is plain Swift so the same code runs, and is tested, on every platform.
///
/// It refuses rather than repairs: more output than declared, less, input left over
/// after the final block, a truncated stream, invalid or over-subscribed codes and
/// distances before the start of the output all fail. Nothing is allocated beyond the
/// declared size.
public enum Inflate {
    public enum Failure: Error, Equatable, Sendable {
        case truncated
        case invalid(String)
        case tooLong
        case tooShort
        case trailingData
    }

    public static func decode(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw Failure.invalid("size") }
        var output = Data(count: expectedSize)
        let written = try output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                var decoder = Decoder(input: source, output: out)
                try decoder.run()
                return decoder.written
            }
        }
        guard written == expectedSize else { throw Failure.tooShort }
        return output
    }

    // MARK: Tables

    fileprivate static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    fileprivate static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    fileprivate static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    fileprivate static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    fileprivate static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    fileprivate static let fixedLiterals: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for index in 144 ..< 256 { lengths[index] = 9 }
        for index in 256 ..< 280 { lengths[index] = 7 }
        // Codes 286 and 287 exist in the fixed code but never appear in valid data.
        return try! Huffman(lengths: lengths)
    }()

    fileprivate static let fixedDistances: Huffman = try! Huffman(lengths: [Int](repeating: 5, count: 32))

    /// A canonical Huffman code as one lookup table indexed by the next `maxBits` input
    /// bits (least significant first, as DEFLATE packs them).
    fileprivate struct Huffman {
        /// symbol << 4 | length; 0 marks a bit pattern no code uses.
        let table: [UInt32]
        let maxBits: Int

        init(lengths: [Int]) throws {
            let maxBits = max(1, lengths.max() ?? 0)
            guard maxBits <= 15 else { throw Failure.invalid("code length") }
            var counts = [Int](repeating: 0, count: 16)
            for length in lengths where length > 0 { counts[length] += 1 }
            // Over-subscribed codes are refused; incomplete ones only fail if an unused pattern appears.
            var left = 1
            for bits in 1 ... 15 {
                left = left * 2 - counts[bits]
                if left < 0 { throw Failure.invalid("over-subscribed code") }
            }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for bits in 1 ... 15 {
                code = (code + counts[bits - 1]) << 1
                next[bits] = code
            }
            var table = [UInt32](repeating: 0, count: 1 << maxBits)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let assigned = next[length]
                next[length] += 1
                var reversed = 0
                for bit in 0 ..< length where assigned & (1 << bit) != 0 { reversed |= 1 << (length - 1 - bit) }
                let entry = UInt32(symbol) << 4 | UInt32(length)
                var index = reversed
                while index < table.count {
                    table[index] = entry
                    index += 1 << length
                }
            }
            self.table = table
            self.maxBits = maxBits
        }
    }

    // MARK: Decoder

    private struct Decoder {
        let input: UnsafeRawBufferPointer
        let output: UnsafeMutableRawBufferPointer
        var position = 0
        var bits: UInt64 = 0
        var count = 0
        var written = 0

        init(input: UnsafeRawBufferPointer, output: UnsafeMutableRawBufferPointer) {
            self.input = input
            self.output = output
        }

        mutating func refill() {
            while count <= 56, position < input.count {
                bits |= UInt64(input[position]) << UInt64(count)
                position += 1
                count += 8
            }
        }

        mutating func take(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            if count < n { refill() }
            guard count >= n else { throw Failure.truncated }
            let value = Int(bits & ((1 << UInt64(n)) - 1))
            bits >>= UInt64(n)
            count -= n
            return value
        }

        mutating func symbol(_ code: Huffman) throws -> Int {
            if count < code.maxBits { refill() }
            let entry = code.table[Int(bits & ((1 << UInt64(code.maxBits)) - 1))]
            let length = Int(entry & 0xF)
            guard length > 0 else { throw Failure.invalid("unused code") }
            guard length <= count else { throw Failure.truncated }
            bits >>= UInt64(length)
            count -= length
            return Int(entry >> 4)
        }

        mutating func emit(_ byte: UInt8) throws {
            guard written < output.count else { throw Failure.tooLong }
            output[written] = byte
            written += 1
        }

        mutating func run() throws {
            var final = false
            while !final {
                final = try take(1) == 1
                switch try take(2) {
                case 0: try stored()
                case 1: try compressed(Inflate.fixedLiterals, Inflate.fixedDistances)
                case 2:
                    let (literals, distances) = try dynamicCodes()
                    try compressed(literals, distances)
                default: throw Failure.invalid("block type")
                }
            }
            // Only the final byte's padding may be left; any further byte is not this entry.
            guard position == input.count, count < 8 else { throw Failure.trailingData }
        }

        mutating func stored() throws {
            // Skip to a byte boundary, then LEN and its complement.
            _ = try take(count % 8)
            let length = try take(16)
            let complement = try take(16)
            guard length == ~complement & 0xFFFF else { throw Failure.invalid("stored length") }
            var remaining = length
            // Whole bytes already buffered first, then straight from the input.
            while remaining > 0, count >= 8 {
                try emit(UInt8(try take(8)))
                remaining -= 1
            }
            guard remaining <= input.count - position else { throw Failure.truncated }
            guard remaining <= output.count - written else { throw Failure.tooLong }
            if remaining > 0 {
                output.baseAddress!.advanced(by: written).copyMemory(from: input.baseAddress!.advanced(by: position), byteCount: remaining)
                written += remaining
                position += remaining
            }
        }

        mutating func compressed(_ literals: Huffman, _ distances: Huffman) throws {
            while true {
                let symbol = try self.symbol(literals)
                if symbol < 256 {
                    try emit(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                let index = symbol - 257
                guard index < Inflate.lengthBase.count else { throw Failure.invalid("length code") }
                let length = Inflate.lengthBase[index] + (try take(Inflate.lengthExtra[index]))
                let code = try self.symbol(distances)
                guard code < Inflate.distanceBase.count else { throw Failure.invalid("distance code") }
                let distance = Inflate.distanceBase[code] + (try take(Inflate.distanceExtra[code]))
                guard distance <= written else { throw Failure.invalid("distance") }
                guard length <= output.count - written else { throw Failure.tooLong }
                // Byte by byte: a copy may overlap the bytes it produces.
                var from = written - distance
                for _ in 0 ..< length {
                    output[written] = output[from]
                    written += 1
                    from += 1
                }
            }
        }

        mutating func dynamicCodes() throws -> (Huffman, Huffman) {
            let literalCount = try take(5) + 257
            let distanceCount = try take(5) + 1
            let lengthCount = try take(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalid("code counts") }
            var codeLengths = [Int](repeating: 0, count: 19)
            for index in 0 ..< lengthCount { codeLengths[Inflate.codeLengthOrder[index]] = try take(3) }
            let lengthCode = try Huffman(lengths: codeLengths)
            var lengths: [Int] = []
            lengths.reserveCapacity(literalCount + distanceCount)
            while lengths.count < literalCount + distanceCount {
                let symbol = try self.symbol(lengthCode)
                switch symbol {
                case 0 ... 15:
                    lengths.append(symbol)
                case 16:
                    guard let previous = lengths.last else { throw Failure.invalid("repeat without a length") }
                    lengths += [Int](repeating: previous, count: 3 + (try take(2)))
                case 17:
                    lengths += [Int](repeating: 0, count: 3 + (try take(3)))
                default:
                    lengths += [Int](repeating: 0, count: 11 + (try take(7)))
                }
            }
            guard lengths.count == literalCount + distanceCount else { throw Failure.invalid("too many lengths") }
            let literalLengths = Array(lengths[0 ..< literalCount])
            guard literalLengths[256] > 0 else { throw Failure.invalid("no end of block") }
            return (try Huffman(lengths: literalLengths), try Huffman(lengths: Array(lengths[literalCount...])))
        }
    }
}

// MARK: Streaming

extension Inflate {
    /// Decodes one raw DEFLATE entry from `read` to `write` without holding it in memory:
    /// a 32 KiB window and small buffers only, so a narration file of any size inside an
    /// EPUB can be copied out. The same refusals as `decode(_:expectedSize:)` apply:
    /// more or less output than `expectedSize`, compressed bytes left over after the
    /// final block, truncation, invalid codes and distances before the start.
    ///
    /// - Parameters:
    ///   - compressedSize: the entry's compressed length; exactly this much is read.
    ///   - read: returns up to the given number of further compressed bytes (never more).
    ///   - write: receives the output in order, in chunks of at most 64 KiB.
    /// - Returns: the CRC-32 of the output.
    public static func stream(compressedSize: Int64, expectedSize: Int64, read: (Int) throws -> Data, write: (Data) throws -> Void) throws -> UInt32 {
        guard compressedSize >= 0, expectedSize >= 0 else { throw Failure.invalid("size") }
        return try withoutActuallyEscaping(read) { read in
            try withoutActuallyEscaping(write) { write in
                var decoder = StreamDecoder(remaining: compressedSize, expected: expectedSize, read: read, write: write)
                try decoder.run()
                try decoder.flush()
                guard decoder.written == expectedSize else { throw Failure.tooShort }
                return decoder.crc
            }
        }
    }

    private struct StreamDecoder {
        static let windowSize = 1 << 15
        static let chunk = 1 << 16

        var remaining: Int64
        let expected: Int64
        let read: (Int) throws -> Data
        let write: (Data) throws -> Void
        var input: [UInt8] = []
        var position = 0
        var bits: UInt64 = 0
        var count = 0
        var window = [UInt8](repeating: 0, count: windowSize)
        var pending: [UInt8] = []
        var written: Int64 = 0
        var crc: UInt32 = 0

        init(remaining: Int64, expected: Int64, read: @escaping (Int) throws -> Data, write: @escaping (Data) throws -> Void) {
            self.remaining = remaining
            self.expected = expected
            self.read = read
            self.write = write
            pending.reserveCapacity(Self.chunk)
        }

        /// Fetches the next compressed chunk when the buffer is used up. False at the end.
        mutating func more() throws -> Bool {
            guard position == input.count else { return true }
            guard remaining > 0 else { return false }
            let next = try read(Int(min(remaining, Int64(Self.chunk))))
            guard !next.isEmpty, Int64(next.count) <= remaining else { throw Failure.truncated }
            remaining -= Int64(next.count)
            input = [UInt8](next)
            position = 0
            return true
        }

        mutating func refill() throws {
            while count <= 56 {
                guard try more() else { return }
                bits |= UInt64(input[position]) << UInt64(count)
                position += 1
                count += 8
            }
        }

        mutating func take(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            if count < n { try refill() }
            guard count >= n else { throw Failure.truncated }
            let value = Int(bits & ((1 << UInt64(n)) - 1))
            bits >>= UInt64(n)
            count -= n
            return value
        }

        mutating func symbol(_ code: Huffman) throws -> Int {
            if count < code.maxBits { try refill() }
            let entry = code.table[Int(bits & ((1 << UInt64(code.maxBits)) - 1))]
            let length = Int(entry & 0xF)
            guard length > 0 else { throw Failure.invalid("unused code") }
            guard length <= count else { throw Failure.truncated }
            bits >>= UInt64(length)
            count -= length
            return Int(entry >> 4)
        }

        mutating func emit(_ byte: UInt8) throws {
            guard written < expected else { throw Failure.tooLong }
            window[Int(written & Int64(Self.windowSize - 1))] = byte
            written += 1
            pending.append(byte)
            if pending.count >= Self.chunk { try flush() }
        }

        mutating func flush() throws {
            guard !pending.isEmpty else { return }
            let data = Data(pending)
            crc = CRC32.checksum(data, initial: crc)
            try write(data)
            pending.removeAll(keepingCapacity: true)
        }

        mutating func run() throws {
            var final = false
            while !final {
                final = try take(1) == 1
                switch try take(2) {
                case 0: try stored()
                case 1: try compressed(Inflate.fixedLiterals, Inflate.fixedDistances)
                case 2:
                    let (literals, distances) = try dynamicCodes()
                    try compressed(literals, distances)
                default: throw Failure.invalid("block type")
                }
            }
            // Only the final byte's padding may be left; any further byte is not this entry.
            guard remaining == 0, position == input.count, count < 8 else { throw Failure.trailingData }
        }

        mutating func stored() throws {
            _ = try take(count % 8)
            let length = try take(16)
            let complement = try take(16)
            guard length == ~complement & 0xFFFF else { throw Failure.invalid("stored length") }
            var left = length
            while left > 0, count >= 8 {
                try emit(UInt8(try take(8)))
                left -= 1
            }
            while left > 0 {
                guard try more() else { throw Failure.truncated }
                let available = min(left, input.count - position)
                for index in position ..< position + available { try emit(input[index]) }
                position += available
                left -= available
            }
        }

        mutating func compressed(_ literals: Huffman, _ distances: Huffman) throws {
            let mask = Int64(Self.windowSize - 1)
            while true {
                let symbol = try self.symbol(literals)
                if symbol < 256 {
                    try emit(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                let index = symbol - 257
                guard index < Inflate.lengthBase.count else { throw Failure.invalid("length code") }
                let length = Inflate.lengthBase[index] + (try take(Inflate.lengthExtra[index]))
                let code = try self.symbol(distances)
                guard code < Inflate.distanceBase.count else { throw Failure.invalid("distance code") }
                let distance = Int64(Inflate.distanceBase[code] + (try take(Inflate.distanceExtra[code])))
                guard distance <= written, distance <= Int64(Self.windowSize) else { throw Failure.invalid("distance") }
                guard Int64(length) <= expected - written else { throw Failure.tooLong }
                for _ in 0 ..< length {
                    try emit(window[Int((written - distance) & mask)])
                }
            }
        }

        mutating func dynamicCodes() throws -> (Huffman, Huffman) {
            let literalCount = try take(5) + 257
            let distanceCount = try take(5) + 1
            let lengthCount = try take(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalid("code counts") }
            var codeLengths = [Int](repeating: 0, count: 19)
            for index in 0 ..< lengthCount { codeLengths[Inflate.codeLengthOrder[index]] = try take(3) }
            let lengthCode = try Huffman(lengths: codeLengths)
            var lengths: [Int] = []
            lengths.reserveCapacity(literalCount + distanceCount)
            while lengths.count < literalCount + distanceCount {
                let symbol = try self.symbol(lengthCode)
                switch symbol {
                case 0 ... 15:
                    lengths.append(symbol)
                case 16:
                    guard let previous = lengths.last else { throw Failure.invalid("repeat without a length") }
                    lengths += [Int](repeating: previous, count: 3 + (try take(2)))
                case 17:
                    lengths += [Int](repeating: 0, count: 3 + (try take(3)))
                default:
                    lengths += [Int](repeating: 0, count: 11 + (try take(7)))
                }
            }
            guard lengths.count == literalCount + distanceCount else { throw Failure.invalid("too many lengths") }
            let literalLengths = Array(lengths[0 ..< literalCount])
            guard literalLengths[256] > 0 else { throw Failure.invalid("no end of block") }
            return (try Huffman(lengths: literalLengths), try Huffman(lengths: Array(lengths[literalCount...])))
        }
    }
}
