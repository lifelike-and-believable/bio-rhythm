// swift-tools-version: 6.0
import PackageDescription

// Two library targets, per SPEC.md §5.2.
//
// HRDJCore is pure: standard library only, no Foundation, no I/O, no wall clock.
// SpotifyKit owns every network and platform concern and depends on HRDJCore
// solely for `Clock`/`Instant`, so that rate limiting and token expiry are
// testable against a fake clock. The dependency never points the other way.
let package = Package(
    name: "bio-rhythm",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HRDJCore", targets: ["HRDJCore"]),
        .library(name: "SpotifyKit", targets: ["SpotifyKit"]),
    ],
    targets: [
        .target(name: "HRDJCore"),
        .target(name: "SpotifyKit", dependencies: ["HRDJCore"]),
        .testTarget(
            name: "HRDJCoreTests",
            dependencies: ["HRDJCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "SpotifyKitTests",
            dependencies: ["SpotifyKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
