import ShelfarrCore
import SwiftUI

/// The bottom bar for pages: previous and next in the reading direction, the page number
/// (which opens Go to page) and a page slider that jumps when it is let go.
struct PageScrubber: View {
    @ObservedObject var model: ReaderModel
    let theme: ReaderTheme
    let goTo: () -> Void
    @State private var scrubbing: Double?

    private var shown: Int { scrubbing.map { Int($0.rounded()) } ?? model.page }

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    leading
                    Spacer(minLength: 8)
                    pageButton
                    Spacer(minLength: 8)
                    trailing
                }
                // Large text: the page number on its own line.
                VStack(spacing: 8) {
                    pageButton
                    HStack {
                        leading
                        Spacer()
                        trailing
                    }
                }
            }
            if model.pageCount > 1 {
                Slider(
                    value: Binding(get: { scrubbing ?? Double(model.page) }, set: { scrubbing = $0 }),
                    in: 1 ... Double(model.pageCount),
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing {
                            model.goToPage(Int(target.rounded()))
                            scrubbing = nil
                        }
                    }
                )
                .tint(theme.accent)
                // Mirrored for right-to-left books, so the slider moves the way pages do.
                .environment(\.layoutDirection, model.layout.rightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityLabel("Page")
                .accessibilityValue("Page \(shown) of \(model.pageCount)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.turnPage(forward: true)
                    case .decrement: model.turnPage(forward: false)
                    @unknown default: break
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.bar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { theme.hairline.frame(height: 1) }
    }

    /// In a right-to-left book the next page is on the left.
    @ViewBuilder private var leading: some View {
        if model.layout.rightToLeft { next } else { previous }
    }

    @ViewBuilder private var trailing: some View {
        if model.layout.rightToLeft { previous } else { next }
    }

    private var previous: some View {
        Button { model.turnPage(forward: false) } label: {
            Image(systemName: model.layout.rightToLeft ? "chevron.right" : "chevron.left")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .tint(theme.text)
        .disabled(model.page <= 1)
        .accessibilityLabel("Previous page")
    }

    private var next: some View {
        Button { model.turnPage(forward: true) } label: {
            Image(systemName: model.layout.rightToLeft ? "chevron.left" : "chevron.right")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .tint(theme.text)
        .disabled(model.page >= model.pageCount)
        .accessibilityLabel("Next page")
    }

    private var pageButton: some View {
        Button(action: goTo) {
            Text("Page \(shown) of \(model.pageCount)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .frame(minHeight: 44)
        }
        .tint(theme.text)
        .accessibilityHint("Go to a page")
        .accessibilityIdentifier("reader-page")
    }
}

/// Layout for pages: fit, reading direction, spreads and page colour. None of it is reading.
struct PageLayoutSheet: View {
    @Binding var layout: PageLayout
    @Binding var theme: ReaderTheme
    let format: ReaderFormat?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Fit", selection: $layout.fit) {
                        ForEach(PageLayout.Fit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Fit")
                } footer: {
                    Text("Pinch or double-tap to zoom. Zooming doesn't change your place.")
                }
                Section {
                    Picker("Reading direction", selection: $layout.rightToLeft) {
                        Text("Left to right").tag(false)
                        Text("Right to left").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reading-direction")
                } header: {
                    Text("Reading direction")
                } footer: {
                    Text("Right to left is for manga and other books read that way. Shelfarr remembers it for this book.")
                }
                if sizeClass == .regular {
                    Section {
                        Toggle("Two pages side by side", isOn: $layout.spreads)
                    } footer: {
                        Text("When the screen is in landscape. The first page stays on its own, like a cover.")
                    }
                }
                Section("Page colour") {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { option in
                            Button { theme = option } label: {
                                Text(option.label)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(option.text)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(option.page, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(theme == option ? Palette.accent : Palette.hairline, lineWidth: theme == option ? 2 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(option.label) background")
                            .accessibilityAddTraits(theme == option ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Page layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private extension ReaderFormat {
    var summary: String {
        switch self {
        case .epub: return "Text that reflows to your type size and page colour."
        case .pdf: return "The printed pages, exactly as laid out."
        case .cbz: return "The page images, one at a time."
        }
    }
}

private func byteCount(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// Several formats and nothing to go on: the reader chooses, and nothing is saved until
/// a page is turned.
struct FormatChoice: View {
    let options: [ReaderModel.FormatOption]
    let theme: ReaderTheme
    let pick: (ReaderFormat) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("How would you like to read it?")
                    .font(Typeface.display(24))
                    .foregroundStyle(theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("This book is on your server in more than one format. Your choice isn't saved as a place until you turn a page.")
                    .font(.subheadline)
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    Button { pick(option.format) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(option.format.label).font(.headline).foregroundStyle(theme.text)
                                if index == 0 { tag("Suggested") }
                                if option.onDevice { tag("On this device") }
                                Spacer(minLength: 0)
                            }
                            Text(option.format.summary + (option.sizeBytes > 0 ? " \(byteCount(option.sizeBytes))." : ""))
                                .font(.subheadline)
                                .foregroundStyle(theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(theme.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("format-choice-\(option.format.rawValue)")
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.accent)
    }
}

/// Offline, with the saved place in a format that isn't on this device.
struct FormatUnavailable: View {
    let saved: ReaderFormat
    let alternatives: [ReaderFormat]
    let theme: ReaderTheme
    let host: String?
    let pick: (ReaderFormat) -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your place is in the \(saved.label)")
                .font(Typeface.display(24))
                .foregroundStyle(theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("The \(saved.label) isn't on this device and \(host ?? "your server") can't be reached. You can read what's here from its beginning; your place in the \(saved.label) stays saved until you turn a page.")
                .font(.subheadline)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(alternatives, id: \.self) { format in
                Button("Read the \(format.label) on this device") { pick(format) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("format-alternative-\(format.rawValue)")
            }
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 480)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A saved place this file can't show. It stays saved; looking is not reading.
struct InvalidPlace: View {
    let format: ReaderFormat
    let pageCount: Int
    let theme: ReaderTheme
    let start: (_ atLastPage: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your saved place isn't in this file")
                .font(Typeface.display(24))
                .foregroundStyle(theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("It points to a page this \(format == .pdf ? "PDF" : "comic") doesn't have (it has \(pageCount) \(pageCount == 1 ? "page" : "pages")), perhaps because the file was replaced. It stays your saved place until you turn a page.")
                .font(.subheadline)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start at page 1") { start(false) }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("invalid-place-first")
            if pageCount > 1 {
                Button("Go to the last page") { start(true) }
                    .buttonStyle(.bordered)
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("invalid-place-last")
            }
        }
        .frame(maxWidth: 480)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
