// SPDX-License-Identifier: GPL-3.0-or-later
// RTP reception with RTCP feedback, recreated after pymobiledevice3 (screen_stream.py, GPL-3.0-or-later).
import Darwin
import Foundation
import os

/// UDP receiver for one of the device's RTP streams. Sends an RTCP receiver report every second
/// (+ SDES) to the sender port – without it the encoder ends the session after ≈ 20–25 s.
public final class RTPReceiver: @unchecked Sendable {
    public typealias PacketHandler = @Sendable (Data) -> Void

    public let port: UInt16
    private let socketFD: Int32
    private let lock = NSLock()
    private var destination: sockaddr_in6?
    private var ourSSRC: UInt32 = 0
    private var deviceSSRC: UInt32 = 0
    private var highestSequence: UInt32 = 0
    private var packetsReceived: UInt64 = 0
    private var lastPacketTime = Date.distantPast
    private var running = true
    private var receiveThread: Thread?
    private var reportTimer: DispatchSourceTimer?
    private static let logger = Logger(subsystem: "PhoneMirror", category: "rtp")

    /// Binds an IPv6 UDP socket on a free port.
    public init() throws {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        address.sin6_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        socketFD = fd
        port = UInt16(bigEndian: address.sin6_port)
        // Large buffer: survives app hangs without kernel losses.
        for size in [8 * 1024 * 1024, 4 * 1024 * 1024, 1024 * 1024] {
            var value = Int32(size)
            if setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        stop()
    }

    /// Start receiving. `deviceAddress`/`sourcePort`/SSRCs come from the `mediastreamstart` response.
    public func start(deviceAddress: String, answer: DisplayService.StreamAnswer, handler: @escaping PacketHandler) {
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = answer.sourcePort.bigEndian
        inet_pton(AF_INET6, deviceAddress, &destination.sin6_addr)
        lock.lock()
        self.destination = answer.sourcePort != 0 ? destination : nil
        ourSSRC = answer.ourSSRC
        deviceSSRC = answer.deviceSSRC
        lock.unlock()

        let fd = socketFD
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while let self, self.isRunning {
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { continue }
                let packet = Data(buffer[0..<count])
                guard packet.count >= 12, !(200...204).contains(packet[1]) else { continue } // skip RTCP
                self.track(sequence: UInt16(packet[2]) << 8 | UInt16(packet[3]))
                handler(packet)
            }
        }
        thread.name = "PhoneMirror.rtp"
        thread.qualityOfService = .userInteractive
        receiveThread = thread
        thread.start()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendReceiverReport() }
        timer.resume()
        reportTimer = timer
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        reportTimer?.cancel()
        reportTimer = nil
        // The receive thread ends at the latest after the receive timeout (250 ms).
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [fd = socketFD] in Darwin.close(fd) }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Time since the last RTP packet.
    public var secondsSinceLastPacket: Double {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastPacketTime)
    }

    public var hasReceivedPackets: Bool {
        lock.lock(); defer { lock.unlock() }
        return packetsReceived > 0
    }

    /// RTCP Picture Loss Indication: the device should send a keyframe immediately.
    public func sendPictureLossIndication() {
        lock.lock()
        let ssrcs = (ourSSRC, deviceSSRC)
        lock.unlock()
        var packet = Data([0x81, 0xCE, 0x00, 0x02])
        packet.append(bigEndian: ssrcs.0)
        packet.append(bigEndian: ssrcs.1)
        send(packet)
    }

    private func track(sequence: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        packetsReceived += 1
        lastPacketTime = Date()
        // Extended highest sequence number (cycles in the upper half-word).
        var cycles = highestSequence >> 16
        let last = UInt16(truncatingIfNeeded: highestSequence)
        if sequence < last, last - sequence > 0x8000 { cycles &+= 1 }
        let extended = cycles << 16 | UInt32(sequence)
        if highestSequence == 0 || extended &- highestSequence < 0x8000_0000 { highestSequence = extended }
    }

    /// RR with one report block + SDES with an empty CNAME – byte-identical to Xcode's mirror.
    private func sendReceiverReport() {
        lock.lock()
        let (ours, device, highest, received) = (ourSSRC, deviceSSRC, highestSequence, packetsReceived)
        lock.unlock()
        guard received > 0, ours != 0, device != 0 else { return }
        var packet = Data([0x81, 0xC9, 0x00, 0x07])
        packet.append(bigEndian: ours)
        packet.append(bigEndian: device)
        packet.append(contentsOf: [0, 0, 0, 0]) // fraction lost + cumulative losses
        packet.append(bigEndian: highest)
        packet.append(Data(count: 12)) // Jitter, LSR, DLSR
        packet.append(contentsOf: [0x81, 0xCA, 0x00, 0x02])
        packet.append(bigEndian: ours)
        packet.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        send(packet)
    }

    private func send(_ packet: Data) {
        lock.lock()
        guard var destination else { lock.unlock(); return }
        lock.unlock()
        packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(socketFD, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
