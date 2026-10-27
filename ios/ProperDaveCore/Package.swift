// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProperDaveCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ProperDaveCore", targets: ["ProperDaveCore"])],
    targets: [
        .target(name: "ProperDaveCore"),
        .testTarget(name: "ProperDaveCoreTests", dependencies: ["ProperDaveCore"]),
    ]
)
