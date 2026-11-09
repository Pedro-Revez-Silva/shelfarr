import ShelfarrCore
import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.accent.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A quiet centred message for empty and failed screens.
struct MessageState: View {
    let title: String
    let message: String
    var systemImage: String?
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage).font(.title2).foregroundStyle(Palette.inkMuted)
            }
            Text(title).font(Typeface.display(22)).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
            Text(message).font(.subheadline).foregroundStyle(Palette.inkMuted).multilineTextAlignment(.center)
            if let action, let onAction {
                Button(action, action: onAction).buttonStyle(.bordered).tint(Palette.accent).padding(.top, 10)
            }
        }
        .frame(maxWidth: 360)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reading progress as a thin rule, the only "data" a cover ever carries.
struct ProgressRule: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule().fill(Palette.accent).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

struct ErrorCopy {
    let title: String
    let message: String
    var retryable = true
}

/// Plain-language wording for every failure a screen can show.
func errorCopy(_ error: Error, host: String?) -> ErrorCopy {
    let server = host ?? "your server"
    switch error as? APIError {
    case let .offline(certificate):
        if certificate {
            return ErrorCopy(title: "Can't verify this server", message: "The security certificate for \(server) couldn't be trusted.")
        }
        return ErrorCopy(title: "Can't reach \(server)", message: "Check your connection, or whether the server is up, and try again.")
    case let .server(status):
        return ErrorCopy(title: "\(server) had a problem", message: "It answered with error \(status). Try again in a moment.")
    case .notFound:
        return ErrorCopy(title: "Not available", message: "This isn't on \(server) any more.", retryable: false)
    case .forbidden:
        return ErrorCopy(title: "Not allowed", message: "This account doesn't have access to that.", retryable: false)
    case .unauthorized:
        return ErrorCopy(title: "Signed out", message: "Your sign-in has ended.", retryable: false)
    case let .redirectBlocked(location):
        return ErrorCopy(
            title: "Server moved",
            message: "\(server) redirects to \(location). For your security Shelfarr won't follow that. Use the new address instead.",
            retryable: false
        )
    case .protocolError:
        return ErrorCopy(title: "Unexpected response", message: "\(server) sent something Shelfarr couldn't read.")
    default:
        return ErrorCopy(title: "Something went wrong", message: "Please try again.")
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = max(Int(seconds), 0)
    let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, rest)
        : String(format: "%d:%02d", minutes, rest)
}

/// A saved place in words: a page for PDFs and comics, a percentage for other books, a
/// timestamp for audio.
func describePlace(locator: JSONValue?, seconds: Double?) -> String {
    if let type = locator?["type"]?.stringValue, type == ReaderFormat.pdfMediaType || type.hasPrefix("image/"),
       let page = locator?["locations"]?["position"]?.doubleValue {
        return "page \(Int(page))"
    }
    if let total = locator?["locations"]?["totalProgression"]?.doubleValue {
        return "\(Int((total * 100).rounded()))% through"
    }
    if let seconds { return formatDuration(seconds) }
    return "Unknown place"
}

extension ShelfarrCore.Publication {
    /// Short status, e.g. `42%` or `Track 3 · 12:20`.
    var progressLabel: String? {
        guard let saved = progress else { return nil }
        if let total = saved.totalProgression { return "\(Int((total * 100).rounded()))%" }
        guard let seconds = saved.positionSeconds else { return nil }
        let tracks = audioAssets
        if tracks.count > 1, let index = tracks.firstIndex(where: { $0.id == saved.assetId }) {
            return "Track \(index + 1) · \(formatDuration(seconds))"
        }
        return formatDuration(seconds)
    }

    /// 0–1 through the publication, when that can honestly be worked out.
    var progressFraction: Double? {
        guard let saved = progress else { return nil }
        if let total = saved.totalProgression { return total }
        let tracks = audioAssets
        if tracks.count > 1, let index = tracks.firstIndex(where: { $0.id == saved.assetId }) {
            return Double(index) / Double(tracks.count)
        }
        return nil
    }

    var primaryActionLabel: String {
        // Finished stays finished: opening it again doesn't promise a restart.
        if status == .finished { return bookType == .ebook ? "Open book" : "Play audiobook" }
        let resuming = progress?.isUsable == true
        switch bookType {
        case .ebook: return resuming ? "Continue reading" : "Start reading"
        case .audiobook: return resuming ? "Continue listening" : "Start listening"
        }
    }
}

extension ReadingStatus {
    var label: String {
        switch self {
        case .unread: return "Unread"
        case .inProgress: return "In progress"
        case .finished: return "Finished"
        }
    }
}

extension APIError {
    /// No connection at all, as opposed to an untrusted certificate. Only this may fall back to local copies.
    var isPlainOffline: Bool {
        if case let .offline(certificate) = self { return !certificate }
        return false
    }
}
