// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicRateFollower", platforms: [.macOS(.v15)],
    products: [.executable(name: "MusicRateFollower", targets: ["MusicRateFollower"])],
    targets: [
        .executableTarget(name: "MusicRateFollower"),
        .testTarget(
            name: "MusicRateFollowerTests", dependencies: ["MusicRateFollower"],
            resources: [.copy("Fixtures")]),
    ], swiftLanguageModes: [.v5]
)
