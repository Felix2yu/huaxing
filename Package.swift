// swift-tools-version: 6.4
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
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "HuaXingKit",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")],
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
