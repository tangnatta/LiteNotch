// swift-tools-version:5.10
import Foundation
import PackageDescription

// The app links the Rust core as a static library. scripts/build-app.sh sets
// LITENOTCH_RUST_LIB to the cargo output directory; without it the release
// directory is assumed, so `cargo build --release -p litenotch-app` must run
// before the `LiteNotch` product is built. The UI library, snapshots and
// tests do not need the Rust library.
let rustLib = ProcessInfo.processInfo.environment["LITENOTCH_RUST_LIB"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../target/release").standardized.path

let package = Package(
    name: "LiteNotchUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LiteNotchUI", targets: ["LiteNotchUI"]),
        .executable(name: "LiteNotch", targets: ["LiteNotch"]),
        .executable(name: "LiteNotchSnapshot", targets: ["LiteNotchSnapshot"]),
    ],
    targets: [
        .target(name: "LiteNotchUI"),
        .target(name: "CLiteNotch"),
        .executableTarget(
            name: "LiteNotch",
            dependencies: ["LiteNotchUI", "CLiteNotch"],
            linkerSettings: [
                .unsafeFlags(["-L", rustLib]),
                .linkedLibrary("litenotch_app"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "LiteNotchSnapshot",
            dependencies: ["LiteNotchUI"]
        ),
        .testTarget(
            name: "LiteNotchUITests",
            dependencies: ["LiteNotchUI"]
        ),
    ]
)
