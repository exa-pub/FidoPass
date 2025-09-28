// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FidoPass",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "FidoPassCore", targets: ["FidoPassCore"]),
    .executable(name: "FidoPassApp", targets: ["FidoPassApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibfido2",
            pkgConfig: "libfido2",
            providers: [
                .brew(["libfido2"])
            ]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["FidoPassCore"],
            path: "Tests/TestSupport"
        ),
        .target(
            name: "FidoPassCore",
            dependencies: ["CLibfido2"],
            swiftSettings: [.define("SWIFT_PACKAGE")],
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "FidoPassApp",
            dependencies: [
                "FidoPassCore"
            ],
            path: "Sources/FidoPassApp",
            resources: [
                // Copy the app icon (.icns); final .app bundling will happen via helper script
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "FidoPassCoreTests",
            dependencies: ["FidoPassCore", "TestSupport"],
            path: "Tests/FidoPassCoreTests"
        ),
        .testTarget(
            name: "FidoPassAppTests",
            dependencies: ["FidoPassApp", "FidoPassCore", "TestSupport"],
            path: "Tests/FidoPassAppTests"
        )
    ]
)
