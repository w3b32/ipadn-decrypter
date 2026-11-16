import Foundation
import UIKit

enum DecryptError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

struct FileFailure {
    var file: String
    var reason: String
}

struct DecryptReport {
    var output: URL
    var appName: String
    var decrypted: Int
    var alreadyPlain: Int
}

private func fpProgressTrampoline(_ line: UnsafePointer<CChar>?, _ ctx: UnsafeMutableRawPointer?) {
    guard let line, let ctx else { return }
    Unmanaged<Decryptor>.fromOpaque(ctx).takeUnretainedValue().log(String(cString: line))
}

final class Decryptor {
    private let fm = FileManager.default
    let log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    private func withProgress<T>(_ operation: () throws -> T) rethrows -> T {
        fp_set_progress(fpProgressTrampoline, Unmanaged.passUnretained(self).toOpaque())
        defer { fp_set_progress(nil, nil) }
        return try operation()
    }

    private func unpack(_ source: URL, to destination: URL) throws {
        var error = [CChar](repeating: 0, count: Int(FP_ERRMAX))
        let errorCapacity = error.count
        let rc = source.path.withCString { archive in
            destination.path.withCString { dest in
                fp_unzip(archive, dest, &error, errorCapacity)
            }
        }
        guard rc == 0 else { throw DecryptError.message("Extract: \(String(cString: error))") }
    }

    private func pack(_ source: URL, to destination: URL) throws {
        var error = [CChar](repeating: 0, count: Int(FP_ERRMAX))
        let errorCapacity = error.count
        let rc = source.path.withCString { dir in
            destination.path.withCString { archive in
                fp_zip_dir(dir, archive, &error, errorCapacity)
            }
        }
        guard rc == 0 else { throw DecryptError.message("Pack: \(String(cString: error))") }
    }

    private func app(in directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard apps.count == 1, let result = apps.first else {
            throw DecryptError.message("Expected exactly one app inside Payload/. Found \(apps.count).")
        }
        return result
    }

