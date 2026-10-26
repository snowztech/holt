// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Holt",
    platforms: [.macOS(.v14)],
    targets: [
        // Built from core/ by `make core`.
        .binaryTarget(name: "HoltCoreFFI", path: "HoltCoreFFI.xcframework"),
        .target(name: "HoltCore", dependencies: ["HoltCoreFFI"]),
        .executableTarget(
            name: "Holt",
            dependencies: ["HoltCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                // Used by iroh inside the Rust core.
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
