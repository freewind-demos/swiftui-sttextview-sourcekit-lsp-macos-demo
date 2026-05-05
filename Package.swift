// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swiftui-sttextview-sourcekit-lsp-macos-demo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.3.10"),
    ],
    targets: [
        .executableTarget(
            name: "swiftui-sttextview-sourcekit-lsp-macos-demo",
            dependencies: [
                .product(name: "STTextView", package: "STTextView"),
            ]
        ),
    ]
)
