// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import MirrorCore
import os

/// Spielt den Ton des iPhones ab (Int16-PCM → Float32) mit begrenzter Latenz:
/// Liegt mehr als `maxQueuedSeconds` in der Warteschlange, werden neue Pakete verworfen,
/// damit der Ton nicht hinter dem Bild herläuft.
final class AudioPlayer: @unchecked Sendable {
    var isEnabled = true {
        didSet { if !isEnabled { stop() } }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    private var format: AVAudioFormat?
    private let maxQueuedSeconds = 0.25
    private static let logger = Logger(subsystem: "PhoneMirror", category: "audio")

    init() {
        engine.attach(node)
    }

    func play(_ chunk: AudioChunk) {
        guard isEnabled, chunk.channels > 0 else { return }
        guard let format = ensureRunning(sampleRate: chunk.sampleRate, channels: chunk.channels) else { return }
        let frames = AVAudioFrameCount(chunk.pcm.count / (2 * chunk.channels))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }

        lock.lock()
        let tooMuchQueued = Double(queuedFrames) / chunk.sampleRate > maxQueuedSeconds
        if !tooMuchQueued { queuedFrames += frames }
        lock.unlock()
        guard !tooMuchQueued else { return }

        buffer.frameLength = frames
        let channels = chunk.channels
        chunk.pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for channel in 0..<channels {
                guard let out = buffer.floatChannelData?[channel] else { continue }
                for frame in 0..<Int(frames) {
                    out[frame] = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32768
                }
            }
        }
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames -= min(frames, self.queuedFrames)
            self.lock.unlock()
        }
    }

    func stop() {
        node.stop()
        engine.stop()
        lock.lock()
        queuedFrames = 0
        lock.unlock()
    }

    private func ensureRunning(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        if let format, format.sampleRate == sampleRate, Int(format.channelCount) == channels, engine.isRunning {
            if !node.isPlaying { node.play() }
            return format
        }
        guard let newFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false
        ) else { return nil }
        engine.stop()
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: newFormat)
        do {
            try engine.start()
            node.play()
            format = newFormat
            return newFormat
        } catch {
            Self.logger.error("Audio konnte nicht starten: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
