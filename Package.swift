// swift-tools-version:6.0
import PackageDescription
import Foundation

let virtualKeys = ProcessInfo.processInfo.environment["FIDOPASS_VIRTUAL_KEYS"] == "1"
let appSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)] + (virtualKeys ? [.define("FIDOPASS_VIRTUAL_KEYS")] : [])

let package = Package(
    name: "FidoPass",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FidoPassCore", targets: ["FidoPassCore"]),
        .executable(name: "FidoPassApp", targets: ["FidoPassApp"])
    ],
    dependencies: [
        // The in-app updater. A binary xcframework whose checksum Sparkle pins in its own
        // manifest; `Package.resolved` pins the exact release here. The release tools that
        // sign updates come from the matching tarball — see scripts/release.env.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .systemLibrary(
            name: "CLibfido2",
            pkgConfig: "libfido2",
            providers: [
                .brew(["libfido2"])
            ]
        ),
        // Argon2 reference implementation, vendored — see Sources/CArgon2/README.md.
        .target(
            name: "CArgon2",
            exclude: ["LICENSE", "README.md"],
            cSettings: [.define("ARGON2_NO_THREADS")]
        ),
        .target(
            name: "FidoPassCore",
            dependencies: ["CLibfido2", "CArgon2"],
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
            dependencies: [.byName(name: "FidoPassCore")] + (virtualKeys ? [.byName(name: "FidoPassVirtualKeys")] : []),
            exclude: virtualKeys ? [] : ["VirtualKeys"],
            swiftSettings: appSettings
        ),
        .target(
            name: "FidoPassVirtualKeys",
            dependencies: ["FidoPassCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The only module that imports Sparkle, the way only Core imports CLibfido2. The app
        // sees it through `UpdateService`; the tests never load the framework.
        .target(
            name: "FidoPassUpdater",
            dependencies: ["FidoPassAppKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The entry point and nothing else. The app icon lives here for `build_app.sh`,
        // which copies it into the bundle itself; SwiftPM must not turn it into a resource
        // bundle the app would never read.
        .executableTarget(
            name: "FidoPassApp",
            dependencies: ["FidoPassAppKit", "FidoPassUpdater"],
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["FidoPassCore", "FidoPassVirtualKeys"],
            path: "Tests/TestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FidoPassCoreTests",
            dependencies: ["FidoPassCore", "FidoPassVirtualKeys", "TestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FidoPassAppTests",
            dependencies: ["FidoPassAppKit", "FidoPassCore", "FidoPassVirtualKeys", "TestSupport"],
            swiftSettings: appSettings
        ),
        .testTarget(
            name: "FidoPassUpdaterTests",
            dependencies: ["FidoPassUpdater", "FidoPassAppKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
