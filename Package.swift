// swift-tools-version:5.9
// This package only exists so the engine can be built and tested without Xcode (swift run EngineSim).
import PackageDescription

let package = Package(
    name: "AbyssalEngine",
    targets: [
        .target(name: "ArcadeEngine", path: "Shared/Engine"),
        .executableTarget(name: "EngineSim", dependencies: ["ArcadeEngine"], path: "Tools/EngineSim"),
    ]
)
