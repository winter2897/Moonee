// swift-tools-version: 6.2
// Vietnamese parse eval (spec §9.2): rules vs each catalog model, on this Mac.
// The app's own parser/AI sources are symlinked into Sources/ParseEval/App, so this measures the shipped code.
//   cd tools/ParseEval && ./run.sh [models-dir]   (models are downloaded there on first run, ~28 GB; add `speed` to skip the parse eval)
import PackageDescription

let package = Package(
    name: "ParseEval",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "ParseEval",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
