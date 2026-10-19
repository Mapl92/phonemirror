// SPDX-License-Identifier: GPL-3.0-or-later
// Converts an RTP capture from `pymobiledevice3 developer core-device display start-video-stream`
// into an Annex B HEVC stream that `PhoneMirror -replay` and ffmpeg can play.
// Usage: rtp-dump-to-h265 <capture.rtp> <output.h265>
import Foundation
import MirrorCore

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: rtp-dump-to-h265 <capture.rtp> <output.h265>\n".utf8))
    exit(64)
}

let packets = RTPDumpFile.packets(in: try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
var depacketizer = RTPHEVCDepacketizer()
var output = Data()
var frames: [VideoPacket] = []
for packet in packets {
    if let frame = depacketizer.push(packet) {
        frames.append(frame)
        output.append(frame.annexB)
    }
}
try output.write(to: URL(fileURLWithPath: arguments[2]))

let duration = frames.last?.timestamp ?? 0
let keyframes = frames.filter { AnnexB.split($0.annexB).contains { HEVCNALType.isIRAP($0.type) } }.count
let fps = duration > 0 ? Double(frames.count - 1) / duration : 0
print("""
\(packets.count) RTP packets → \(frames.count) frames (\(keyframes) keyframes, \(depacketizer.droppedFrames) dropped)
Duration \(String(format: "%.2f", duration)) s, ≈ \(String(format: "%.1f", fps)) fps, \(output.count / 1024) KiB
""")
