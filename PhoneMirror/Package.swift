// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "PhoneMirror",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PhoneMirror", targets: ["PhoneMirror"]),
        .executable(name: "hevc-test-stream", targets: ["HEVCTestStream"]),
        .executable(name: "rtp-dump-to-h265", targets: ["RTPDumpToH265"]),
        .executable(name: "native-probe", targets: ["NativeProbe"]),
        .library(name: "MirrorCore", targets: ["MirrorCore"]),
    ],
    dependencies: [
        // Automatic updates for the downloaded app (MIT license).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Device-independent core: transport abstraction, HEVC processing, input mapping.
        .target(name: "MirrorCore"),
        // Native transport without Python: tunnel, RemoteXPC, CoreDevice services.
        // Recreated after pymobiledevice3 – hence GPL-3.0-or-later (see file headers).
        .target(name: "MirrorNative", dependencies: ["MirrorCore", "CZlib"]),
        // System zlib: the media offer must be compressed byte-exactly at level 9.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(name: "NativeProbe", dependencies: ["MirrorNative"]),
        // MCP server (Streamable HTTP, JSON-RPC) for control by agents.
        .target(name: "MirrorMCP"),
        // Generates synthetic HEVC streams (Annex B) for tests and the replay transport.
        .target(name: "MirrorTestSupport", dependencies: ["MirrorCore"]),
        .executableTarget(name: "HEVCTestStream", dependencies: ["MirrorCore", "MirrorTestSupport"]),
        // Converts RTP captures (pymobiledevice3 start-video-stream) into Annex B files.
        .executableTarget(name: "RTPDumpToH265", dependencies: ["MirrorCore"]),
        .executableTarget(
            name: "PhoneMirror",
            dependencies: ["MirrorCore", "MirrorNative", "MirrorMCP", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks by Scripts/bundle-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore", "MirrorTestSupport", "MirrorNative", "MirrorMCP"]),
    ]
)
