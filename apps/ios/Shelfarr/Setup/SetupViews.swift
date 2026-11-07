import ShelfarrCore
import SwiftUI
import UIKit

struct SetupFlow: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        SetupContent(app: app)
    }
}

private struct SetupContent: View {
    @StateObject private var model: SetupModel
    @Environment(\.openURL) private var openURL

    init(app: AppModel) {
        _model = StateObject(wrappedValue: SetupModel(app: app))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch model.phase {
                case .enterServer, .connecting: ServerForm(model: model)
                case let .authorizing(pending): AuthorizeView(model: model, pending: pending)
                case let .ended(server, denied): EndedView(model: model, server: server, denied: denied)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.background.ignoresSafeArea())
        .onChange(of: model.browserRequest) { url in
            guard let url else { return }
            openURL(url)
            model.browserRequest = nil
        }
    }
}

private struct ServerForm: View {
    @ObservedObject var model: SetupModel

    private var connecting: Bool { model.phase == .connecting }

    var body: some View {
        Spacer(minLength: 72)
        Text("Shelfarr")
            .font(Typeface.display(44, relativeTo: .largeTitle))
            .foregroundStyle(Palette.accent)
            .accessibilityAddTraits(.isHeader)
        Text(greeting)
            .font(Typeface.serif(18))
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 12)

        Text("Server address")
            .font(.footnote)
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 48)
        TextField("books.example.org", text: $model.address)
            .textContentType(.URL)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.go)
            .onSubmit { model.connect() }
            .disabled(connecting)
            .padding(14)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline))
            .padding(.top, 6)
        Text(model.errorMessage ?? "The address you use to open Shelfarr in a browser.")
            .font(.footnote)
            .foregroundStyle(model.errorMessage == nil ? Palette.inkMuted : Palette.danger)
            .padding(.top, 8)

        if model.canUseLocalHTTP {
            Toggle(isOn: $model.allowLocalHTTP) {
                VStack(alignment: .leading) {
                    Text("Allow local HTTP").font(.subheadline)
                    Text("Development builds only. Unencrypted, for hosts on your own network.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .padding(.top, 16)
        }

        Button(connecting ? "Connecting…" : "Continue", action: model.connect)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(connecting)
            .padding(.top, 24)
    }

    private var greeting: String {
        if let name = model.expiredFor {
            return "Your sign-in has ended, \(name). Connect again to carry on where you left off."
        }
        return "Your library, to read and to listen to."
    }
}

private struct AuthorizeView: View {
    @ObservedObject var model: SetupModel
    let pending: PendingAuthorization
    @Environment(\.openURL) private var openURL

    var body: some View {
        Spacer(minLength: 56)
        Text("Approve this device")
            .font(Typeface.display(32, relativeTo: .largeTitle))
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
        Text("Sign in to \(pending.server.host) in your browser and confirm the code below.")
            .font(Typeface.serif(18))
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 12)

        HStack {
            Text(pending.grant.userCode)
                .font(.system(size: 26, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Palette.ink)
                .accessibilityLabel("Confirmation code \(pending.grant.userCode.map(String.init).joined(separator: " "))")
            Spacer()
            Button {
                UIPasteboard.general.string = pending.grant.userCode
            } label: {
                Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Copy code")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 36)

        Button {
            if let url = model.browserURL(pending) { openURL(url) }
        } label: {
            Label("Open browser", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.top, 20)

        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Waiting for approval · code expires in \(formatDuration(Double(model.secondsLeft)))")
                .font(.footnote)
                .foregroundStyle(Palette.inkMuted)
        }
        .padding(.top, 20)
        Text("On another device? Go to \(model.verificationAddress(pending))")
            .font(.footnote)
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 8)

        Button("Cancel", action: model.cancel)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.top, 16)
    }
}

private struct EndedView: View {
    @ObservedObject var model: SetupModel
    let server: ServerAddress
    let denied: Bool

    var body: some View {
        Spacer(minLength: 72)
        Text(denied ? "Approval was declined" : "That code expired")
            .font(Typeface.display(32, relativeTo: .largeTitle))
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
        Text(denied
            ? "\(server.host) didn't approve this device. Nothing was connected."
            : "Codes last a few minutes. Get a new one to try again.")
            .font(Typeface.serif(18))
            .foregroundStyle(Palette.inkMuted)
            .padding(.top, 12)
        Button("Get a new code", action: model.connect)
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 32)
        Button("Use a different server", action: model.cancel)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.top, 8)
    }
}
