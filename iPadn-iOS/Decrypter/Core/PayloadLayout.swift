import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FPCoreNative)
import FPCoreNative
#endif

enum PayloadLayoutError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

struct PayloadManifest: Codable {
    let version: Int
    let appName: String
    let directory: String
    let binaries: [String: String]
    let licenses: [String: String]
    let signingDigests: [String: String]?
    let displayName: String?
    let appVersion: String?

    init(version: Int, appName: String, directory: String, binaries: [String: String],
         licenses: [String: String], signingDigests: [String: String]? = nil,
         displayName: String? = nil, appVersion: String? = nil) {
        self.version = version
        self.appName = appName
        self.directory = directory
        self.binaries = binaries
        self.licenses = licenses
        self.signingDigests = signingDigests
        self.displayName = displayName
        self.appVersion = appVersion
    }

    var exportBaseName: String {
        let name = PayloadLayout.filenameComponent(displayName ?? appName, fallback: "App")
        guard let appVersion else { return name } // Keep legacy helpers readable.
        return name + "." + PayloadLayout.filenameComponent(appVersion, fallback: "unknown")
    }

    var runnerFilename: String { exportBaseName + ".runner.ipa" }
    var decryptedFilename: String { exportBaseName + "-decrypted.ipa" }
}

/// Preparation is separate from the UIKit app so the actual helper layout can
/// be tested on the macOS builder without a phone or an Apple account.
enum PayloadLayout {
    static let manifestName = "TetherDecryptPayload.plist"
    static let backupName = "payload-manifest.json"
    static let infoKey = "TetherDecryptPayloadData"

