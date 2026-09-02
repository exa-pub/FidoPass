// swift-tools-version:5.9
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
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Everything the application is: stores, windows, views. A library so it can be
        // imported by tests as one module and assembled from one entry point.
        .target(
            name: "FidoPassAppKit",
            dependencies: ["FidoPassCore"]
        ),
        // The entry point and nothing else. The app icon lives here for `build_app.sh`,
        // which copies it into the bundle itself; SwiftPM must not turn it into a resource
        // bundle the app would never read.
        .executableTarget(
            name: "FidoPassApp",
            dependencies: ["FidoPassAppKit"],
            exclude: ["Resources"]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["FidoPassCore"],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "FidoPassCoreTests",
            dependencies: ["FidoPassCore", "TestSupport"]
        ),
        .testTarget(
            name: "FidoPassAppTests",
            dependencies: ["FidoPassAppKit", "FidoPassCore", "TestSupport"]
        )
    ]
)
