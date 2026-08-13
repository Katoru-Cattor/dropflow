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
        // Everything with no AppKit *view* dependency lives here so it can be linked by a test
        // target. A test target cannot link an executable target's @main, which is why the app was
        // untested for its whole history.
        .target(
            name: "DropFlowCore",
            path: "Sources/DropFlowCore"
        ),
        .executableTarget(
            name: "DropFlow",
            dependencies: ["DropFlowCore"],
            path: "Sources/DropFlow"
        ),
        .testTarget(
            name: "DropFlowCoreTests",
            dependencies: ["DropFlowCore"],
            path: "Tests/DropFlowCoreTests"
        )
    ]
)
