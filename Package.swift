// swift-tools-version: 6.0
import PackageDescription

// This machine has a CommandLineTools-only toolchain: it ships neither XCTest
// nor a SwiftPM-compatible swift-testing overlay. `SelfTest` is therefore a
// plain executable that runs the suite and exits non-zero on failure, so
// `Scripts/test.sh` works with nothing but the compiler.
let package = Package(
    name: "SFTPsurf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SFTPsurf", targets: ["SFTPsurf"]),
        .executable(name: "SelfTest", targets: ["SelfTest"]),
        .library(name: "SFTPsurfCore", targets: ["SFTPsurfCore"]),
        .library(name: "SFTPsurfUI", targets: ["SFTPsurfUI"]),
    ],
    targets: [
        .target(
            name: "SFTPsurfCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SFTPsurfUI",
            dependencies: ["SFTPsurfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SFTPsurf",
            dependencies: ["SFTPsurfUI", "SFTPsurfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["SFTPsurfUI", "SFTPsurfCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
