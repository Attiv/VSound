// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VSound",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MusicCore", targets: ["MusicCore"]),
        .executable(name: "VSound", targets: ["VSound"])
    ],
    targets: [
        .target(name: "MusicCore"),
        .executableTarget(name: "VSound", dependencies: ["MusicCore"]),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"])
    ],
    swiftLanguageModes: [.v5]
)
