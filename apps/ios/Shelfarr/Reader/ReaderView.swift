import ShelfarrCore
import SwiftUI
import UIKit

/// Hosts Readium's navigator as a child, so its gestures and selection menus work.
private struct NavigatorHost: UIViewControllerRepresentable {
    let navigator: UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.addChild(navigator)
        navigator.view.frame = host.view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(navigator.view)
        navigator.didMove(toParent: host)
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @ObservedObject private var settingsStore: ReaderSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ReaderSheet?
    @State private var goToPage = false
    @State private var pageEntry = ""
    private let host: String?

    init(publicationId: String, app: AppModel) {
        _model = StateObject(wrappedValue: ReaderModel(app: app, publicationId: publicationId))
        settingsStore = app.readerSettings
        host = app.session?.server.host
    }

    private var theme: ReaderTheme { settingsStore.settings.theme }

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()
            content
            if let trace = model.restoreTrace {
                // Simulator smoke only: see RestoreTrace.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("reader-restore-trace")
                    .accessibilityLabel(trace)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(isReady && !model.chromeVisible)
        .task { await model.open() }
        .onChange(of: settingsStore.settings) {
            model.book?.apply($0)
            model.applyTheme($0.theme)
        }
        .onChange(of: scenePhase) { if $0 != .active { model.flush() } }
        .onDisappear { model.flush() }
        .sheet(item: $sheet) { which in
            switch which {
            case .contents:
                ContentsSheet(entries: model.book?.contents ?? [], current: model.chapter, theme: theme) { entry in
                    sheet = nil
                    model.chromeVisible = false
                    model.book?.go(to: entry)
                }
            case .settings:
                ReaderSettingsSheet(settings: $settingsStore.settings)
                    .presentationDetents([.medium, .large])
            case .pageLayout:
                PageLayoutSheet(layout: $model.layout, theme: $settingsStore.settings.theme, format: model.format)
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Go to page", isPresented: $goToPage) {
            TextField("Page", text: $pageEntry)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("go-to-page-field")
            Button("Go") {
                if let target = Int(pageEntry.trimmingCharacters(in: .whitespaces)) { model.goToPage(min(max(target, 1), model.pageCount)) }
                pageEntry = ""
            }
            Button("Cancel", role: .cancel) { pageEntry = "" }
        } message: {
            Text("Pages 1 to \(model.pageCount)")
        }
    }

    private var isReady: Bool {
        switch model.state {
        case .ready, .pages: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case let .preparing(fraction):
            VStack(spacing: 14) {
                Text(fraction == nil ? "Opening…" : "Fetching this book")
                    .font(Typeface.display(20))
                    .foregroundStyle(theme.text)
                ProgressView(value: fraction).tint(theme.accent).frame(maxWidth: 240)
            }
            .overlay(alignment: .topLeading) { closeButton }
        case let .chooseResume(local, server):
            Color.clear.alert("Where would you like to continue?", isPresented: .constant(true)) {
                Button("Use other device") { Task { await model.chooseResume(keepLocal: false) } }
                Button("Keep this device") { Task { await model.chooseResume(keepLocal: true) } }
            } message: {
                Text(choiceMessage(local, server))
            }
        case let .failed(error):
            let copy = errorCopy(error, host: host)
            MessageState(title: copy.title, message: copy.message, action: copy.retryable ? "Try again" : nil) {
                Task { await model.open() }
            }
            .overlay(alignment: .topLeading) { closeButton }
        case let .unreadable(title, message):
            MessageState(title: title, message: message)
                .overlay(alignment: .topLeading) { closeButton }
        case let .chooseFormat(options):
            FormatChoice(options: options, theme: theme) { format in Task { await model.pick(format) } }
                .overlay(alignment: .topLeading) { closeButton }
        case let .formatUnavailable(saved, alternatives):
            FormatUnavailable(saved: saved, alternatives: alternatives, theme: theme, host: host) { format in
                Task { await model.pick(format) }
            } retry: {
                Task { await model.open() }
            }
            .overlay(alignment: .topLeading) { closeButton }
        case let .invalidPlace(format, count):
            InvalidPlace(format: format, pageCount: count, theme: theme) { last in model.startLooking(atLastPage: last) }
                .overlay(alignment: .topLeading) { closeButton }
        case let .ready(title, navigator):
            NavigatorHost(navigator: navigator).ignoresSafeArea()
            chrome(title)
            conflictAlert
        case let .pages(title, reader):
            NavigatorHost(navigator: reader)
                .id(ObjectIdentifier(reader))
                .ignoresSafeArea()
            pageChrome(title)
            conflictAlert
        }
    }

    @ViewBuilder
    private var conflictAlert: some View {
        if case let .conflict(local?, server) = model.syncStatus {
            Color.clear.alert("Where would you like to continue?", isPresented: .constant(true)) {
                Button("Use other device", action: model.useOtherPlace)
                Button("Keep this device", action: model.keepThisPlace)
            } message: {
                Text(choiceMessage(local, server))
            }
        }
    }

    /// Another format of this book, opened at its beginning. Shown only with several.
    @ViewBuilder
    private var formatMenu: some View {
        if model.formats.count > 1 {
            Menu {
                ForEach(model.formats, id: \.self) { format in
                    Button {
                        Task { await model.switchFormat(format) }
                    } label: {
                        if format == model.format {
                            Label(format.label, systemImage: "checkmark")
                        } else {
                            Text(format.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
            }
            .tint(theme.text)
            .accessibilityLabel("Format")
            .accessibilityValue(model.format?.label ?? "")
        }
    }

    /// Quiet by default: only a small folio. A tap in the middle shows the bars.
    private func pageChrome(_ title: String) -> some View {
        VStack(spacing: 0) {
            if model.chromeVisible {
                HStack(spacing: 4) {
                    closeButton
                    Text(title).font(Typeface.serifBold(15)).foregroundStyle(theme.text).lineLimit(1)
                    Spacer()
                    formatMenu
                    Button { sheet = .pageLayout } label: {
                        Image(systemName: "rectangle.split.2x1").frame(width: 44, height: 44)
                    }
                    .tint(theme.text)
                    .accessibilityLabel("Page layout")
                }
                .padding(.horizontal, 4)
                .background(theme.bar.ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { theme.hairline.frame(height: 1) }
                .transition(.opacity)
            }
            Spacer()
            if model.chromeVisible {
                PageScrubber(model: model, theme: theme) {
                    pageEntry = ""
                    goToPage = true
                }
                .transition(.opacity)
            } else {
                Text("\(model.page) / \(model.pageCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.muted)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Page \(model.page) of \(model.pageCount)")
                    .accessibilityIdentifier("reader-page")
            }
            notices
        }
        .animation(.easeOut(duration: 0.2), value: model.chromeVisible)
    }

    @ViewBuilder
    private var notices: some View {
        if model.syncStatus == .storageFailed {
            Text(storageFailedMessage)
                .font(.footnote)
                .foregroundStyle(theme.text)
                .padding(12)
                .background(theme.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .accessibilityIdentifier("progress-storage-failed")
        }
        if let notice = model.notice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(theme.text)
                .padding(12)
                .background(theme.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(16)
                .accessibilityIdentifier("reader-notice")
                .task(id: notice) {
                    try? await Task.sleep(nanoseconds: 7_000_000_000)
                    model.clearNotice()
                }
        }
    }

    private func choiceMessage(_ local: SavedPosition, _ server: ReadingProgress) -> String {
        "This device: \(describePlace(locator: local.locator, seconds: local.positionSeconds))\n"
            + "Other device: \(describePlace(locator: server.locator, seconds: server.positionSeconds))"
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 44)
        }
        .tint(theme.text)
        .accessibilityLabel("Close book")
    }

    private func chrome(_ title: String) -> some View {
        VStack(spacing: 0) {
            if model.chromeVisible {
                HStack(spacing: 4) {
                    closeButton
                    Text(title).font(Typeface.serifBold(15)).foregroundStyle(theme.text).lineLimit(1)
                    Spacer()
                    formatMenu
                    Button { sheet = .contents } label: {
                        Image(systemName: "list.bullet").frame(width: 44, height: 44)
                    }
                    .tint(theme.text)
                    .accessibilityLabel("Contents")
                    Button { sheet = .settings } label: {
                        Text("Aa").font(Typeface.serifBold(17)).frame(width: 44, height: 44)
                    }
                    .tint(theme.text)
                    .accessibilityLabel("Reading settings")
                }
                .padding(.horizontal, 4)
                .background(theme.bar.ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { theme.hairline.frame(height: 1) }
                .transition(.opacity)
            }
            Spacer()
            if model.chromeVisible {
                ReaderScrubber(model: model, theme: theme)
                    .transition(.opacity)
            } else {
                Text("\(Int((model.fraction * 100).rounded()))%")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.muted)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("reader-progress")
            }
            notices
        }
        .animation(.easeOut(duration: 0.2), value: model.chromeVisible)
    }
}

private enum ReaderSheet: String, Identifiable {
    case contents, settings, pageLayout
    var id: String { rawValue }
}

private struct ReaderScrubber: View {
    @ObservedObject var model: ReaderModel
    let theme: ReaderTheme
    @State private var scrubbing: Double?

    private var label: String {
        let percent = Int(((scrubbing ?? model.fraction) * 100).rounded())
        if let position = model.position, let count = model.book?.positionCount, count > 0 {
            return "\(position) of \(count) · \(percent)%"
        }
        return "\(percent)%"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(model.chapter ?? "").lineLimit(1)
                Spacer()
                Text(label)
            }
            .font(.footnote)
            .foregroundStyle(theme.muted)
            Slider(
                value: Binding(get: { scrubbing ?? model.fraction }, set: { scrubbing = $0 }),
                in: 0 ... 1,
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        model.book?.go(toFraction: target)
                        scrubbing = nil
                    }
                }
            )
            .tint(theme.accent)
            .accessibilityLabel("Position in book")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(theme.bar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { theme.hairline.frame(height: 1) }
    }
}

private struct ContentsSheet: View {
    let entries: [ContentsEntry]
    let current: String?
    let theme: ReaderTheme
    let select: (ContentsEntry) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    MessageState(title: "No chapters", message: "This book doesn't list any chapters.")
                } else {
                    List(entries) { entry in
                        Button { select(entry) } label: {
                            Text(entry.title)
                                .font(Typeface.serif(18))
                                .foregroundStyle(entry.title == current ? Palette.accent : Palette.ink)
                                .padding(.leading, CGFloat(entry.depth) * 16)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    ForEach(ReaderTheme.allCases) { option in
                        Button { settings.theme = option } label: {
                            Text(option.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(option.text)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(option.page, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(settings.theme == option ? Palette.accent : Palette.hairline, lineWidth: settings.theme == option ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(option.label) pages")
                        .accessibilityAddTraits(settings.theme == option ? .isSelected : [])
                    }
                }
            }
            Section {
                Stepper(value: $settings.fontSize, in: 0.75 ... 2.5, step: 0.1) {
                    Text("Text size · \(Int((settings.fontSize * 100).rounded()))%")
                }
                Picker("Typeface", selection: $settings.font) {
                    ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                }
                Picker("Line spacing", selection: $settings.lineHeight) {
                    Text("Tight").tag(1.3)
                    Text("Normal").tag(1.5)
                    Text("Loose").tag(1.8)
                }
                Picker("Margins", selection: $settings.margins) {
                    Text("Narrow").tag(0.6)
                    Text("Normal").tag(1.0)
                    Text("Wide").tag(1.6)
                }
                Toggle("Justify text", isOn: $settings.justify)
                Toggle("Scroll instead of turning pages", isOn: $settings.scroll)
            }
        }
    }
}
