// SPDX-License-Identifier: GPL-3.0-or-later
// Installs the Developer Disk Image as a Cryptex1 via cryptexd – without devicectl. Recreated after
// pymobiledevice3 (services/cryptexd.py, restore/tss.py; GPL-3.0-or-later).
import Foundation
import os

public enum DeveloperDiskImageError: LocalizedError {
    case bundleMissing(String)
    case unsupportedOS(String)
    case locked
    case signing(String)
    case cryptexd(String)

    public var errorDescription: String? {
        switch self {
        case .bundleMissing(let path):
            "No Developer Disk Image found at \(path). It is installed with Xcode (it stays after Xcode is deleted)."
        case .unsupportedOS(let version):
            "iOS \(version) installs the Developer Disk Image differently; iOS 26.4 or later is required."
        case .locked:
            "Please unlock the iPhone so the Developer Disk Image can be mounted."
        case .signing(let message):
            "Apple's signing server refused the Developer Disk Image: \(message)"
        case .cryptexd(let message):
            "Mounting the Developer Disk Image failed: \(message)"
        }
    }
}

/// The DDI cryptex from an unpacked `Restore` directory (as Xcode installs it).
public struct DeveloperDiskImageBundle: @unchecked Sendable {
    public static let defaultRestoreDirectory = URL(fileURLWithPath: "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore")

    /// The `ddiRestorePath` default overrides the location (e.g. a DDI copied from another Mac's Xcode).
    public static var restoreDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: "ddiRestorePath") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return defaultRestoreDirectory
    }

    static let variantSuffix = "Developer Disk Image Cryptex"

    public let buildVersion: String
    let identity: [String: Any]
    let image: Data
    let trustCache: Data
    let info: Data
    let volumeHash: Data

    public init(restoreDirectory: URL = Self.restoreDirectory) throws {
        let manifestURL = restoreDirectory.appendingPathComponent("BuildManifest.plist")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any],
              let identities = manifest["BuildIdentities"] as? [[String: Any]]
        else { throw DeveloperDiskImageError.bundleMissing(restoreDirectory.path) }
        guard let identity = identities.first(where: {
            (($0["Info"] as? [String: Any])?["Variant"] as? String)?.hasSuffix(Self.variantSuffix) == true
        }), let components = identity["Manifest"] as? [String: Any]
        else { throw DeveloperDiskImageError.bundleMissing(manifestURL.path) }

        func payload(_ key: String) throws -> Data {
            guard let relative = ((components[key] as? [String: Any])?["Info"] as? [String: Any])?["Path"] as? String else {
                throw DeveloperDiskImageError.bundleMissing("\(manifestURL.path) (\(key))")
            }
            // The manifest names the files; never follow it out of the bundle.
            let url = restoreDirectory.appendingPathComponent(relative).standardizedFileURL
            guard url.path.hasPrefix(restoreDirectory.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: url) else {
                throw DeveloperDiskImageError.bundleMissing(url.path)
            }
            return data
        }
        buildVersion = manifest["ProductBuildVersion"] as? String ?? "?"
        self.identity = identity
        image = try payload("Cryptex1,GenericDmg")
        trustCache = try payload("Cryptex1,GenericTrustCache")
        info = try payload("Cryptex1,CryptexInfoPlist")
        volumeHash = try payload("Cryptex1,GenericVolume")
    }

    /// `Cryptex1,NonceDomain` is a nonce-domain *handle* (not an index).
    var nonceDomainHandle: UInt64 { UInt64(Self.integer(identity["Cryptex1,NonceDomain"])) }

    /// The `Cryptex1,*` parameters exactly as Xcode sends them (integers as uint64).
    var cryptex1Properties: XPCValue {
        [
            "Cryptex1,UseProductClass": .bool(identity["Cryptex1,UseProductClass"] as? Bool ?? true),
            "MountedCryptex": false,
            "Cryptex1,SubType": .uint64(UInt64(Self.integer(identity["Cryptex1,SubType"]))),
            "Cryptex1,NonceDomain": .uint64(nonceDomainHandle),
            "Cryptex1,Version": .string(identity["Cryptex1,Version"] as? String ?? ""),
            "Cryptex1,PreauthVersion": .string(identity["Cryptex1,PreauthorizationVersion"] as? String ?? ""),
        ]
    }

    /// Manifest numbers come as integers or hex strings ("0xFF10").
    static func integer(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String:
            if text.lowercased().hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) ?? 0 }
            return Int(text) ?? 0
        default: return 0
        }
    }

    /// TSS request for a Cryptex1 ticket bound to this device and its current cryptex nonce.
    func tssRequest(chip: ChipInstance, nonce: Data) -> [String: Any] {
        var request: [String: Any] = [
            "@HostPlatformInfo": "mac",
            "@VersionInfo": "libauthinstall-1104.0.9",
            "@UUID": UUID().uuidString,
            "@Cryptex1,Ticket": true,
            "Cryptex1,ChipID": Self.integer(identity["Cryptex1,ChipID"]),
            "Cryptex1,Type": Self.integer(identity["Cryptex1,Type"]),
            "Cryptex1,SubType": Self.integer(identity["Cryptex1,SubType"]),
            "Cryptex1,ProductClass": Self.integer(identity["Cryptex1,ProductClass"]),
            "Cryptex1,UseProductClass": identity["Cryptex1,UseProductClass"] as? Bool ?? true,
            "Cryptex1,NonceDomain": Self.integer(identity["Cryptex1,NonceDomain"]),
            "Cryptex1,Version": identity["Cryptex1,Version"] as? String ?? "",
            "Cryptex1,PreauthorizationVersion": identity["Cryptex1,PreauthorizationVersion"] as? String ?? "",
            "Cryptex1,Nonce": nonce,
            "Cryptex1,ProductionMode": chip.productionMode,
            "Cryptex1,UDID": chip.cryptexUDID,
            "Cryptex1,UniqueTagList": Data(),
        ]
        // Personalized components contribute only their digest; the generic DMG is not personalized.
        for case let (key, entry as [String: Any]) in (identity["Manifest"] as? [String: Any] ?? [:]) where key.hasPrefix("Cryptex1,") {
            guard (entry["Info"] as? [String: Any])?["Personalize"] as? Bool == true, let digest = entry["Digest"] else { continue }
            request[key] = ["Digest": digest]
        }
        return request
    }
}

