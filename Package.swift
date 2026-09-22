// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalSideload",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SideloadCore", targets: ["SideloadCore"]),
        .executable(name: "LocalSideload", targets: ["LocalSideload"])
    ],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "SideloadCore", dependencies: ["CArchive"]),
        .executableTarget(name: "LocalSideload", dependencies: ["SideloadCore"]),
        .testTarget(name: "SideloadCoreTests", dependencies: ["SideloadCore"])
    ]
)
