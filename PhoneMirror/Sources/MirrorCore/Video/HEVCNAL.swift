// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// NAL-Unit-Typen nach ITU-T H.265, Tabelle 7-1 (nur die hier relevanten).
public enum HEVCNALType {
    public static let vps: UInt8 = 32
    public static let sps: UInt8 = 33
    public static let pps: UInt8 = 34
    public static let accessUnitDelimiter: UInt8 = 35
    public static let prefixSEI: UInt8 = 39

    public static func isVCL(_ type: UInt8) -> Bool { type < 32 }
    /// IRAP-Bilder (BLA, IDR, CRA) – dort kann die Dekodierung beginnen.
    public static func isIRAP(_ type: UInt8) -> Bool { (16...23).contains(type) }
    public static func isParameterSet(_ type: UInt8) -> Bool { (32...34).contains(type) }
}

/// Eine NAL Unit ohne Startcode.
public struct HEVCNALUnit: Sendable, Equatable {
    public var data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var type: UInt8 {
        guard let first = data.first else { return 0xFF }
        return (first >> 1) & 0x3F
    }

    /// `first_slice_segment_in_pic_flag`: erstes Bit nach dem 2-Byte-Header einer VCL-NAL.
    public var isFirstSliceOfPicture: Bool {
        guard HEVCNALType.isVCL(type), data.count > 2 else { return false }
        return data[data.startIndex + 2] & 0x80 != 0
    }
}

public enum AnnexB {
    public static let startCode = Data([0, 0, 0, 1])

    /// Zerlegt einen Annex-B-Bytestrom (3- oder 4-Byte-Startcodes) in NAL Units.
    public static func split(_ stream: Data) -> [HEVCNALUnit] {
        let bytes = [UInt8](stream)
        var units: [HEVCNALUnit] = []
        var payloadStart: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let start = payloadStart {
                    // Eine Null vor "00 00 01" gehört zum 4-Byte-Startcode, nicht zur vorigen NAL.
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

/// Gruppiert einen fortlaufenden NAL-Strom zu Access Units (je ein Bild).
/// Eine neue Access Unit beginnt mit AUD/VPS/SPS/PPS/Prefix-SEI oder mit dem ersten Slice
/// eines Bildes – jeweils nur, wenn die aktuelle Unit schon ein Bild enthält.
public struct HEVCAccessUnitAssembler: Sendable {
    private var current: [HEVCNALUnit] = []
    private var currentHasVCL = false

    public init() {}

    /// Liefert die abgeschlossene vorige Access Unit, sobald `unit` eine neue beginnt.
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

    /// Gibt die letzte, noch offene Access Unit zurück.
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
