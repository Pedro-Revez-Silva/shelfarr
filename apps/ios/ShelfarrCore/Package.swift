// swift-tools-version:5.10
import PackageDescription

// Everything here is plain Foundation, so it builds and tests on Linux as well as
// on Apple platforms. UI, Keychain, Readium and AVFoundation stay in the app target.
let package = Package(
    name: "ShelfarrCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ShelfarrCore", targets: ["ShelfarrCore"])],
    targets: [
        .target(name: "ShelfarrCore"),
        .testTarget(name: "ShelfarrCoreTests", dependencies: ["ShelfarrCore"]),
    ]
)
