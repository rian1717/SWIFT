// swift-tools-version: 6.0
import PackageDescription

// No third-party dependencies. The Quick Share protocol — wire format, UKEY2
// handshake, secure messages, mDNS discovery and payload transfer — is
// implemented in SWIFTCore on top of Foundation, Network and CryptoKit
// alone. See docs/ARCHITECTURE.md.
let package = Package(
    name: "SWIFT",
    platforms: [.macOS("26.0")],   // real Liquid Glass (glassEffect) needs macOS 26
    products: [
        .library(name: "SWIFTCore", targets: ["SWIFTCore"]),
        .executable(name: "SWIFT", targets: ["SWIFTApp"]),
        .executable(name: "SWIFTProbe", targets: ["SWIFTProbe"]),
    ],
    targets: [
        // Our Quick Share protocol implementation.
        .target(
            name: "SWIFTCore",
            path: "Sources/SWIFTCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Our native SwiftUI app.
        .executableTarget(
            name: "SWIFTApp",
            dependencies: ["SWIFTCore"],
            path: "Sources/SWIFTApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Headless real-device interoperability harness.
        .executableTarget(
            name: "SWIFTProbe",
            dependencies: ["SWIFTCore"],
            path: "Sources/SWIFTProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SWIFTCoreTests",
            dependencies: ["SWIFTCore"],
            path: "Tests/SWIFTCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SWIFTAppTests",
            dependencies: ["SWIFTApp", "SWIFTCore"],
            path: "Tests/SWIFTAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
