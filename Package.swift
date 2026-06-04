// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Snapture",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Snapture",
            path: "Sources/Snapture"
        )
    ]
)
