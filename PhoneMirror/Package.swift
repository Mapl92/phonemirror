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
    targets: [
        // Gerätunabhängiger Kern: Transport-Abstraktion, HEVC-Verarbeitung, Eingabe-Mapping.
        .target(name: "MirrorCore"),
        // Nativer Transport ohne Python: Tunnel, RemoteXPC, CoreDevice-Dienste.
        // Nachgebaut nach pymobiledevice3 – daher GPL-3.0-or-later (siehe Dateiköpfe).
        .target(name: "MirrorNative", dependencies: ["MirrorCore", "CZlib"]),
        // System-zlib: Das Medienangebot muss byte-genau mit Stufe 9 komprimiert sein.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .executableTarget(name: "NativeProbe", dependencies: ["MirrorNative"]),
        // MCP-Server (Streamable HTTP, JSON-RPC) für die Steuerung durch Agents.
        .target(name: "MirrorMCP"),
        // Erzeugt synthetische HEVC-Streams (Annex B) für Tests und den Replay-Transport.
        .target(name: "MirrorTestSupport", dependencies: ["MirrorCore"]),
        .executableTarget(name: "HEVCTestStream", dependencies: ["MirrorCore", "MirrorTestSupport"]),
        // Wandelt RTP-Mitschnitte (pymobiledevice3 start-video-stream) in Annex-B-Dateien.
        .executableTarget(name: "RTPDumpToH265", dependencies: ["MirrorCore"]),
        .executableTarget(name: "PhoneMirror", dependencies: ["MirrorCore", "MirrorNative", "MirrorMCP"]),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore", "MirrorTestSupport", "MirrorNative", "MirrorMCP"]),
    ]
)
