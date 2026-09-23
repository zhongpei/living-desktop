// swift-tools-version:5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let needleLibraryDirectory = packageRoot.appendingPathComponent("Sources/CNeedle").path

let package = Package(
    name: "LivingDesktop",
    platforms: [
        // macOS 14：mlx-swift-lm（本地大脑运行时）的下限要求（brain-local.md §5.1）
        .macOS(.v14)
    ],
    products: [
        .library(name: "MyPetCore", targets: ["MyPetCore"]),
        .library(name: "MyPet2D", targets: ["MyPet2D"]),
        .library(name: "MyPetCombat", targets: ["MyPetCombat"]),
        .library(name: "MyPetCombatCPU", targets: ["MyPetCombatCPU"]),
        .library(name: "MyPetEngine", targets: ["MyPetEngine"]),
        .library(name: "MyPetSimulation", targets: ["MyPetSimulation"]),
        .library(name: "MyPetAI", targets: ["MyPetAI"]),
        .library(name: "MyPetPlatform", targets: ["MyPetPlatform"]),
        .library(name: "MyPetContent", targets: ["MyPetContent"]),
        .library(name: "MyPetRender", targets: ["MyPetRender"]),
        .library(name: "CNeedle", targets: ["CNeedle"]),
        .executable(name: "LivingDesktop", targets: ["MyPet"]),
    ],
    dependencies: [
        // 本地 Student Brain（brain-local.md）。Swift 6.4 可构建 mlx-swift 0.31.6；
        // 固定 revision，确保 MLXGuidedGeneration/XGrammar API 可复现。
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "c6446cf7bfb7cea76408013b614d4b2c530eaa03"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "MyPetCore",
            path: "Sources/MyPetCore"
        ),
        .target(
            name: "MyPet2D",
            dependencies: ["MyPetCore"],
            path: "Sources/MyPet2D"
        ),
        .target(
            name: "MyPetCombat",
            dependencies: ["MyPetCore", "MyPet2D"],
            path: "Sources/MyPetCombat"
        ),
        .target(
            name: "MyPetCombatCPU",
            dependencies: ["MyPetCore", "MyPet2D", "MyPetCombat"],
            path: "Sources/MyPetCombatCPU"
        ),
        .target(
            name: "MyPetEngine",
            dependencies: ["MyPetCore", "MyPet2D", "MyPetCombat", "MyPetCombatCPU"],
            path: "Sources/MyPetEngine"
        ),
        .target(
            name: "MyPetSimulation",
            dependencies: ["MyPetCore", "MyPet2D", "MyPetCombat", "MyPetEngine"],
            path: "Sources/MyPetSimulation"
        ),
        // Needle 3 C 接口：needle.h + shim（空实现，只为生成 C 模块），
        // 静态库 libneedle.a 由 MyPet 目标的 linkerSettings 链接。
        .target(
            name: "CNeedle",
            path: "Sources/CNeedle",
            exclude: ["libneedle.a"]
        ),
        .target(
            name: "MyPetAI",
            dependencies: [
                "CNeedle",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MyPetAI",
            linkerSettings: [
                .linkedLibrary("needle"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-L", needleLibraryDirectory]),
            ]
        ),
        .target(
            name: "MyPetPlatform",
            path: "Sources/MyPetPlatform"
        ),
        .target(
            name: "MyPetContent",
            dependencies: ["MyPetCore", "MyPetCombat", "ZIPFoundation"],
            path: "Sources/MyPetContent"
        ),
        .target(
            name: "MyPetRender",
            dependencies: ["MyPetContent", "MyPetCore", "MyPetEngine"],
            path: "Sources/MyPetRender"
        ),
        .target(
            name: "MyPetApp",
            dependencies: [
                "MyPetCore",
                "MyPet2D",
                "MyPetCombat",
                "MyPetEngine",
                "MyPetAI",
                "MyPetPlatform",
                "MyPetContent",
                "MyPetRender",
            ],
            path: "Sources/MyPet"
        ),
        .executableTarget(
            name: "MyPet",
            dependencies: ["MyPetApp"],
            path: "Sources/MyPetEntry"
        ),
        .testTarget(
            name: "MyPet2DTests",
            dependencies: ["MyPet2D", "MyPetCore"],
            path: "Tests/MyPet2DTests"
        ),
        .testTarget(
            name: "MyPetCombatTests",
            dependencies: ["MyPetCombat", "MyPetCore", "MyPet2D"],
            path: "Tests/MyPetCombatTests"
        ),
        .testTarget(
            name: "MyPetCombatCPUTests",
            dependencies: ["MyPetCombatCPU", "MyPetCombat", "MyPet2D", "MyPetCore"],
            path: "Tests/MyPetCombatCPUTests"
        ),
        .testTarget(
            name: "MyPetTests",
            dependencies: ["MyPetApp", "MyPetCore", "MyPet2D", "MyPetCombat", "MyPetEngine", "MyPetSimulation", "MyPetPlatform", "MyPetContent", "MyPetRender"],
            path: "Tests/MyPetTests"
        ),
        .testTarget(
            name: "MyPetCoreTests",
            dependencies: ["MyPetCore", "MyPet2D", "MyPetCombat", "MyPetEngine", "MyPetSimulation", "MyPetContent"],
            path: "Tests/MyPetCoreTests"
        ),
        .testTarget(
            name: "MyPetAITests",
            dependencies: ["MyPetAI"],
            path: "Tests/MyPetAITests"
        ),
        .testTarget(
            name: "MyPetPlatformTests",
            dependencies: ["MyPetPlatform"],
            path: "Tests/MyPetPlatformTests"
        ),
        .testTarget(
            name: "MyPetRenderTests",
            dependencies: ["MyPetRender", "MyPetContent", "MyPetCore", "MyPetEngine"],
            path: "Tests/MyPetRenderTests"
        ),
        .testTarget(
            name: "MyPetContentTests",
            dependencies: ["MyPetContent", "MyPetCore", "MyPetCombat", "MyPetEngine", "ZIPFoundation"],
            path: "Tests/MyPetContentTests"
        )
    ]
)
