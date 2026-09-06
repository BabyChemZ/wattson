// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wattson",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "wattson",
            path: "Sources/wattson"
        )
    ]
)
