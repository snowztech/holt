// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Holt",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Built from core/ by `make core`.
        .binaryTarget(name: "HoltCoreFFI", path: "HoltCoreFFI.xcframework"),
        .target(name: "HoltCore", dependencies: ["HoltCoreFFI"]),
        // Skip, his face and the colors, shared with the iPhone app.
        .target(name: "HoltBrand"),
        .executableTarget(
            name: "Holt",
            dependencies: [
                "HoltCore",
                "HoltBrand",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
