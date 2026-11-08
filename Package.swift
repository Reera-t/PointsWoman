// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PointsWoman",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PointsWoman", targets: ["PointsWoman"]),
        .executable(name: "pointswomanctl", targets: ["PointsWomanCLI"])
    ],
    targets: [
        .target(name: "PointsWomanCore"),
        .executableTarget(name: "PointsWoman", dependencies: ["PointsWomanCore"]),
        .executableTarget(name: "PointsWomanCLI", dependencies: ["PointsWomanCore"]),
        .executableTarget(name: "PointsWomanChecks", dependencies: ["PointsWomanCore"], path: "Tests/PointsWomanTests")
    ],
    swiftLanguageModes: [.v5]
)
