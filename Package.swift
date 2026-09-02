// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FidoPass",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FidoPassCore", targets: ["FidoPassCore"]),
        .executable(name: "FidoPassApp", targets: ["FidoPassApp"])
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
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Everything the application is: stores, windows, views. A library so it can be
        // imported by tests as one module and assembled from one entry point.
        .target(
            name: "FidoPassAppKit",
            dependencies: ["FidoPassCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The entry point and nothing else. The app icon lives here for `build_app.sh`,
        // which copies it into the bundle itself; SwiftPM must not turn it into a resource
        // bundle the app would never read.
        .executableTarget(
            name: "FidoPassApp",
            dependencies: ["FidoPassAppKit"],
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["FidoPassCore"],
            path: "Tests/TestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FidoPassCoreTests",
            dependencies: ["FidoPassCore", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FidoPassAppTests",
            dependencies: ["FidoPassAppKit", "FidoPassCore", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
