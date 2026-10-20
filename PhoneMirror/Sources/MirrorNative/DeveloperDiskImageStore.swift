// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Where PhoneMirror finds the Developer Disk Image, and how it gets one without an installed Xcode:
/// from the user's own Xcode download (`.xip`), an `Xcode.app`, Xcode's `XcodeSystemResources.pkg`,
/// an `iOS_DDI.dmg` or an unpacked DDI folder. Apple packages are accepted only with Apple's signature;
/// the DDI itself is verified by the iPhone anyway (trust cache and personalization ticket).
public enum DeveloperDiskImageStore {
    public struct Info: Sendable, Equatable {
        public var restoreDirectory: URL
        public var build: String
    }

    /// PhoneMirror's own copy (no admin rights needed).
    public static var ownDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneMirror/DDI/iOS_DDI")
    }

    static let xcodeHostDirectory = URL(fileURLWithPath: "/Library/Developer/DeveloperDiskImages/iOS_DDI")
    static let packageMember = "/Contents/Resources/Packages/XcodeSystemResources.pkg"
    static let ddiInPackage = "Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg"
    private static let logger = Logger(subsystem: "PhoneMirror", category: "ddi")

    /// The newest usable DDI: `ddiRestorePath` default, PhoneMirror's copy, Xcode's host copy.
    public static func installed() -> Info? {
        var candidates: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: "ddiRestorePath") {
            candidates.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        candidates.append(ownDirectory.appendingPathComponent("Restore"))
        candidates.append(xcodeHostDirectory.appendingPathComponent("Restore"))
        let found = candidates.compactMap(info(restoreDirectory:))
        return found.max { $0.build.compare($1.build, options: .numeric) == .orderedAscending }
    }

    static func info(restoreDirectory: URL) -> Info? {
        let manifest = restoreDirectory.appendingPathComponent("BuildManifest.plist")
        guard let data = try? Data(contentsOf: manifest),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return Info(restoreDirectory: restoreDirectory, build: plist["ProductBuildVersion"] as? String ?? "?")
    }

    /// An installed Xcode the DDI can be taken from without asking (e.g. downloaded but never launched).
    public static func xcodeApplications() -> [URL] {
        let applications = URL(fileURLWithPath: "/Applications")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        return names.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { applications.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path + packageMember) }
    }

    /// Imports a DDI into PhoneMirror's own directory. `progress` gets short status texts.
    public static func importDDI(from source: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Info {
        try await Task.detached(priority: .userInitiated) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneMirror-DDI-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let info = try importAny(source, scratch: scratch, progress: progress)
            logger.notice("Imported Developer Disk Image \(info.build, privacy: .public)")
            return info
        }.value
    }

    /// Imports the DDI straight from Apple's Xcode download, reading only parts of the `.xip`
    /// (`cookies` from the user's Apple Developer sign-in). The device verifies the image itself
    /// (trust cache, personalization ticket); a whole package is additionally checked with pkgutil.
    public static func importFromApple(xipURL: URL, cookies: [HTTPCookie],
                                       progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (Info, RemoteXIPReport) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneMirror-DDI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (outcome, report) = try await RemoteXIPFetcher.fetch(xipURL: xipURL, cookies: cookies, into: scratch, progress: progress)
        let info = try await Task.detached {
            switch outcome {
            case .diskImage(let dmg): try importDiskImage(dmg, scratch: scratch, progress: progress)
            case .package(let package): try importPackage(package, scratch: scratch, progress: progress)
            }
        }.value
        return (info, report)
    }

    private static func importAny(_ source: URL, scratch: URL, progress: @escaping @Sendable (String) -> Void) throws -> Info {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        switch source.pathExtension.lowercased() {
        case "xip":
            progress("Checking Apple's signature…")
            try requireAppleSignature(source)
            let package = scratch.appendingPathComponent("XcodeSystemResources.pkg")
            try XIPExtractor.extract(xip: source, memberSuffix: packageMember, to: package) { fraction in
                progress("Reading the Xcode archive… \(Int(fraction * 100)) %")
            }
            return try importPackage(package, scratch: scratch, progress: progress)
        case "app":
            return try importPackage(source.appendingPathComponent(String(packageMember.dropFirst())), scratch: scratch, progress: progress)
        case "pkg":
            return try importPackage(source, scratch: scratch, progress: progress)
        case "dmg":
            return try importDiskImage(source, scratch: scratch, progress: progress)
        default:
            guard isDirectory.boolValue else { throw DeveloperDiskImageError.bundleMissing(source.path) }
            return try importFolder(source, progress: progress)
        }
    }

    private static func importPackage(_ package: URL, scratch: URL, progress: @escaping @Sendable (String) -> Void) throws -> Info {
        progress("Checking the package…")
        try requireAppleSignature(package)
        let expanded = scratch.appendingPathComponent("expanded")
        progress("Unpacking the Developer Disk Image…")
        try run("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path])
        let dmg = expanded.appendingPathComponent("Payload").appendingPathComponent(ddiInPackage)
        guard FileManager.default.fileExists(atPath: dmg.path) else { throw DeveloperDiskImageError.bundleMissing(dmg.path) }
        return try importDiskImage(dmg, scratch: scratch, progress: progress)
    }

    private static func importDiskImage(_ dmg: URL, scratch: URL, progress: @escaping @Sendable (String) -> Void) throws -> Info {
        let mountPoint = scratch.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mountPoint.path]) }
        return try importFolder(mountPoint, progress: progress)
    }

    /// Accepts an `iOS_DDI` folder (with `Restore/`) or a `Restore` folder itself.
    private static func importFolder(_ folder: URL, progress: @escaping @Sendable (String) -> Void) throws -> Info {
        let restore = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Restore/BuildManifest.plist").path)
            ? folder.appendingPathComponent("Restore") : folder
        // Must hold a complete DDI cryptex before anything is replaced.
        _ = try DeveloperDiskImageBundle(restoreDirectory: restore)
        progress("Copying…")
        let target = ownDirectory
        let staging = target.deletingLastPathComponent().appendingPathComponent("iOS_DDI.importing")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [restore.path, staging.appendingPathComponent("Restore").path])
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        guard let info = info(restoreDirectory: target.appendingPathComponent("Restore")) else {
            throw DeveloperDiskImageError.bundleMissing(target.path)
        }
        return info
    }

    /// `pkgutil --check-signature` must report Apple's own signature (also works for `.xip`).
    static func requireAppleSignature(_ file: URL) throws {
        let output = (try? run("/usr/sbin/pkgutil", ["--check-signature", file.path])) ?? ""
        guard output.contains("signed Apple Software") else {
            throw DeveloperDiskImageError.signing("\(file.lastPathComponent) is not signed by Apple")
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DeveloperDiskImageError.importFailed("\(URL(fileURLWithPath: tool).lastPathComponent): \(output.prefix(300))")
        }
        return output
    }
}
