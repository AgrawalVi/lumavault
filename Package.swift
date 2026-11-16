// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumaVaultSDK",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "LumaVaultSDK",
            targets: ["LumaVaultSDK"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/connectrpc/connect-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "LumaVaultSDK",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Connect", package: "connect-swift"),
            ],
            path: "sdk/swift/Sources/LumaVaultSDK",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "LumaVaultSDKTests",
            dependencies: ["LumaVaultSDK"],
            path: "sdk/swift/Tests/LumaVaultSDKTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
