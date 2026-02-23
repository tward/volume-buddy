// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VolumeBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VolumeBuddy",
            path: "Sources/VolumeBuddy",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
