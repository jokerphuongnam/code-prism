// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SwiftPrismCore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swift-prism-analyzer", targets: ["SwiftPrismAnalyzer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "510.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftPrismAnalyzer",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
    ]
)