    static func filenameComponent(_ raw: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:<>\"|?*").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var value = ""
        for character in cleaned {
            guard value.utf8.count + String(character).utf8.count <= 96 else { break }
            value.append(character)
        }
        let stem = value.components(separatedBy: ".")[0].uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if reserved.contains(stem) { value = "_" + value }
        return value.isEmpty ? fallback : value
    }

    static func child(_ relative: String, in root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\\"), !relative.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PayloadLayoutError.invalid("Invalid relative payload path: \(relative)")
        }
        // Canonicalize the existing root BEFORE appending missing components.
        // On iOS /var aliases /private/var; resolving a nonexistent leaf may
        // otherwise leave the candidate in a different namespace from its root.
        let baseURL = root.resolvingSymlinksInPath().standardizedFileURL
        let base = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        var url = baseURL
        let fm = FileManager.default
        for part in parts {
            url.appendPathComponent(String(part))
            do {
                let attributes = try fm.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    guard fm.fileExists(atPath: resolved.path) else {
                        throw PayloadLayoutError.invalid("Broken payload symlink: \(relative)")
                    }
                    url = resolved
                }
            } catch let error as NSError {
                let missing = error.domain == NSCocoaErrorDomain &&
                    [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
                if !missing && !permissionDenied(error) { throw error }
            }
            guard url.path == baseURL.path || url.path.hasPrefix(base) else {
                throw PayloadLayoutError.invalid("Payload path escapes its bundle: \(relative)")
            }
        }
        guard url.path.hasPrefix(base) else {
            throw PayloadLayoutError.invalid("Payload path escapes its bundle: \(relative)")
        }
        return url
    }

    static func files(in root: URL, skipLicenses: Bool = false) throws -> [URL] {
        let fm = FileManager.default
        var firstError: Error?
        guard let walker = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in firstError = error; return false }) else {
            throw PayloadLayoutError.invalid("Cannot enumerate \(root.lastPathComponent).")
        }
        var result: [URL] = []
        for case let item as URL in walker {
            if skipLicenses && item.lastPathComponent == "SC_Info" {
                walker.skipDescendants()
                continue
            }
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink != true && values.isRegularFile == true { result.append(item) }
        }
        if let error = firstError { throw error }
        return result.sorted { $0.path < $1.path }
    }

    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            // Drain Foundation's temporary read buffers for large IPAs instead
            // of keeping autoreleased data alive until the entire task ends.
            let more = try readPool { () throws -> Bool in
                guard let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                return true
            }
            if !more { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readPool<T>(_ operation: () throws -> T) rethrows -> T {
#if canImport(ObjectiveC)
        return try autoreleasepool(invoking: operation)
#else
        return try operation()
#endif
    }

    /// Hash every slice byte except the code-signature blob, its location fields
    /// and __LINKEDIT size fields. Encrypted pages, cryptid, all other load
    /// commands and executable code remain covered.
    /// Returning nil means this layout cannot safely use the signing exception.
    static func signingDigest(_ file: URL) throws -> String? {
        var records = [fp_signing_slice](repeating: fp_signing_slice(), count: Int(FP_SIGNING_MAX_SLICES))
        var count: UInt32 = 0
        var error = [CChar](repeating: 0, count: Int(FP_ERRMAX))
        let errorCapacity = error.count
        let capacity = UInt32(records.count)
        let rc = records.withUnsafeMutableBufferPointer { buffer in
            file.path.withCString { path in
                fp_signing_layout(path, buffer.baseAddress, capacity, &count, &error, errorCapacity)
            }
        }
        guard rc == 0 else { return nil }
        let slices = records.prefix(Int(count))
        guard slices.contains(where: { $0.signature_size > 0 }) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        hash.update(data: Data("TetherDecrypt-signing-invariant-v1:\(count)\n".utf8))
        for record in slices {
            let length = record.signature_size > 0 ? record.signature_offset : record.slice_size
            hash.update(data: Data("\(record.cputype):\(record.cpusubtype):\(length)\n".utf8))
            var masks: [(UInt64, UInt64)] = []
            if record.signature_size > 0 {
                masks.append((record.signature_fields_offset, 8))
                if record.linkedit_word_size > 0 {
                    masks.append((record.linkedit_vmsize_offset, UInt64(record.linkedit_word_size)))
                    masks.append((record.linkedit_filesize_offset, UInt64(record.linkedit_word_size)))
                }
            }
            guard masks.allSatisfy({ $0.0 < length && $0.1 <= length - $0.0 }) else { return nil }
            try handle.seek(toOffset: record.slice_offset)
            var position: UInt64 = 0
            while position < length {
                let consumed = try readPool { () throws -> UInt64 in
                    let wanted = Int(min(UInt64(1 << 20), length - position))
                    guard var bytes = try handle.read(upToCount: wanted), !bytes.isEmpty else {
                        throw PayloadLayoutError.invalid("Truncated Mach-O while checking signing changes.")
                    }
                    let n = UInt64(bytes.count)
                    for (start, size) in masks {
                        let lower = max(start, position), upper = min(start + size, position + n)
                        if lower < upper {
                            bytes.replaceSubrange(Int(lower - position)..<Int(upper - position),
                                                  with: repeatElement(UInt8(0), count: Int(upper - lower)))
                        }
                    }
                    hash.update(data: bytes)
                    return n
                }
                position += consumed
            }
            // A signature may grow/shrink and retain zero alignment padding.
            // Non-signature data after the signature is not safe to ignore.
            if record.signature_size > 0 {
                let start = record.signature_offset + record.signature_size
                guard start <= record.slice_size else { return nil }
                try handle.seek(toOffset: record.slice_offset + start)
                var remaining = record.slice_size - start
                while remaining > 0 {
                    let consumed = try readPool { () throws -> UInt64 in
                        guard let bytes = try handle.read(upToCount: Int(min(UInt64(1 << 20), remaining))),
                              !bytes.isEmpty else {
                            throw PayloadLayoutError.invalid("Truncated signature padding.")
                        }
                        if bytes.contains(where: { $0 != 0 }) { return 0 }
                        return UInt64(bytes.count)
                    }
                    if consumed == 0 { return nil }
                    remaining -= consumed
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func replicateLicenses(in app: URL, log: (String) -> Void) throws {
        let fm = FileManager.default
        let manifest = app.appendingPathComponent("SC_Info/Manifest.plist")
        guard fm.fileExists(atPath: manifest.path) else { return }
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: manifest),
                                                               options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw PayloadLayoutError.invalid("Invalid SC_Info/Manifest.plist.")
        }
        let sources = dictionary["SinfPaths"] as? [String] ?? []
        let replicas = dictionary["SinfReplicationPaths"] as? [String] ?? []
        guard !replicas.isEmpty else { return }
        guard let source = sources.first else {
            throw PayloadLayoutError.invalid("License manifest has replicas but no source SINF.")
        }
        let sourceURL = try child(source, in: app)
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw PayloadLayoutError.invalid("The IPA is missing its license: \(source).")
        }
        var created = 0
        for path in replicas {
            let destination = try child(path, in: app)
            guard destination.pathExtension == "sinf" else {
                throw PayloadLayoutError.invalid("Unexpected license replication path: \(path)")
            }
            if fm.fileExists(atPath: destination.path) { continue }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: sourceURL, to: destination)
            created += 1
        }
        log("Prepared \(created) framework/extension license replica(s).")
    }

    static func prepare(app: URL, in helper: URL, log: (String) -> Void) throws -> PayloadManifest {
        let fm = FileManager.default
        let embedded = helper.appendingPathComponent("EmbeddedPayload", isDirectory: true)
        if fm.fileExists(atPath: embedded.path) { try fm.removeItem(at: embedded) }
        try fm.createDirectory(at: embedded, withIntermediateDirectories: true)
        // A .app suffix makes signers treat the encrypted app as nested code.
        // Store it as resources and restore its original name only in the output.
        let target = embedded.appendingPathComponent("Target", isDirectory: true)
        try fm.copyItem(at: app, to: target)
        let watch = target.appendingPathComponent("Watch")
        if fm.fileExists(atPath: watch.path) {
            try fm.removeItem(at: watch)
            log("Excluded Watch content: this helper decrypts iOS arm64 binaries only.")
        }
        try replicateLicenses(in: target, log: log)
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: target.appendingPathComponent("Info.plist")), options: [], format: nil)
        guard let dictionary = info as? [String: Any],
              let executable = dictionary["CFBundleExecutable"] as? String else {
            throw PayloadLayoutError.invalid("The target app has no CFBundleExecutable.")
        }
        let main = try child(executable, in: target)
        guard fm.fileExists(atPath: main.path) else {
            throw PayloadLayoutError.invalid("The target executable is missing: \(executable).")
        }
        var binaries: [String: String] = [:], licenses: [String: String] = [:]
        var signingDigests: [String: String] = [:]
        for file in try files(in: target) {
            let relative = String(file.path.dropFirst(target.path.count + 1))
            var probe = fp_info()
            guard file.path.withCString({ fp_probe($0, &probe) }) == 0 else {
                throw PayloadLayoutError.invalid("Malformed Mach-O: \(relative).")
            }
            if probe.is_macho {
                binaries[relative] = try digest(file)
                if let fingerprint = try signingDigest(file) { signingDigests[relative] = fingerprint }
                if probe.encrypted {
                    let license = file.deletingLastPathComponent()
                        .appendingPathComponent("SC_Info/\(file.lastPathComponent).sinf")
                    guard fm.fileExists(atPath: license.path) else {
                        throw PayloadLayoutError.invalid("Missing license for \(relative). Download the original IPA with the Apple account that owns it; a re-signed or stripped IPA is insufficient.")
                    }
                }
            }
            if file.pathComponents.contains("SC_Info") { licenses[relative] = try digest(file) }
        }
        guard binaries[executable] != nil else {
            throw PayloadLayoutError.invalid("The target executable is not a readable Mach-O.")
        }
        var mainInfo = fp_info()
        guard main.path.withCString({ fp_probe($0, &mainInfo) }) == 0, mainInfo.arm64_slices > 0 else {
            throw PayloadLayoutError.invalid("The target app has no arm64 iPhone executable.")
        }
        func metadata(_ key: String) -> String? {
            guard let text = dictionary[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let displayName = metadata("CFBundleDisplayName") ?? metadata("CFBundleName")
            ?? app.deletingPathExtension().lastPathComponent
        let appVersion = metadata("CFBundleShortVersionString") ?? metadata("CFBundleVersion") ?? "unknown"
        let result = PayloadManifest(version: 2, appName: app.deletingPathExtension().lastPathComponent,
                                     directory: "Target", binaries: binaries, licenses: licenses,
                                     signingDigests: signingDigests, displayName: displayName, appVersion: appVersion)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(result)
        let sidecar = helper.appendingPathComponent(manifestName)
        let backup = embedded.appendingPathComponent(backupName)
        try encoded.write(to: sidecar, options: .atomic)
        try JSONEncoder().encode(result).write(to: backup, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
        let helperInfoURL = helper.appendingPathComponent("Info.plist")
        guard var helperInfo = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: helperInfoURL), options: [], format: nil) as? [String: Any] else {
            throw PayloadLayoutError.invalid("The helper template has an invalid Info.plist.")
        }
        helperInfo[infoKey] = encoded
        helperInfo["TetherDecryptTemplate"] = false
        helperInfo["TetherDecryptPreparedFor"] = result.displayName ?? result.appName
        helperInfo["TetherDecryptPreparedVersion"] = result.appVersion
        helperInfo["CFBundleDisplayName"] = "\(result.displayName ?? result.appName) Runner"
        try PropertyListSerialization.data(fromPropertyList: helperInfo, format: .binary, options: 0)
            .write(to: helperInfoURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helperInfoURL.path)
        log("Recorded \(binaries.count) binary and \(licenses.count) license fingerprints in three manifest locations.")
        return result
    }

    static func installed(in helper: URL, log: (String) -> Void = { _ in }) throws -> (URL, PayloadManifest) {
        let fm = FileManager.default
        let root = helper.resolvingSymlinksInPath().standardizedFileURL
        let base = root.appendingPathComponent("EmbeddedPayload", isDirectory: true)
        var errors: [String] = []
        let infoURL = root.appendingPathComponent("Info.plist")
        let parsedInfo = (try? Data(contentsOf: infoURL)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
        }
        let info = parsedInfo ?? Bundle(url: root)?.infoDictionary
        let candidates: [(String, () throws -> PayloadManifest)] = [
            (manifestName, {
                try PropertyListDecoder().decode(PayloadManifest.self,
                    from: Data(contentsOf: root.appendingPathComponent(manifestName)))
            }),
            ("EmbeddedPayload/\(backupName)", {
                try JSONDecoder().decode(PayloadManifest.self,
                    from: Data(contentsOf: base.appendingPathComponent(backupName)))
            }),
            ("Info.plist/\(infoKey)", {
                guard let data = info?[infoKey] as? Data else {
                    throw PayloadLayoutError.invalid("No embedded manifest data in Info.plist.")
                }
                return try PropertyListDecoder().decode(PayloadManifest.self, from: data)
            })
        ]
        for (name, decode) in candidates {
            do {
                let manifest = try decode()
                guard [1, 2].contains(manifest.version), !manifest.binaries.isEmpty else {
                    throw PayloadLayoutError.invalid("Unsupported manifest version or empty binary inventory.")
                }
                // This is an output NAME, not an existing file in the helper.
                guard !manifest.appName.isEmpty, !manifest.appName.contains("/"),
                      !manifest.appName.contains("\\"), !manifest.appName.contains(":"),
                      manifest.appName != ".", manifest.appName != ".." else {
                    throw PayloadLayoutError.invalid("Invalid app name in helper manifest.")
                }
                let payload = try child(manifest.directory, in: base)
                var directory: ObjCBool = false
                guard fm.fileExists(atPath: payload.path, isDirectory: &directory), directory.boolValue,
                      fm.fileExists(atPath: payload.appendingPathComponent("Info.plist").path) else {
                    throw PayloadLayoutError.invalid("Manifest found, but its installed payload directory is missing.")
                }
                log("Loaded manifest from \(name) for \(manifest.appName).")
                return (payload, manifest)
            } catch {
                let message = "\(name): \(error.localizedDescription)"
                errors.append(message)
                log("Manifest check: \(message)")
            }
        }
        let rootFiles = (try? fm.contentsOfDirectory(atPath: root.path))?.sorted().joined(separator: ", ") ?? "unreadable"
        let embeddedFiles = (try? fm.contentsOfDirectory(atPath: base.path))?.sorted().joined(separator: ", ") ?? "missing or unreadable"
        log("Helper bundle files: \(rootFiles)")
        log("EmbeddedPayload files: \(embeddedFiles)")
        if info?["TetherDecryptTemplate"] as? Bool == true &&
            !fm.fileExists(atPath: base.appendingPathComponent("Target").path) {
            throw PayloadLayoutError.invalid("This is the empty helper template. Install the AppName.Version.runner.ipa generated by Decrypter, rather than HelperTemplate.ipa.")
        }
        if info?["TetherDecryptTemplate"] as? Bool == true {
            log("Payload exists, but Info.plist still marks this as a template; signing may have replaced its metadata.")
        }
        throw PayloadLayoutError.invalid("Could not load the prepared payload. \(errors.joined(separator: " | "))")
    }

    static func validate(_ manifest: PayloadManifest, at payload: URL, log: (String) -> Void) throws {
        for (path, expected) in manifest.binaries.sorted(by: { $0.key < $1.key }) {
            let file = try child(path, in: payload)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw PayloadLayoutError.invalid("Missing installed binary \(path). Recreate the helper and preserve EmbeddedPayload when signing it.")
            }
            if try digest(file) != expected {
                if let code = manifest.signingDigests?[path], let actual = try signingDigest(file), code == actual {
                    log("Signature-only update accepted for \(path): code, encrypted pages and non-signing load commands are unchanged.")
                } else {
                    throw PayloadLayoutError.invalid("Signing changed code or non-signing metadata in \(path). Only code-signature updates are permitted. Recreate the helper using a signer that preserves the embedded app's code.")
                }
            }
        }
        for (path, expected) in manifest.licenses.sorted(by: { $0.key < $1.key }) {
            let file = try child(path, in: payload)
            do {
                guard try digest(file) == expected else {
                    throw PayloadLayoutError.invalid("Signing changed the license \(path). Recreate and re-sign the helper while preserving SC_Info.")
                }
            } catch let error as NSError {
                if permissionDenied(error) {
                    // installd may protect SC_Info from the app while fairplayd
                    // remains allowed to read it. This is not a missing license.
                    log("Protected license: \(path) (the system will read it).")
                } else if error.domain == NSCocoaErrorDomain &&
                            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
                    throw PayloadLayoutError.invalid("Missing installed license \(path). The signer or installer stripped SC_Info. Recreate the helper and preserve its embedded resources.")
                } else {
                    throw error
                }
            }
        }
        log("Embedded binaries and accessible licenses match the prepared helper.")
    }

    private static func permissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError { return permissionDenied(cause) }
        return false
    }
}
