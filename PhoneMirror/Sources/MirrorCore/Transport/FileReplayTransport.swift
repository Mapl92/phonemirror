// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Plays back an Annex B HEVC file in real time as a device stream (endless loop).
/// Input is only logged and counted as `receivedInputs`.
public struct FileReplayTransport: MirrorTransport {
    public var fileURL: URL
    public var screen: DeviceScreen
    public var framesPerSecond: Double

    public init(fileURL: URL, screen: DeviceScreen = .iPhone15, framesPerSecond: Double = 60) {
        self.fileURL = fileURL
        self.screen = screen
        self.framesPerSecond = framesPerSecond
    }

    public var displayName: String { "Replay: \(fileURL.lastPathComponent)" }

    public func connect() async throws -> any MirrorSession {
        let data = try Data(contentsOf: fileURL)
        let accessUnits = HEVCAccessUnitAssembler.accessUnits(in: data).map(AnnexB.join)
        return FileReplaySession(accessUnits: accessUnits, screen: screen, framesPerSecond: framesPerSecond)
    }
}

public final class FileReplaySession: MirrorSession {
    public let screen: DeviceScreen
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let playback: Task<Void, Never>
    private let inputLog = OSAllocatedUnfairLock(initialState: [InputEvent]())
    private static let logger = Logger(subsystem: "PhoneMirror", category: "replay")

    init(accessUnits: [Data], screen: DeviceScreen, framesPerSecond: Double) {
        self.screen = screen
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .bufferingNewest(8))
        self.events = stream
        self.continuation = continuation

        playback = Task {
            guard !accessUnits.isEmpty else {
                continuation.yield(.disconnected(reason: "File contains no HEVC frames"))
                continuation.finish()
                return
            }
            continuation.yield(.screenChanged(screen))
            let clock = ContinuousClock()
            let frameDuration = Duration.seconds(1 / framesPerSecond)
            var deadline = clock.now
            var frame = 0
            while !Task.isCancelled {
                let unit = accessUnits[frame % accessUnits.count]
                continuation.yield(.video(VideoPacket(annexB: unit, timestamp: Double(frame) / framesPerSecond)))
                frame += 1
                deadline += frameDuration
                try? await clock.sleep(until: deadline)
            }
            continuation.finish()
        }
    }

    public var receivedInputs: [InputEvent] {
        inputLog.withLock { $0 }
    }

    public func send(_ event: InputEvent) async throws {
        inputLog.withLock { $0.append(event) }
        // notice instead of debug: ends up in the persistent log and can be checked with `log show`.
        Self.logger.notice("Input: \(String(describing: event), privacy: .public)")
    }

    public func close() async {
        playback.cancel()
        continuation.finish()
    }

    deinit {
        playback.cancel()
    }
}
