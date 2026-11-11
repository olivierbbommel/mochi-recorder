// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mochi",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        // Shared with the iPhone app (ios/project.yml).
        .library(name: "MochiKit", targets: ["MochiKit"]),
        .library(name: "MochiTranscribe", targets: ["MochiTranscribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        // Two-track call capture: a Core Audio process tap on the call app, and the mic the call
        // app reads, opened read only. Grew out of old Mochi's tap/ package.
        .target(name: "MochiCapture", path: "Sources/MochiCapture",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Models, local storage, transcript formatting. No UI.
        .target(name: "MochiKit", path: "Sources/MochiKit"),
        // The SwiftUI app. build.sh wraps the binary into Mochi.app.
        .executableTarget(name: "Mochi", dependencies: ["MochiCapture", "MochiKit", "MochiTranscribe"], path: "Sources/Mochi",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Local speech to text: Parakeet TDT v3 via FluidAudio on the Neural Engine.
        .target(name: "MochiTranscribe",
                dependencies: ["MochiKit", .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "WhisperKit", package: "WhisperKit")],
                path: "Sources/MochiTranscribe", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "mochi-transcribe", dependencies: ["MochiTranscribe", "MochiKit", .product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Sources/mochi-transcribe", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MochiKitTests", dependencies: ["MochiKit"], path: "Tests/MochiKitTests"),
    ]
)
