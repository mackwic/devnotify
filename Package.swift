// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "devnotify",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "devnotify",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        ),
    ]
)