/// The device's AppleImage4 chip instance (`read-personalization-id`).
struct ChipInstance: Equatable {
    var chipID: UInt64
    var ecid: UInt64
    var productionMode: Bool

    init(chipID: UInt64, ecid: UInt64, productionMode: Bool) {
        self.chipID = chipID
        self.ecid = ecid
        self.productionMode = productionMode
    }

    init?(_ value: XPCValue) {
        func number(_ key: String) -> UInt64? {
            switch value[key] {
            case .uint64(let n)?: n
            case .int64(let n)?: UInt64(bitPattern: n)
            case .bool(let flag)?: flag ? 1 : 0
            default: nil
            }
        }
        guard let chip = number("img4_chip_chip"), let ecid = number("img4_chip_ecid") else { return nil }
        self.init(chipID: chip, ecid: ecid, productionMode: (number("img4_chip_cpro") ?? 1) != 0)
    }

    /// `Cryptex1,UDID`: chip ID and ECID, each 8 bytes big-endian.
    var cryptexUDID: Data {
        withUnsafeBytes(of: chipID.bigEndian) { Data($0) } + withUnsafeBytes(of: ecid.bigEndian) { Data($0) }
    }
}

/// Apple's signing server (TSS).
enum TSSClient {
    static let url = URL(string: "https://gs.apple.com/TSS/controller?action=2")!

    static func ticket(for request: [String: Any]) async throws -> Data {
        var http = URLRequest(url: url, timeoutInterval: 30)
        http.httpMethod = "POST"
        http.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        http.setValue("InetURL/1.0", forHTTPHeaderField: "User-Agent")
        http.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        http.httpBody = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        let (body, _) = try await URLSession.shared.data(for: http)
        return try parse(body)
    }

    /// Response: `STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=<plist>`.
    static func parse(_ body: Data) throws -> Data {
        let text = String(decoding: body, as: UTF8.self)
        let message = text.components(separatedBy: "MESSAGE=").dropFirst().first?.components(separatedBy: "&").first ?? text
        guard message == "SUCCESS", let range = text.range(of: "REQUEST_STRING=") else {
            throw DeveloperDiskImageError.signing(message)
        }
        let plist = Data(text[range.upperBound...].utf8)
        guard let response = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let ticket = (response["Cryptex1,Ticket"] ?? response["ApImg4Ticket"]) as? Data
        else { throw DeveloperDiskImageError.signing("response without ticket") }
        return ticket
    }
}

/// `cryptexd` over RemoteXPC: `{"routine": …, "argv": {…}}`, one connection per call.
struct CryptexdService {
    static let name = "com.apple.security.cryptexd.remote"
    static let ddiIdentifier = "com.apple.MobileAsset.DDI"
    let rsd: RemoteServiceDiscovery

    func invoke(_ routine: String, _ argv: XPCValue = [:]) async throws -> XPCValue {
        let connection = try await rsd.connect(service: Self.name)
        defer { connection.close() }
        let response = try await withTimeout(seconds: 20, "cryptexd \(routine)") {
            try await connection.sendReceive(["routine": .string(routine), "argv": argv])
        }
        return try Self.unwrap(routine, response)
    }

    static func unwrap(_ routine: String, _ response: XPCValue) throws -> XPCValue {
        if let error = response["cferr"] {
            let description = error["cferr_userinfo"]?["NSLocalizedDescription"]?.stringValue ?? "\(error)"
            let code = error["cferr_code"]?.intValue.map(String.init) ?? "?"
            throw DeveloperDiskImageError.cryptexd("\(routine): \(description) (\(error["cferr_domain"]?.stringValue ?? "?") \(code))")
        }
        if let code = response["error"]?.intValue, code != 0 {
            throw DeveloperDiskImageError.cryptexd("\(routine): \(String(cString: strerror(Int32(code)))) (errno \(code))")
        }
        return response["argv"] ?? .null
    }

