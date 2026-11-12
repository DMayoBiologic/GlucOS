// swift-tools-version:5.9
// The app itself is built from project.yml with XcodeGen. This package compiles the plain-Foundation
// core that every part of GlucOS shares (models, LibreLinkUp client, prediction engine, alert rules,
// Live Activity state) so it can be unit-tested with `swift test`. The push relay is a TypeScript
// port on Supabase (supabase/functions/relay); RelayParityTests keeps the two in step.
import PackageDescription

let package = Package(
    name: "GlucOSEngine",
    platforms: [.macOS(.v14), .iOS("17.2")],
    products: [
        .library(name: "GlucOSEngine", targets: ["GlucOSEngine"]),
    ],
    dependencies: [
        // SHA-256 for LibreLinkUp's Account-Id header where CryptoKit isn't available (Linux).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "GlucOSEngine",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            path: "Sources",
            sources: [
                "Engine",
                "Shared/GlucoseModels.swift",
                "Shared/OutlookSnapshot.swift",
                "Core/AlertPlanner.swift",
                "Shared/GlucoseActivityState.swift",
                "Shared/ClockLabel.swift",
                "Core/RelayProtocol.swift",
                "App/Logbook/InsulinLibrary.swift",
                "App/Logbook/SiteRotation.swift",
                "Core/ShareProtocol.swift",
                "Core/Diagnostics.swift",
                "Core/LibrePatchInfo.swift",
                "Core/Libre/Libre2.swift",
                "Core/Libre/LibreCalibrationTables.swift",
                "Core/Libre/LibreReadings.swift",
                "App/Logbook/LogbookModels.swift",
                "App/Logbook/FoodModels.swift",
                "Food/FoodDatabase.swift",
                "App/Logbook/LogbookSync.swift",
                "App/Logbook/LogbookSyncClient.swift",
                "App/LibreLinkUpClient.swift",
            ]
        ),
        .testTarget(
            name: "GlucOSEngineTests",
            dependencies: ["GlucOSEngine"],
            path: "Tests/EngineTests"
        ),
    ]
)
