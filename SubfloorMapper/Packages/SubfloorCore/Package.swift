// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SubfloorCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SubfloorCore", targets: ["SubfloorCore"]),
    ],
    targets: [
        .target(name: "SubfloorCore"),
        .testTarget(name: "SubfloorCoreTests", dependencies: ["SubfloorCore"]),
    ]
)
