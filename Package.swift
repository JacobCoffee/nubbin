// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Nubbin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Nubbin", path: "Sources/Nubbin"),
    ]
)
