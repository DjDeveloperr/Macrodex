// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacrodexAgent",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "MacrodexAgent", targets: ["MacrodexAgent"])
    ],
    targets: [
        .target(
            name: "MacrodexAgent",
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "MacrodexAgentTests",
            dependencies: ["MacrodexAgent"]
        )
    ]
)
