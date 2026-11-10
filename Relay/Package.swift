// swift-tools-version:5.9
// GlucOS push relay: a small always-on service that keeps the iPhone Live Activity and alerts
// going while the phone is asleep. It fetches from LibreLinkUp every minute, runs the same alert
// rules and forecast as the apps, and sends APNs pushes. See docs/iOS.md.
//
// The shared GlucOS code (models, LibreLinkUp client, engine, alert rules) is compiled straight
// into RelayKit through the symlinks in Sources/RelayKit/Core, so there's one copy of it.
import PackageDescription

let package = Package(
    name: "GlucOSRelay",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "RelayKit",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "glucos-relay",
            dependencies: ["RelayKit"]
        ),
        .testTarget(
            name: "RelayKitTests",
            dependencies: ["RelayKit"]
        ),
    ]
)
