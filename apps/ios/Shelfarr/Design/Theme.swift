import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

private func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
}

/// Mirror of `apps/design/tokens.json`. `apps/scripts/check-design-tokens.py` fails
/// the build when these values drift from that file.
enum Palette {
    static let background = dynamic(0xFBF7F0, 0x16130F)
    static let surface = dynamic(0xFFFDF9, 0x211C17)
    static let sunken = dynamic(0xF3ECE0, 0x0F0D0A)
    static let ink = dynamic(0x211C16, 0xF2EADD)
    static let inkMuted = dynamic(0x665B4E, 0xB3A797)
    static let hairline = dynamic(0xE6DCCB, 0x38302A)
    static let accent = dynamic(0xA33A22, 0xEE9270)
    static let onAccent = dynamic(0xFFF9F2, 0x2B1208)
    static let accentSoft = dynamic(0xF6E3D8, 0x3D261C)
    static let danger = dynamic(0x9B1C1C, 0xF2A3A3)

    /// Backgrounds for generated covers, chosen by `coverSwatchIndex`.
    static let coverSwatches: [Color] = [
        Color(hex: 0x6E2A20), Color(hex: 0x3F4A30), Color(hex: 0x26384A),
        Color(hex: 0x7A5518), Color(hex: 0x4E2F44), Color(hex: 0x3F4649),
    ]
    static let coverInk = Color(hex: 0xF7EFE2)
}

/// FNV-1a over UTF-8, so a book gets the same generated cover on every client.
func coverSwatchIndex(_ id: String) -> Int {
    var hash: UInt32 = 0x811C_9DC5
    for byte in id.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    return Int(hash % UInt32(Palette.coverSwatches.count))
}

/// Serif for titles and long text, the system face for everything functional. All
/// sizes follow Dynamic Type.
enum Typeface {
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("NewsreaderDisplay-Medium", size: size, relativeTo: style)
    }

    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Newsreader-Regular", size: size, relativeTo: style)
    }

    static func serifBold(_ size: CGFloat, relativeTo style: Font.TextStyle = .headline) -> Font {
        .custom("Newsreader-SemiBold", size: size, relativeTo: style)
    }
}

enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system, light, dark

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "Match this device"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
