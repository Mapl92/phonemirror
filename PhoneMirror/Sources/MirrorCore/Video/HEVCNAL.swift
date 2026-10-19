// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// NAL unit types per ITU-T H.265, table 7-1 (only the ones relevant here).
public enum HEVCNALType {
    public static let vps: UInt8 = 32
    public static let sps: UInt8 = 33
    public static let pps: UInt8 = 34
    public static let accessUnitDelimiter: UInt8 = 35
    public static let prefixSEI: UInt8 = 39

    public static func isVCL(_ type: UInt8) -> Bool { type < 32 }
    /// IRAP pictures (BLA, IDR, CRA) – decoding can start there.
    public static func isIRAP(_ type: UInt8) -> Bool { (16...23).contains(type) }
    public static func isParameterSet(_ type: UInt8) -> Bool { (32...34).contains(type) }
}

/// A NAL unit without start code.
public struct HEVCNALUnit: Sendable, Equatable {
    public var data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var type: UInt8 {
        guard let first = data.first else { return 0xFF }
        return (first >> 1) & 0x3F
    }

    /// `first_slice_segment_in_pic_flag`: first bit after the 2-byte header of a VCL NAL.
    public var isFirstSliceOfPicture: Bool {
        guard HEVCNALType.isVCL(type), data.count > 2 else { return false }
        return data[data.startIndex + 2] & 0x80 != 0
    }
}

public enum AnnexB {
    public static let startCode = Data([0, 0, 0, 1])

    /// Splits an Annex B byte stream (3- or 4-byte start codes) into NAL units.
    public static func split(_ stream: Data) -> [HEVCNALUnit] {
        let bytes = [UInt8](stream)
        var units: [HEVCNALUnit] = []
        var payloadStart: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let start = payloadStart {
                    // A zero before "00 00 01" belongs to the 4-byte start code, not to the previous NAL.
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(HEVCNALUnit(Data(bytes[start..<end]))) }
                }
                i += 3
                payloadStart = i
            } else {
                i += 1
            }
        }
        if let start = payloadStart, start < bytes.count {
            units.append(HEVCNALUnit(Data(bytes[start...])))
        }
        return units
    }

    public static func join(_ units: [HEVCNALUnit]) -> Data {
        var data = Data()
        for unit in units {
            data.append(startCode)
            data.append(unit.data)
        }
        return data
    }
}

/// Groups a continuous NAL stream into access units (one picture each).
/// A new access unit starts with AUD/VPS/SPS/PPS/prefix SEI or with the first slice
/// of a picture – in each case only if the current unit already contains a picture.
public struct HEVCAccessUnitAssembler: Sendable {
    private var current: [HEVCNALUnit] = []
    private var currentHasVCL = false

    public init() {}

    /// Returns the completed previous access unit as soon as `unit` starts a new one.
    public mutating func push(_ unit: HEVCNALUnit) -> [HEVCNALUnit]? {
        let type = unit.type
        let startsNewUnit = currentHasVCL && (
            type == HEVCNALType.accessUnitDelimiter
                || HEVCNALType.isParameterSet(type)
                || type == HEVCNALType.prefixSEI
                || unit.isFirstSliceOfPicture
        )
        var finished: [HEVCNALUnit]?
        if startsNewUnit {
            finished = current
            current = []
            currentHasVCL = false
        }
        current.append(unit)
        if HEVCNALType.isVCL(type) { currentHasVCL = true }
        return finished
    }

    /// Returns the last access unit that is still open.
    public mutating func flush() -> [HEVCNALUnit]? {
        defer {
            current = []
            currentHasVCL = false
        }
        return currentHasVCL ? current : nil
    }

    public static func accessUnits(in stream: Data) -> [[HEVCNALUnit]] {
        var assembler = HEVCAccessUnitAssembler()
        var units: [[HEVCNALUnit]] = []
        for nal in AnnexB.split(stream) {
            if let unit = assembler.push(nal) { units.append(unit) }
        }
        if let last = assembler.flush() { units.append(last) }
        return units
    }
}
