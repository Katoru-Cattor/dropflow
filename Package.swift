// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DropFlow",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DropFlow", targets: ["DropFlow"])
    ],
    targets: [
        .executableTarget(
            name: "DropFlow",
            path: "Sources/DropFlow"
        )
    ]
)
