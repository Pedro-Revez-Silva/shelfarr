import Foundation

/// A format this app's reader opens. Audio is played, not read, and is not one of these.
///
/// The app declares all three with `X-Shelfarr-Reader-Formats` on library listings,
/// details, Continue and status changes. A server that predates the header ignores it
/// and keeps offering only EPUB files for books, so nothing changes against it.
public enum ReaderFormat: String, Codable, CaseIterable, Sendable {
    case epub, pdf, cbz

    public static let header = "X-Shelfarr-Reader-Formats"
    public static let declared = "epub,pdf,cbz"

    public static let pdfMediaType = "application/pdf"
    public static let cbzMediaType = "application/vnd.comicbook+zip"
    /// The server's caps; a larger file is never offered.
    public static let maxPDFBytes: Int64 = 500 << 20
    public static let maxCBZBytes: Int64 = 2 << 30

    /// Pages laid out by the file itself: no reflowing text, no font settings.
    public var isFixedLayout: Bool { self != .epub }

    public var label: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .cbz: return "Comic (CBZ)"
        }
    }
}

/// Which format the reader opens, decided before anything is shown.
///
/// 1. A saved place keeps its own format: a place in the PDF opens the PDF.
/// 2. Otherwise a ready download's format.
/// 3. Otherwise the only format there is.
/// 4. With several formats and nothing to go on, the reader asks.
///
/// Offline, a saved place in a format that isn't on this device offers the formats that
/// are, rather than a dead end; the place itself stays saved.
public enum FormatDecision: Equatable, Sendable {
    case open(ReaderFormat)
    /// Several formats and nothing to choose by. The suggested one is first.
    case ask([ReaderFormat])
    /// The saved place is in `saved`, which can't be opened without the server; these can.
    case savedFormatUnavailable(saved: ReaderFormat, alternatives: [ReaderFormat])

    /// - Parameters:
    ///   - placeAssetId: the asset of the place the reader will restore, if any.
    ///   - readyDownload: the format of this publication's finished download, if any.
    ///   - local: formats with a complete copy on this device (download or reading cache).
    public static func decide(
        publication: Publication,
        placeAssetId: String?,
        readyDownload: ReaderFormat?,
        local: Set<ReaderFormat>,
        offline: Bool
    ) -> FormatDecision? {
        let formats = publication.readerFormats
        guard !formats.isEmpty else { return nil }
        let suggested = suggestedOrder(publication).filter(formats.contains)
        if let placeAssetId, let saved = publication.readableAssets.first(where: { $0.id == placeAssetId })?.readerFormat {
            if offline, !local.contains(saved) {
                let alternatives = suggested.filter { $0 != saved && local.contains($0) }
                if !alternatives.isEmpty { return .savedFormatUnavailable(saved: saved, alternatives: alternatives) }
            }
            return .open(saved)
        }
        if let readyDownload, formats.contains(readyDownload) { return .open(readyDownload) }
        if formats.count == 1 { return .open(formats[0]) }
        if offline {
            let here = suggested.filter(local.contains)
            if here.count == 1 { return .open(here[0]) }
            if !here.isEmpty { return .ask(here) }
        }
        return .ask(suggested)
    }

    /// Comics suggest their page images first, other books their text.
    public static func suggestedOrder(_ publication: Publication) -> [ReaderFormat] {
        publication.isGraphic ? [.cbz, .pdf, .epub] : [.epub, .pdf, .cbz]
    }
}

/// True when `head`, the first bytes of a file, carry a `%PDF-x.y` header within 1 KiB.
public enum PDFSniff {
    public static let window = 1024

    public static func hasHeader(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(window))
        let marker = Array("%PDF-".utf8)
        guard bytes.count >= marker.count + 3 else { return false }
        for start in 0 ... bytes.count - marker.count - 3 where Array(bytes[start ..< start + marker.count]) == marker {
            let version = bytes[(start + marker.count)...]
            let digits = Array(version.prefix(3))
            if digits.count == 3, (0x30 ... 0x39).contains(digits[0]), digits[1] == 0x2E, (0x30 ... 0x39).contains(digits[2]) {
                return true
            }
        }
        return false
    }

    public static func hasHeader(file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return hasHeader((try? handle.read(upToCount: window)) ?? Data())
    }
}
