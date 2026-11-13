import Foundation

/// When a reading or listening checkpoint actually happened: the wire's `observed_at`.
///
/// Times travel as ISO-8601 UTC with milliseconds and are compared as epoch
/// milliseconds. A time is trusted for ordering only when it is well formed and
/// plausible: not before `earliest` (a clock that was never set) and not more than
/// `futureTolerance` ahead of this device, which matches the server's limit.
public enum ActivityTime {
    public static let futureTolerance: Int64 = 5 * 60_000

    /// 2000-01-01T00:00:00Z.
    public static let earliest: Int64 = 946_684_800_000

    /// This device's wall clock, in epoch milliseconds.
    public static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// `2026-11-07T09:15:30.123Z`.
    public static func format(_ epochMs: Int64) -> String {
        let millis = Int(((epochMs % 1000) + 1000) % 1000)
        let seconds = (epochMs - Int64(millis)) / 1000
        var days = seconds / 86400
        var rest = seconds % 86400
        if rest < 0 {
            rest += 86400
            days -= 1
        }
        let (year, month, day) = civil(fromDays: days)
        func pad(_ value: Int64, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(year, 4))-\(pad(Int64(month), 2))-\(pad(Int64(day), 2))T"
            + "\(pad(rest / 3600, 2)):\(pad(rest % 3600 / 60, 2)):\(pad(rest % 60, 2)).\(pad(Int64(millis), 3))Z"
    }

    /// Epoch milliseconds, or nil when `value` is missing or not a zoned ISO-8601 time
    /// with seconds. Fractions beyond milliseconds are truncated.
    public static func parse(_ value: String?) -> Int64? {
        guard let value else { return nil }
        var scanner = Scanner(Array(value.utf8))
        guard let year = scanner.digits(4), scanner.take(UInt8(ascii: "-")),
              let month = scanner.digits(2), scanner.take(UInt8(ascii: "-")),
              let day = scanner.digits(2), scanner.take(UInt8(ascii: "T")),
              let hour = scanner.digits(2), scanner.take(UInt8(ascii: ":")),
              let minute = scanner.digits(2), scanner.take(UInt8(ascii: ":")),
              let second = scanner.digits(2)
        else { return nil }
        var millis: Int64 = 0
        if scanner.take(UInt8(ascii: ".")) {
            var count = 0
            while let digit = scanner.digit() {
                count += 1
                if count <= 3 { millis = millis * 10 + Int64(digit) }
            }
            guard (1 ... 9).contains(count) else { return nil }
            if count < 3 {
                for _ in count ..< 3 { millis *= 10 }
            }
        }
        var offsetMinutes: Int64 = 0
        if scanner.take(UInt8(ascii: "Z")) {
            offsetMinutes = 0
        } else if let sign = scanner.sign() {
            guard let hours = scanner.digits(2), scanner.take(UInt8(ascii: ":")), let minutes = scanner.digits(2),
                  hours <= 23, minutes <= 59
            else { return nil }
            offsetMinutes = sign * (hours * 60 + minutes)
        } else {
            return nil
        }
        guard scanner.atEnd,
              (1 ... 12).contains(month), day >= 1, day <= daysIn(month: month, year: year),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }
        let days = Self.days(fromCivil: year, month, day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetMinutes * 60
        return seconds * 1000 + millis
    }

    /// True when `epochMs` can be trusted to order activity against this device's `now`.
    public static func isPlausible(_ epochMs: Int64?, now: Int64) -> Bool {
        guard let epochMs else { return false }
        return epochMs >= earliest && epochMs <= now + futureTolerance
    }

    /// The time to record for a new local observation. Activity on one device happens in
    /// order, so a clock that stepped back a little (or an adopted place stamped by a
    /// slightly fast clock elsewhere) must not make the newer place look older.
    public static func next(_ observed: Int64, after previous: Int64?) -> Int64 {
        if let previous, previous >= observed, previous <= observed + futureTolerance { return previous + 1 }
        return observed
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Howard Hinnant's days-from-civil and its inverse, for the proleptic Gregorian calendar.
    private static func days(fromCivil year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays value: Int64) -> (Int64, Int, Int) {
        let z = value + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), Int(month), Int(day))
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index == bytes.count }

        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func digit() -> Int? {
            guard index < bytes.count, (48 ... 57).contains(bytes[index]) else { return nil }
            index += 1
            return Int(bytes[index - 1] - 48)
        }

        mutating func digits(_ count: Int) -> Int64? {
            var value: Int64 = 0
            for _ in 0 ..< count {
                guard let digit = digit() else { return nil }
                value = value * 10 + Int64(digit)
            }
            return value
        }

        mutating func sign() -> Int64? {
            if take(UInt8(ascii: "+")) { return 1 }
            if take(UInt8(ascii: "-")) { return -1 }
            return nil
        }
    }
}
