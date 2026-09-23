// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ara",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Ara", targets: ["FrameStudio"]),
        .executable(name: "FrameProbe", targets: ["FrameProbe"])
    ],
    targets: [
        .target(name: "FrameCore"),
        .target(name: "FrameMedia", dependencies: ["FrameCore"]),
        .executableTarget(name: "FrameStudio", dependencies: ["FrameCore", "FrameMedia"]),
        .executableTarget(name: "FrameProbe", dependencies: ["FrameCore", "FrameMedia"]),
        .testTarget(name: "FrameCoreTests", dependencies: ["FrameCore"])
    ],
    swiftLanguageModes: [.v6]
)
