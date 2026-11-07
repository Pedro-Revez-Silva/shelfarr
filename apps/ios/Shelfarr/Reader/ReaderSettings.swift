import Foundation
import SwiftUI

/// Page colours. These apply to the book and its chrome, independent of the app theme.
enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case paper, sepia, night

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    private var swatch: (page: UInt32, text: UInt32, muted: UInt32, bar: UInt32, hairline: UInt32, accent: UInt32) {
        switch self {
        case .paper: return (0xFBF7F0, 0x2A241D, 0x665B4E, 0xFFFDF9, 0xE6DCCB, 0xA33A22)
        case .sepia: return (0xF0E5D0, 0x3A2E21, 0x65553F, 0xF7EEDD, 0xDCCDB1, 0x96351F)
        case .night: return (0x16130F, 0xD9CFC0, 0xA99D8D, 0x211C17, 0x38302A, 0xEE9270)
        }
    }

    var pageHex: UInt32 { swatch.page }
    var textHex: UInt32 { swatch.text }

    var page: Color { Color(hex: pageHex) }
    var text: Color { Color(hex: textHex) }
    var muted: Color { Color(hex: swatch.muted) }
    var bar: Color { Color(hex: swatch.bar) }
    var hairline: Color { Color(hex: swatch.hairline) }
    var accent: Color { Color(hex: swatch.accent) }
}

enum ReaderFont: String, Codable, CaseIterable, Identifiable {
    case newsreader, sans, original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newsreader: return "Newsreader"
        case .sans: return "Sans"
        case .original: return "Book's own"
        }
    }
}

struct ReaderSettings: Codable, Equatable {
    var theme = ReaderTheme.paper
    var font = ReaderFont.newsreader
    var fontSize = 1.0
    var lineHeight = 1.5
    var margins = 1.0
    var justify = false
    var scroll = false
}

/// Display preferences only, so UserDefaults is the right home.
@MainActor
final class ReaderSettingsStore: ObservableObject {
    @Published var settings: ReaderSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private static let key = "reader_settings"

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReaderSettings.self, from: $0) } ?? ReaderSettings()
    }
}
