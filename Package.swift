// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscriptPipeline",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TranscriptPipelineApp", targets: ["TranscriptPipelineApp"])
    ],
    targets: [
        .executableTarget(
            name: "TranscriptPipelineApp",
            path: "Sources/TranscriptPipelineApp"
        ),
        .testTarget(
            name: "TranscriptPipelineAppTests",
            dependencies: ["TranscriptPipelineApp"],
            path: "Tests/TranscriptPipelineAppTests"
        )
    ]
)
