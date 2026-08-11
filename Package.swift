// swift-tools-version: 6.0
import PackageDescription

let whisperBuild = "Vendor/whisper.cpp/build-macos"

let package = Package(
    name: "WhisperTranscriber",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WhisperTranscriber", targets: ["WhisperTranscriber"])
    ],
    targets: [
        .target(
            name: "WhisperBridge",
            path: "Sources/WhisperBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/whisper.cpp/include"),
                .headerSearchPath("../../Vendor/whisper.cpp/ggml/include")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(whisperBuild)/src",
                    "-L\(whisperBuild)/ggml/src",
                    "-L\(whisperBuild)/ggml/src/ggml-metal",
                    "-L\(whisperBuild)/ggml/src/ggml-blas",
                    "-lwhisper",
                    "-lparakeet",
                    "-lggml",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                    "-lggml-base"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal")
            ]
        ),
        .executableTarget(
            name: "WhisperTranscriber",
            dependencies: ["WhisperBridge"],
            path: "Sources/WhisperTranscriber",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "WhisperTranscriberTests",
            dependencies: ["WhisperTranscriber"],
            path: "Tests/WhisperTranscriberTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
