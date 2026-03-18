// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FluxBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FluxBar", targets: ["FluxBar"]),
        .executable(name: "FluxBarTUNHelper", targets: ["FluxBarTUNHelper"])
    ],
    targets: [
        .executableTarget(
            name: "FluxBar",
            path: ".",
            exclude: [
                ".build",
                ".git",
                ".DS_Store",
                "Assets.xcassets",
                "BuildArtifacts",
                "FluxBar.entitlements",
                "test",
                "Resources",
                "Scripts",
                "Helper",
                "README.md",
                "CHANGELOG.md"
            ],
            sources: [
                "FluxBarApp.swift",
                "App",
                "Core",
                "Features",
                "Models",
                "Services",
                "Support",
                "UI"
            ]
        ),
        .executableTarget(
            name: "FluxBarTUNHelper",
            path: "Helper"
        )
    ]
)
