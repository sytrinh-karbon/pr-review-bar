// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRReviewBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReviewCore"),
        .target(name: "RepoSync"),
        .executableTarget(name: "PRReviewBar", dependencies: ["ReviewCore", "RepoSync"]),
        .testTarget(name: "ReviewCoreTests", dependencies: ["ReviewCore"]),
        .testTarget(name: "RepoSyncTests", dependencies: ["RepoSync"]),
    ]
)
