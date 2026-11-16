// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HuaXingKit",
    platforms: [
        .macOS(.v27)
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
            path: "Sources/HuaXingKit",
            swiftSettings: [
                // Swift 6.2 的诊断组控制：升级到 6.4 后把警告当错误，避免新诊断被忽略。
                .treatAllWarnings(as: .error)
            ]
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
