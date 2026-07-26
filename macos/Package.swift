// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Markive",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Markive",
            path: "Sources/Markive"
        )
    ]
)
