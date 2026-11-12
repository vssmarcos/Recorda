// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordaKit",
    defaultLocalization: "pt-BR",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecordaKit", targets: [
            "RecordaCore", "RecordaScheduler", "RecordaTemplates", "RecordaSearch",
            "RecordaPackaging", "RecordaStats", "RecordaSync",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.6"),
    ],
    targets: [
        // Puro (só Foundation): parser de templates, cloze, type-answer.
        .target(name: "RecordaTemplates"),
        .target(name: "RecordaCore", dependencies: [
            "RecordaTemplates",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "RecordaSearch", dependencies: ["RecordaCore"]),
        .target(name: "RecordaScheduler", dependencies: ["RecordaCore", "RecordaSearch"]),
        .target(name: "RecordaPackaging", dependencies: [
            "RecordaCore", "RecordaTemplates", "RecordaSearch",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "libzstd", package: "zstd"),
        ]),
        .target(name: "RecordaStats", dependencies: ["RecordaCore", "RecordaScheduler", "RecordaSearch"]),
        .target(name: "RecordaSync", dependencies: ["RecordaCore"]),

        .testTarget(name: "RecordaCoreTests", dependencies: ["RecordaCore"]),
        .testTarget(name: "RecordaSchedulerTests", dependencies: ["RecordaScheduler"]),
        .testTarget(name: "RecordaTemplatesTests", dependencies: ["RecordaTemplates"]),
        .testTarget(name: "RecordaSearchTests", dependencies: ["RecordaSearch"]),
        .testTarget(name: "RecordaPackagingTests", dependencies: [
            "RecordaPackaging", "RecordaScheduler",
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "libzstd", package: "zstd"),
        ]),
        .testTarget(name: "RecordaStatsTests", dependencies: ["RecordaStats", "RecordaScheduler"]),
        .testTarget(name: "RecordaSyncTests", dependencies: ["RecordaSync", "RecordaScheduler"]),
    ]
)
