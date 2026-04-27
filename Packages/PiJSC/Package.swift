// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiJSC",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "PiJSC", targets: ["PiJSC"])
    ],
    targets: [
        .target(
            name: "PiJSC",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "PiJSCTests",
            dependencies: ["PiJSC"]
        )
    ]
)
