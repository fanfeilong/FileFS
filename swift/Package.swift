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
        )
    ],
    targets: [
        .target(
            name: "FileFS"
        ),
        .testTarget(
            name: "FileFSTests",
            dependencies: ["FileFS"]
        )
    ]
)
