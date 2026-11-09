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
    /// The reader's own width class. A sheet on iPad is compact inside, so the page
    /// layout sheet is told what the reader can show rather than reading its own.
    @Environment(\.horizontalSizeClass) private var sizeClass
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
            model.layoutChanged()
            model.book?.apply($0)
            model.applyTheme($0.theme)
        }
        // The reading surface's size, as the navigator (which ignores the safe area) is
        // laid out: rotation or a resized window. On iPad, hiding the controls hides the
        // status bar and changes only the safe area; that is not a layout, and treating it
        // as one made the next page turned an anchor instead of a reading place.
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size) { _ in model.layoutChanged() }
        }.ignoresSafeArea())
        .onChange(of: scenePhase) { if $0 != .active { model.flush() } }
        .onDisappear { model.leave() }
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
                PageLayoutSheet(layout: $model.layout, theme: $settingsStore.settings.theme, format: model.format,
                                offersSpreads: sizeClass == .regular)
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
            if let readAlong = model.readAlong {
                ReadAlongTrace(controller: readAlong)
            }
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
            if let readAlong = model.readAlong {
                ReadAlongOffer(controller: readAlong, theme: theme)
            }
            if model.chromeVisible {
                VStack(spacing: 0) {
                    if let readAlong = model.readAlong {
                        ReadAlongBar(controller: readAlong, theme: theme)
                    } else if let note = model.readAlongNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .accessibilityIdentifier("read-along-note")
                    }
                    ReaderScrubber(model: model, theme: theme)
                }
                .background(theme.bar.ignoresSafeArea(edges: .bottom))
                .transition(.opacity)
            } else {
                if let readAlong = model.readAlong {
                    ReadAlongPill(controller: readAlong, theme: theme)
                }
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

// MARK: Read-along

/// The narration controls, in the reading-controls overlay: back 15 / play / forward 30
/// (Play is the only filled control), Follow the text and speed in quiet ink, then the
/// coverage line. Wraps onto two rows when the text is large or the window narrow.
private struct ReadAlongBar: View {
    @ObservedObject var controller: ReadAlongController
    let theme: ReaderTheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    transport
                    Spacer(minLength: 12)
                    follow.fixedSize()
                    speed
                }
                VStack(alignment: .leading, spacing: 10) {
                    transport
                    HStack(spacing: 16) {
                        follow
                        Spacer(minLength: 8)
                        speed
                    }
                }
            }
            if let problem = controller.problem {
                Text(problem).font(.footnote).foregroundStyle(theme.text).accessibilityIdentifier("read-along-problem")
            }
            Text(controller.note)
                .font(.footnote)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("read-along-note")
        }
        .frame(maxWidth: sizeClass == .regular ? 640 : .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { theme.hairline.frame(height: 1) }
    }

    private var transport: some View {
        HStack(spacing: 18) {
            Button { controller.skip(by: -PlaybackEngine.skipBack) } label: {
                Image(systemName: "gobackward.15").font(.title3).frame(width: 44, height: 44)
            }
            .disabled(!controller.started)
            .accessibilityLabel("Back 15 seconds")
            Button { controller.togglePlay() } label: {
                Image(systemName: controller.playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: theme == .night ? 0x2B1208 : 0xFFF9F2))
                    .frame(width: 54, height: 54)
                    .background(theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.playing ? "Pause narration" : "Play narration")
            .accessibilityIdentifier("read-along-play")
            Button { controller.skip(by: PlaybackEngine.skipForward) } label: {
                Image(systemName: "goforward.30").font(.title3).frame(width: 44, height: 44)
            }
            .disabled(!controller.started)
            .accessibilityLabel("Forward 30 seconds")
        }
        .tint(theme.text)
    }

    private var follow: some View {
        Toggle("Follow the text", isOn: Binding(get: { controller.follow }, set: { controller.setFollow($0) }))
            .toggleStyle(.switch)
            .tint(theme.accent)
            .font(.subheadline)
            .foregroundStyle(theme.text)
            .accessibilityIdentifier("read-along-follow")
    }

    private var speed: some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { value in
                Button {
                    controller.setSpeed(value)
                } label: {
                    if value == controller.speed { Label(Self.label(value), systemImage: "checkmark") } else { Text(Self.label(value)) }
                }
            }
        } label: {
            Text(Self.label(controller.speed)).font(.subheadline.weight(.medium)).frame(minWidth: 44, minHeight: 44)
        }
        .tint(theme.text)
        .accessibilityLabel("Narration speed")
        .accessibilityValue(Self.label(controller.speed))
    }

    private static func label(_ value: Float) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%g×", value)
    }
}

/// The only addition to the page itself, and only once narration has started: a small
/// Pause/Play pill, and "Back to the narration" after browsing away from it.
private struct ReadAlongPill: View {
    @ObservedObject var controller: ReadAlongController
    let theme: ReaderTheme

    var body: some View {
        if controller.started {
            HStack(spacing: 6) {
                Button { controller.togglePlay() } label: {
                    Label(controller.playing ? "Pause" : "Play", systemImage: controller.playing ? "pause.fill" : "play.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel(controller.playing ? "Pause narration" : "Play narration")
                .accessibilityIdentifier("read-along-pill")
                if controller.suspended {
                    theme.hairline.frame(width: 1, height: 22)
                    Button { controller.returnToNarration() } label: {
                        Text("Back to the narration")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("read-along-return")
                }
            }
            .tint(theme.text)
            .background(theme.bar, in: Capsule())
            .overlay(Capsule().stroke(theme.hairline, lineWidth: 1))
            .padding(.bottom, 6)
            .transition(.opacity)
        }
    }
}

/// A later place heard on the paired audiobook, offered and never applied by itself.
private struct ReadAlongOffer: View {
    @ObservedObject var controller: ReadAlongController
    let theme: ReaderTheme

    var body: some View {
        if let offer = controller.offer {
            VStack(alignment: .leading, spacing: 8) {
                Text(offer).font(.footnote).foregroundStyle(theme.text)
                HStack(spacing: 12) {
                    Button("Go to the audiobook's place") { controller.acceptOffer() }
                        .font(.footnote.weight(.semibold))
                        .tint(theme.accent)
                        .accessibilityIdentifier("read-along-offer-accept")
                    Button("Not now") { controller.dismissOffer() }
                        .font(.footnote)
                        .tint(theme.text)
                }
                .frame(minHeight: 44)
            }
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(theme.bar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.hairline, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("read-along-offer")
        }
    }
}

/// Simulator smoke only (see `RestoreTrace`): the session in fixture terms.
private struct ReadAlongTrace: View {
    @ObservedObject var controller: ReadAlongController

    var body: some View {
        if let trace = controller.trace {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("read-along-trace")
                .accessibilityLabel(trace)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
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
