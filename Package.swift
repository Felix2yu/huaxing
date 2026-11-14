// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HuaXingKit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "HuaXingKit", targets: ["HuaXingKit"]),
        .executable(name: "huaxingctl", targets: ["huaxingctl"])
    ],
    targets: [
        .target(
            name: "HuaXingKit",
            path: "Sources/HuaXingKit"
        ),
        .executableTarget(
            name: "huaxingctl",
            dependencies: ["HuaXingKit"],
            path: "Sources/huaxingctl"
        ),
        .testTarget(
            name: "HuaXingKitTests",
            dependencies: ["HuaXingKit"],
            path: "Tests/HuaXingKitTests"
        )
    ]
)
