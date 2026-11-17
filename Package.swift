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
                "Core/AlertSnooze.swift",
                "Core/AlertBanner.swift",
                "Shared/GlucoseActivityState.swift",
                "Shared/ClockLabel.swift",
                "Shared/ChartSummary.swift",
                "Shared/ChartSpan.swift",
                "Shared/ChartScrub.swift",
                "Shared/YesterdayLine.swift",
                "Shared/MarkerPop.swift",
                "Shared/MarkerPeek.swift",
                "Shared/CardReveals.swift",
                "Shared/LoggedElsewhere.swift",
                "Shared/ForecastMorph.swift",
                "Shared/PopoverStagger.swift",
                "Shared/ContentResize.swift",
                "Shared/DependentRows.swift",
                "Shared/ReadingRoll.swift",
                "Shared/UnitSwitch.swift",
                "Shared/TypedAmountRoll.swift",
                "Shared/RangeCrossing.swift",
                "Shared/TrendTurn.swift",
                "Shared/LaunchReading.swift",
                "Shared/NewReadingRipple.swift",
                "Shared/PullRefresh.swift",
                "Shared/HeaderCollapse.swift",
                "Shared/HapticRules.swift",
                "Shared/MenuBarGlance.swift",
                "Shared/WidgetGlance.swift",
                "Shared/SpokenGlucose.swift",
                "Shared/ReadingDetails.swift",
                "Shared/UndoCountdown.swift",
                "Core/RelayProtocol.swift",
                "Core/RelayRetry.swift",
                "Core/FunctionRegion.swift",
                "App/Logbook/InsulinLibrary.swift",
                "App/Logbook/SiteRotation.swift",
                "Core/ShareProtocol.swift",
                "iOS/Sharing/FollowDetail.swift",
                "Core/Diagnostics.swift",
                "Core/LibrePatchInfo.swift",
                "Core/Libre/Libre2.swift",
                "Core/Libre/LibreCalibrationTables.swift",
                "Core/Libre/LibreReadings.swift",
                "App/Logbook/LogbookModels.swift",
                "App/Logbook/FoodModels.swift",
                "App/Logbook/LogFlow.swift",
                "App/HomeQuickActions.swift",
                "App/Logbook/LogKeyboard.swift",
                "Food/FoodDatabase.swift",
                "Food/FoodSearch.swift",
                "Food/MealDescription.swift",
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
