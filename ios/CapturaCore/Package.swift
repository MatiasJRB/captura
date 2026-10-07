// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral capture logic: naming, checksums, sync policy, Drive protocol,
// upload queue and OAuth helpers. Builds and tests on macOS (`swift test`) and iOS.
let package = Package(
    name: "CapturaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "CapturaCore", targets: ["CapturaCore"])],
    targets: [
        .target(name: "CapturaCore"),
        .testTarget(name: "CapturaCoreTests", dependencies: ["CapturaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
