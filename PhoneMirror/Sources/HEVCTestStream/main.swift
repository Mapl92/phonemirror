// SPDX-License-Identifier: GPL-3.0-or-later
// Generates an HEVC test file (Annex B) for the replay transport.
// Usage: hevc-test-stream <output.h265> [seconds=4] [width=1179] [height=2556] [collapse]
// “collapse”: every other second scaled down on a gray background (resolution collapse as on iOS).
import Foundation
import MirrorCore
import MirrorTestSupport

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: hevc-test-stream <output.h265> [seconds] [width] [height]\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])
let seconds = arguments.count > 2 ? Int(arguments[2]) ?? 4 : 4
let width = arguments.count > 3 ? Int(arguments[3]) ?? DeviceScreen.iPhone15.pixelWidth : DeviceScreen.iPhone15.pixelWidth
let height = arguments.count > 4 ? Int(arguments[4]) ?? DeviceScreen.iPhone15.pixelHeight : DeviceScreen.iPhone15.pixelHeight
let fps = 60
let collapse = arguments.contains("collapse")

let data = try HEVCTestStreamEncoder.encode(
    width: width, height: height, frameCount: seconds * fps, framesPerSecond: fps,
    collapsedFrames: { collapse && ($0 / fps) % 2 == 1 }
)
try data.write(to: output)
let units = HEVCAccessUnitAssembler.accessUnits(in: data)
print("\(output.path): \(width)×\(height), \(units.count) frames, \(data.count / 1024) KiB")
