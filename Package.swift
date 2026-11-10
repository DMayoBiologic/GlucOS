// swift-tools-version:5.9
// Unit tests for the prediction engine. The app itself is built from project.yml with XcodeGen;
// this package only compiles the engine and the plain-Foundation model files it uses, so the
// models can be tested with `swift test` without building the app.
import PackageDescription

let package = Package(
    name: "GlucOSEngine",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "GlucOSEngine",
            path: "Sources",
            sources: [
                "Engine",
                "Shared/GlucoseModels.swift",
                "Shared/OutlookSnapshot.swift",
                "App/Logbook/LogbookModels.swift",
            ]
        ),
        .testTarget(
            name: "GlucOSEngineTests",
            dependencies: ["GlucOSEngine"],
            path: "Tests/EngineTests"
        ),
    ]
)
