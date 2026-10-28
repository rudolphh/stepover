// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Stepover",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "StepoverKit"),
        .executableTarget(name: "stepover", dependencies: ["StepoverKit"]),
        // "StepoverApp", not "Stepover": the file system is case-insensitive and "stepover" is taken
        .executableTarget(name: "StepoverApp", dependencies: ["StepoverKit"]),
        .testTarget(name: "StepoverKitTests", dependencies: ["StepoverKit"]),
        // builds the games list (games.json) for the Games list workflow
        .target(name: "GamesListBuilder", dependencies: ["StepoverKit"]),
        .executableTarget(name: "games-list", dependencies: ["GamesListBuilder"]),
        .testTarget(name: "GamesListBuilderTests", dependencies: ["GamesListBuilder"]),
    ]
)
