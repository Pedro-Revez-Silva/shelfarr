# Installing and distributing the iPhone/iPad app

There are two signing paths. Simulator builds do not require an Apple Developer
membership and cannot be installed on a physical iPad. Personal testing through
Xcode can use a free Apple Account; TestFlight and distribution signing require
Apple Developer Program membership.

## Personal iPad testing without membership

Use a Mac with Xcode and XcodeGen. The existing app targets iOS/iPadOS 16 or
later; the Mac's Xcode must also support the connected iPad's OS version.

1. In `apps/ios`, run `xcodegen generate` and open `Shelfarr.xcodeproj` in Xcode.
2. Add your Apple Account in Xcode's account settings. In the Shelfarr target's
   **Signing & Capabilities**, select your **Personal Team** and automatic signing.
3. Connect the iPad by USB, accept its trust prompt and enable Developer Mode
   if requested. Select that iPad as the run destination and run Shelfarr.
4. Connect the app to your Shelfarr HTTPS address and approve the sign-in in
   the browser, just as on Android.
5. Free signing expires after seven days. Run it from Xcode again to refresh
   the installation. Keep the same team and bundle identifier, and do not
   uninstall the app as a renewal step. Confirm data preservation on the device.

If the default bundle identifier is unavailable to your team, use an identifier
you control for that personal test build. A different bundle identifier is a
different application; do not expect it to share another installation's files.
The checked-in project and release identifier need not be changed for a local
test. Xcode project generation replaces local project-setting edits.

Apple Account sign-in and trust prompts stay in Apple's UI. Never put an Apple
password or verification code in the repository, a support message or a CI secret.

See [Apple's account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
and [running an app on a device](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html).

## Signed distribution workflow

`.github/workflows/ios-distribution.yml` adds a current-SDK compatibility lane
on pull requests and a manual signed-publication job. It does not replace the
existing Xcode 16.4 simulator coverage. The distribution lane uses Xcode 26.6
on a macOS 26 runner: Apple has required iOS/iPadOS SDK 26 or later for App
Store Connect uploads since April 28, 2026. Building against a newer SDK does
not change the app's minimum OS version.

The compatibility job builds and runs the iPhone and iPad simulator tests and
compiles an unsigned Release archive. That archive is evidence of compilation,
not an installable iPad package. No signing environment is exposed to PR jobs.

Create a GitHub environment named `ios-distribution` when a membership and
signing assets are available. Restrict its trusted branches and add reviewers
as appropriate. The signed job is manual only, and App Store Connect uploads
are additionally restricted to the repository's default branch.

| Kind | Name | Required value |
| --- | --- | --- |
| Variable | `IOS_TEAM_ID` | Ten-character Apple team identifier |
| Secret | `IOS_CERTIFICATE_P12_BASE64` | One-line base64 of an exported Apple Distribution certificate and private key |
| Secret | `IOS_CERTIFICATE_PASSWORD` | The certificate's nonempty PKCS12 password |
| Secret | `IOS_PROVISION_PROFILE_BASE64` | One-line base64 of an explicit distribution profile for `org.shelfarr.app` |
| Variable | `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key identifier; required only for upload |
| Variable | `APP_STORE_CONNECT_ISSUER_ID` | The API key issuer UUID; required only for upload |
| Secret | `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | One-line base64 of the API key's `.p8` file; required only for upload |

Store these through GitHub's secret UI or stdin-based CLI commands, never
literal values in a shell command. Back up the signing assets in the owner's
secret manager. CI cannot manufacture an Apple membership, accept agreements,
register an app or register an iPad on behalf of an unconfigured account.

Run **iOS distribution** with a three-part calendar version such as
`2026.11.9`, a new increasing build number such as `5`, and one of:

- `app-store-connect`: an App Store Connect distribution profile. With upload
  disabled, this exports the signed IPA for inspection. With upload enabled,
  the verified IPA is sent to App Store Connect for TestFlight processing.
- `release-testing`: a distribution profile containing the registered devices.
  Only those devices can install the exported IPA; it cannot be uploaded as a
  TestFlight build. The intended iPad must already be in that profile.

The workflow must first be available on the default branch before GitHub offers
its initial manual dispatch. Merely adding it to a feature branch does not
configure or exercise publication.

After an upload, finish processing/export-compliance and tester access in App
Store Connect. Internal testers need the appropriate team role. External
TestFlight testing has Apple's review requirements. An upload succeeding does
not mean a tester can install the build yet.

References: [Apple upload requirements](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/),
[TestFlight](https://developer.apple.com/testflight/),
[SDK requirements](https://developer.apple.com/news/upcoming-requirements/?id=04282026a),
and [GitHub's signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Artifacts and credential isolation

`apps/scripts/ios-distribute.py` validates the version and signing inputs before
building. It rejects an expired profile, another team/app, a development or
enterprise profile, a mismatched certificate and a registered-device profile
used for TestFlight. It checks the signed archive and exported IPA again,
including the bundle identity, version, device families, entitlements and
embedded profile.

Signing material lives in a private temporary directory and temporary keychain.
Only this run's keychain and newly installed profile are removed, including on
failure; concurrent changes by another signing process are preserved. An existing
conflicting profile is never replaced. Xcode and SwiftPM receive an environment containing paths and
locale settings only, so their diagnostic output cannot dump signing or GitHub
secret environment variables. Signing/import/upload command output is not saved.

The `ios-distribution` artifact contains the verified IPA, available symbols,
build logs and `distribution.json` with source commit, version, checksum and
upload result. A failed upload leaves the verified IPA and its manifest for
inspection. A new output directory is required on a retry so an earlier build
is not silently replaced. Provisioning profiles are embedded in signed IPAs;
registered-device profiles therefore include their device identifiers.

## Verification gates

Portable tests cover version/profile rejection, environment isolation, signed
app metadata and cleanup paths using synthetic signing material and tool
stand-ins. macOS CI is the first actual Xcode 26 archive/runtime check. A signed
export and upload require real signing assets; a physical iPad install, account
restore, offline book and background-audio pass remain separate acceptance gates.
