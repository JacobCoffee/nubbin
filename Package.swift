// swift-tools-version: 6.0
import PackageDescription

// Embed Info.plist in the binary so a bare `swift run` still has Nubbin's bundle ID and version:
// same defaults domain, same single-instance check, real version in Settings.
let infoPlist = Context.packageDirectory + "/Resources/Info.plist"

let package = Package(
    name: "Nubbin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nubbin",
            path: "Sources/Nubbin",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", infoPlist]),
            ]
        ),
    ]
)
