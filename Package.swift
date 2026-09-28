// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeployHero",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DeployHero", path: "Sources/DeployHero"),
    ]
)
