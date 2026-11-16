// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "HuaXingApp",
    platforms: [
        .macOS(.v27)
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
            path: "Sources/HuaXingUI",
            swiftSettings: [
                // Swift 6.2 默认 MainActor 隔离：UI 模型层与视图同在主线程，减少标注。
                .defaultIsolation(MainActor.self)
            ]
        ),
        // SwiftUI 可执行入口 —— 需要完整 Xcode
        .executableTarget(
            name: "huaxing",
            dependencies: ["HuaXingUI"],
            path: "Sources/huaxing",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        )
    ]
)