    private func save(_ source: URL, named name: String) throws -> URL {
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        let output = try PayloadLayout.child(name, in: documents)
        // Do not remove the previous successful result before the new copy is ready.
        let staged = documents.appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: output)
        }
        return output
    }

    func prepareHelper(ipaAt source: URL) throws -> (url: URL, appName: String) {
        try withProgress {
            guard let template = Bundle.main.url(forResource: "HelperTemplate", withExtension: "ipa") else {
                throw DecryptError.message("Missing HelperTemplate.ipa. Install the complete artifact from the Build unsigned IPA workflow.")
            }
            let work = fm.temporaryDirectory.appendingPathComponent("prepare-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let target = work.appendingPathComponent("target")
            let stage = work.appendingPathComponent("helper")
            try unpack(source, to: target)
            try unpack(template, to: stage)
            let original = try app(in: target)
            let helper = try app(in: stage)
            let manifest = try PayloadLayout.prepare(app: original, in: helper, log: log)
            let (_, decoded) = try PayloadLayout.installed(in: helper, log: log)
            guard decoded.appName == manifest.appName, decoded.binaries == manifest.binaries,
                  decoded.signingDigests == manifest.signingDigests,
                  decoded.displayName == manifest.displayName, decoded.appVersion == manifest.appVersion else {
                throw DecryptError.message("The prepared helper manifest did not survive its write/read check.")
            }
            let signature = helper.appendingPathComponent("_CodeSignature")
            if fm.fileExists(atPath: signature.path) { try fm.removeItem(at: signature) }
            let provision = helper.appendingPathComponent("embedded.mobileprovision")
            if fm.fileExists(atPath: provision.path) { try fm.removeItem(at: provision) }
            let archive = work.appendingPathComponent("helper.ipa")
            try pack(stage, to: archive)
            let result = try save(archive, named: manifest.runnerFilename)
            log("Prepared \(result.lastPathComponent). Sign and install it, then open the app's Runner.")
            log("Use the App Store account that owns the original IPA on this iPhone.")
            return (result, manifest.displayName ?? manifest.appName)
        }
    }

    func runEmbedded() throws -> DecryptReport {
        try withProgress {
            let (origin, manifest) = try PayloadLayout.installed(in: Bundle.main.bundleURL, log: log)
            log("Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
            log("Build: \(Bundle.main.object(forInfoDictionaryKey: "TetherDecryptCommit") as? String ?? "local")")
            log("Validating the installed helper…")
            try PayloadLayout.validate(manifest, at: origin, log: log)
            let work = fm.temporaryDirectory.appendingPathComponent("decrypt-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            let copy = try PayloadLayout.child("\(manifest.appName).app", in: payload)
            try copyTree(origin, to: copy)

            var decrypted = 0, plain = 0
            var failures: [FileFailure] = []
            // Use the prepared inventory, not a best-effort walk that could miss
            // unreadable or removed binaries and incorrectly report success.
            for relative in manifest.binaries.keys.sorted() {
                let file = try PayloadLayout.child(relative, in: origin)
                let destination = try PayloadLayout.child(relative, in: copy)
                var info = fp_info()
                if file.path.withCString({ fp_probe($0, &info) }) != 0 || !info.is_macho {
                    failures.append(FileFailure(file: relative, reason: "The prepared Mach-O is missing or invalid."))
                    continue
                }
                if !info.encrypted { plain += 1; continue }
                log("Decrypting \(relative) (\(info.slices) slice(s))…")
                var transcript = [CChar](repeating: 0, count: Int(FP_LOGMAX))
                var error = [CChar](repeating: 0, count: Int(FP_ERRMAX))
                let transcriptCapacity = transcript.count
                let errorCapacity = error.count
                let rc = file.path.withCString { src in
                    destination.path.withCString { dst in
                        fp_decrypt_copy(src, dst, &transcript, transcriptCapacity, &error, errorCapacity)
                    }
                }
                if rc != 0 {
                    let reason = String(cString: error)
                    log("FAILED \(relative): \(reason)")
                    failures.append(FileFailure(file: relative, reason: reason))
                } else {
                    var verified = fp_info()
                    if destination.path.withCString({ fp_probe($0, &verified) }) != 0 ||
                        !verified.is_macho || verified.encrypted {
                        failures.append(FileFailure(file: relative, reason: "Output verification found an encrypted or invalid binary."))
                    } else {
                        decrypted += 1
                        log("Verified \(relative): all slices have cryptid 0.")
                    }
                }
            }
            guard failures.isEmpty else {
                log("Failed \(failures.count) of \(manifest.binaries.count) binaries. No decrypted IPA was exported.")
                for failure in failures { log("\(failure.file): \(failure.reason)") }
                throw DecryptError.message("\(failures.count) binary/binaries failed. \(failures[0].file): \(failures[0].reason)")
            }
            // Keep no stale code-signing seals in the modified bundle. The
            // original, installed files and licenses have never been changed.
            try removeSignatures(in: copy)
            let archive = work.appendingPathComponent("result.ipa")
            try pack(work, to: archive)
            let final = try save(archive, named: manifest.decryptedFilename)
            log("Saved \(final.lastPathComponent): \(decrypted) decrypted, \(plain) already plain, 0 failures.")
            log("Re-sign the exported IPA before installing it.")
            return DecryptReport(output: final, appName: manifest.appName,
                                 decrypted: decrypted, alreadyPlain: plain)
        }
    }

    private func copyTree(_ source: URL, to destination: URL) throws {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: source,
                     includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if item.lastPathComponent == "SC_Info" || item.lastPathComponent == "_CodeSignature" ||
                item.lastPathComponent == "embedded.mobileprovision" { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let link = try fm.destinationOfSymbolicLink(atPath: item.path)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            } else if values.isDirectory == true {
                try copyTree(item, to: target)
            } else {
                // Missing resources are a hard error, never a silently incomplete IPA.
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    private func removeSignatures(in app: URL) throws {
        for item in try fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if item.lastPathComponent == "_CodeSignature" || item.lastPathComponent == "embedded.mobileprovision" {
                try fm.removeItem(at: item)
            } else {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true { try removeSignatures(in: item) }
            }
        }
    }
}
