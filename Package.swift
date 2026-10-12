// swift-tools-version: 6.2
import PackageDescription

// The Mac app (AppKit + SwiftUI + Sparkle) has no Linux build; the Linux desktop app (GTK 4) has no Mac build.
// Everything below them — the engine, llama.cpp and the CLI — is shared.
#if os(macOS)
let appProducts: [Product] = [.executable(name: "DigUpApp", targets: ["DigUpApp"])]
let appDependencies: [Package.Dependency] = [
    // In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
]
let appTargets: [Target] = [
    // The menubar + hotkey app. build.sh wraps it into build.noindex/DigUp.app. (The product can't be called
    // "DigUp": on a case-insensitive disk it would collide with the `digup` CLI binary.)
    .executableTarget(
        name: "DigUpApp",
        dependencies: ["DigUpKit", .product(name: "Sparkle", package: "Sparkle")],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
]
let kitDependencies: [Target.Dependency] = []
let kitTargets: [Target] = []
let llamaModule = "Sources/CLlama"
#else
let appProducts: [Product] = []
let appDependencies: [Package.Dependency] = []
let appTargets: [Target] = []
// Linux has no SQLite3 module in its SDK: the system libsqlite3 comes in through Sources/CSQLite.
let kitDependencies: [Target.Dependency] = ["CSQLite"]
let kitTargets: [Target] = [.systemLibrary(name: "CSQLite", path: "Sources/CSQLite")]
let llamaModule = "Sources/CLlamaLinux"
#endif

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "digup", targets: ["digup"]),
        .library(name: "DigUpKit", targets: ["DigUpKit"]),
    ] + appProducts,
    dependencies: appDependencies,
    targets: [
        // The engine: crawler, extractors, index store, the embedder interface and worker client, search. No UI.
        .target(name: "DigUpKit", dependencies: kitDependencies),
        // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama) and EmbeddingGemma 2 on it.
        .systemLibrary(name: "CLlama", path: llamaModule),
        .target(
            name: "LlamaRuntime",
            dependencies: ["CLlama", "DigUpKit"],
            linkerSettings: [.unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"])]
        ),
        // Developer CLI: estimate / index / search / status / eval. Doubles as the eval harness, and the app runs it as
        // its indexing helper and its query encoder.
        .executableTarget(name: "digup", dependencies: ["DigUpKit", "LlamaRuntime"]),
        .testTarget(name: "DigUpKitTests", dependencies: ["DigUpKit"]),
        .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
    ] + kitTargets + appTargets
)
