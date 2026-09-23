// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TouchBarPillPolicy",
    platforms: [.macOS(.v12)],
    products: [],
    targets: [
        .target(
            name: "TouchBarPillPolicy",
            path: "TouchBarPill",
            sources: ["ZonePolicy.swift"]
        ),
        .testTarget(
            name: "TouchBarPillPolicyTests",
            dependencies: ["TouchBarPillPolicy"],
            path: "Tests/TouchBarPillPolicyTests"
        ),
    ]
)
