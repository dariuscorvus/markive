// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Markive",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CMarkiveFFI",
            path: "Sources/CMarkiveFFI"
        ),
        .executableTarget(
            name: "Markive",
            dependencies: ["CMarkiveFFI"],
            path: "Sources/Markive",
            linkerSettings: [
                // libmarkive_ffi.a lands in .libs via scripts/build-ffi.sh.
                .unsafeFlags(["-L.libs"]),
                .linkedLibrary("markive_ffi"),
            ]
        ),
        .testTarget(
            name: "MarkiveTests",
            dependencies: ["Markive"],
            path: "Tests/MarkiveTests"
        ),
    ]
)