    func isDDIInstalled() async throws -> Bool {
        let installed = try await invoke("copy-installed")["remote-cryptex-array"]?.arrayValue ?? []
        return installed.contains { $0["remote-cryptex-identifier"]?.stringValue == Self.ddiIdentifier }
    }

    func chipInstance() async throws -> ChipInstance {
        let value = try await invoke("read-personalization-id")
        guard let chip = ChipInstance(value) else { throw DeveloperDiskImageError.cryptexd("unexpected personalization identifiers") }
        return chip
    }

    /// The nonce TSS signs against: cryptexd wraps it (2-byte lead, nonce, uint32 LE length).
    func nonce(handle: UInt64) async throws -> Data {
        guard let blob = try await invoke("get-nonce", ["nonce-domain-handle": .uint64(handle)])["nonce"]?.dataValue,
              blob.count >= 6
        else { throw DeveloperDiskImageError.cryptexd("get-nonce without nonce") }
        return Self.unwrapNonce(blob)
    }

    static func unwrapNonce(_ blob: Data) -> Data {
        let bytes = [UInt8](blob)
        let length = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        return Data(bytes[2..<min(2 + length, bytes.count - 4)])
    }

    /// Installs the cryptex; the five payloads follow the request as file transfers.
    func install(_ bundle: DeveloperDiskImageBundle, ticket: Data) async throws {
        let payloads: [(String, Data)] = [
            ("image", bundle.image), ("trustcache", bundle.trustCache), ("im4m", ticket),
            ("info", bundle.info), ("volumehash", bundle.volumeHash),
        ]
        var argv: [XPCEntry] = [
            XPCEntry("auth", .uint64(0)),
            XPCEntry("client-version", .uint64(3)),
            XPCEntry("cryptex1-properties", bundle.cryptex1Properties),
            XPCEntry("image-type-index", .int64(10)), // Cryptex1,GenericDmg
            XPCEntry("nonce-persistence", .uint64(1)),
            XPCEntry("persistence", .uint64(2)), // survives reboots until the next iOS update
        ]
        for (index, (key, data)) in payloads.enumerated() {
            argv.append(XPCEntry(key, .fileTransfer(id: UInt64(index + 1), size: UInt64(data.count))))
        }
        let connection = try await rsd.connect(service: Self.name)
        defer { connection.close() }
        try await connection.sendRequest(["routine": "install", "argv": .dictionary(argv)], wantingReply: true)
        for (index, (_, data)) in payloads.enumerated() {
            try await connection.sendFileTransfer(id: UInt64(index + 1), data: data)
        }
        let response = try await withTimeout(seconds: 120, "cryptexd install") { try await connection.receiveResponse() }
        _ = try Self.unwrap("install", response)
    }
}

/// Mounts the DDI natively: personalization identifiers and nonce from cryptexd, ticket from Apple's
/// TSS server, install via cryptexd. Needs the DDI files Xcode installs, but no Xcode process.
public enum DeveloperDiskImageMounter {
    private static let logger = Logger(subsystem: "PhoneMirror", category: "ddi")

    public static func isMounted(rsd: RemoteServiceDiscovery) async throws -> Bool {
        try await CryptexdService(rsd: rsd).isDDIInstalled()
    }

    /// Removes the DDI cryptex (for tests; Xcode and PhoneMirror mount it again on demand).
    public static func unmount(rsd: RemoteServiceDiscovery) async throws {
        _ = try await CryptexdService(rsd: rsd).invoke("uninstall", ["remote-cryptex-identifier": .string(CryptexdService.ddiIdentifier)])
    }

    /// iOS version from the RSD properties.
    static func osVersion(_ rsd: RemoteServiceDiscovery) -> String {
        rsd.properties["OSVersion"]?.stringValue ?? rsd.properties["ProductVersion"]?.stringValue ?? "0"
    }

    /// Returns `false` if the DDI was already installed.
    @discardableResult
    public static func mountIfNeeded(rsd: RemoteServiceDiscovery) async throws -> Bool {
        let version = osVersion(rsd)
        guard version.compare("26.4", options: .numeric) != .orderedAscending else {
            throw DeveloperDiskImageError.unsupportedOS(version)
        }
        let cryptexd = CryptexdService(rsd: rsd)
        if try await cryptexd.isDDIInstalled() { return false }

        let bundle = try DeveloperDiskImageBundle()
        logger.notice("Mounting Developer Disk Image \(bundle.buildVersion, privacy: .public)")
        let chip = try await cryptexd.chipInstance()
        let nonce = try await cryptexd.nonce(handle: bundle.nonceDomainHandle)
        let ticket = try await TSSClient.ticket(for: bundle.tssRequest(chip: chip, nonce: nonce))
        do {
            try await cryptexd.install(bundle, ticket: ticket)
        } catch DeveloperDiskImageError.cryptexd(let message) where message.localizedCaseInsensitiveContains("lock") {
            throw DeveloperDiskImageError.locked
        }
        logger.notice("Developer Disk Image mounted")
        return true
    }
}
