// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HuaXingApp",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        // 纯 Foundation/Combine 模型层 —— CLT 下可 typecheck
        .target(
            name: "HuaXingUI",
            dependencies: [
                .product(name: "HuaXingKit", package: "huaxing")
            ],
            path: "Sources/HuaXingUI"
        ),
        // SwiftUI 可执行入口 —— 需要完整 Xcode
        .executableTarget(
            name: "huaxing",
            dependencies: ["HuaXingUI"],
            path: "Sources/huaxing"
        )
    ]
)
