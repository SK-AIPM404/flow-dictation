// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FlowDictation",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FlowDictation", targets: ["FlowDictation"])
    ],
    targets: [
        .executableTarget(name: "FlowDictation")
    ]
)
