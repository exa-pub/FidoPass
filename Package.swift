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
            name: "FidoPassCore",
            dependencies: ["CLibfido2"],
            swiftSettings: [.define("SWIFT_PACKAGE")]
        ),
        .executableTarget(
            name: "FidoPassApp",
            dependencies: [
                "FidoPassCore"
            ],
            path: "Sources/FidoPassApp",
            exclude: [
                "Resources/Info.plist",
                "Resources/placeholder.txt"
            ],
            resources: [
                // Copy the app icon (.icns); final .app bundling will happen via helper script
                .copy("Resources/AppIcon.icns")
            ]
        )
    ]
)
