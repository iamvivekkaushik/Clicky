// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clicky",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clicky",
            path: "Sources/Clicky"
        ),
    ]
)
