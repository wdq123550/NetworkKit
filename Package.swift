// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NetworkKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "NetworkKit",
            targets: ["NetworkKit"]
        ),
    ],
    dependencies: [
        // SmartCodable：基于 Codable 的强容错 JSON 解析库，用于把返回数据解析成模型
        .package(url: "https://github.com/iAmMccc/SmartCodable.git", from: "7.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NetworkKit",
            dependencies: [
                .product(name: "SmartCodable", package: "SmartCodable"),
            ]
        ),
        .testTarget(
            name: "NetworkKitTests",
            dependencies: ["NetworkKit"]
        ),
    ]
)
