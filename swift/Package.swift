// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileFS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FileFS",
            targets: ["FileFS"]
        ),
        .executable(
            name: "FileFsBench",
            targets: ["FileFsBench"]
        ),
    ],
    targets: [
        .target(
            name: "FileFS"
        ),
        .executableTarget(
            name: "FileFsBench",
            dependencies: ["FileFS"]
        ),
        .testTarget(
            name: "FileFSTests",
            dependencies: ["FileFS"]
        )
    ]
)
