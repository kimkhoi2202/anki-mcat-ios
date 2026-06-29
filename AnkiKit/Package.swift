// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnkiKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AnkiKit", targets: ["AnkiKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        // Anki's Rust core, packaged as a C-ABI static library xcframework.
        .binaryTarget(
            name: "AnkiCore",
            path: "../AnkiCore/AnkiCore.xcframework"
        ),
        .target(
            name: "AnkiKit",
            dependencies: [
                "AnkiCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            // System libraries/frameworks required by the linked Rust staticlib.
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("c++"),
                .linkedLibrary("resolv"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(
            name: "AnkiKitTests",
            dependencies: ["AnkiKit"]
        ),
    ]
)
