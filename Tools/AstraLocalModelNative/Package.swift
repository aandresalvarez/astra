// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AstraLocalModelNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "astra-local-model-native", targets: ["AstraLocalModelNative"])
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "AstraLocalModelNative",
            dependencies: [
                .product(name: "ASTRACore", package: "ASTRA"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/AstraLocalModelNative"
        )
    ]
)
