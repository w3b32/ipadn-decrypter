import Foundation
#if canImport(FPCoreNative)
import FPCoreNative
#endif

@main
struct PayloadLayoutTests {
    static func store(_ value: UInt64, at offset: Int, bytes: Int, in data: inout Data) {
        for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    static func signedMachO() -> Data {
        var data = Data(repeating: 0, count: 0x8040)
        let words: [UInt32] = [0xFEEDFACF, 0x0100000C, 0, 6, 3, 112, 0, 0,
                               0x2C, 24, 0x4000, 0x4000, 1, 0]
        for (index, value) in words.enumerated() { store(UInt64(value), at: index * 4, bytes: 4, in: &data) }
        store(0x19, at: 56, bytes: 4, in: &data)
        store(72, at: 60, bytes: 4, in: &data)
        data.replaceSubrange(64..<74, with: Data("__LINKEDIT".utf8))
        store(0x100008000, at: 80, bytes: 8, in: &data)
        store(0x4000, at: 88, bytes: 8, in: &data)
        store(0x8000, at: 96, bytes: 8, in: &data)
        store(64, at: 104, bytes: 8, in: &data)
        store(1, at: 112, bytes: 4, in: &data)
        store(1, at: 116, bytes: 4, in: &data)
        store(0x1D, at: 128, bytes: 4, in: &data)
        store(16, at: 132, bytes: 4, in: &data)
        store(0x8000, at: 136, bytes: 4, in: &data)
        store(64, at: 140, bytes: 4, in: &data)
        data.replaceSubrange(0x4000..<0x8000, with: repeatElement(UInt8(0xA5), count: 0x4000))
        data.replaceSubrange(0x8000..<0x8040, with: repeatElement(UInt8(0x5A), count: 64))
        return data
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw PayloadLayoutError.invalid("TEST FAILED: \(message)") }
    }

    static func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { print("PASS: \(message)"); return }
        throw PayloadLayoutError.invalid("TEST FAILED: \(message)")
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("layout-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let imports = root.appendingPathComponent("imports")
        let external = root.appendingPathComponent("Selected.IPA")
        let archiveBytes = Data([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4])
        try archiveBytes.write(to: external)
        let owned = try IPAImport.stage(external, in: imports)
        try require(try Data(contentsOf: owned) == archiveBytes, "import preserves selected bytes")
        try require(fm.fileExists(atPath: external.path), "import never deletes the original")
        try fm.removeItem(at: external)
        try require(try Data(contentsOf: owned) == archiveBytes, "import survives provider URL disappearing")
        let another = try IPAImport.stage(owned, in: imports)
        try require(another != owned, "same-named imports use independent owned directories")
        let renamedHTML = root.appendingPathComponent("NotAnArchive.ipa")
        try Data("<html>Download failed</html>".utf8).write(to: renamedHTML)
        try expectFailure("renamed HTML is rejected during import") {
            _ = try IPAImport.stage(renamedHTML, in: imports)
        }
        try require(try fm.contentsOfDirectory(atPath: imports.path).count == 2,
                    "failed imports remove their staging directory")
        try expectFailure("non-IPA selections are rejected") {
            _ = try IPAImport.stage(root.appendingPathComponent("wrong.zip"), in: imports)
        }
        IPAImport.removeOwned(renamedHTML, in: imports)
        try require(fm.fileExists(atPath: renamedHTML.path), "cleanup cannot delete unowned files")
        IPAImport.removeOwned(owned, in: imports)
        try require(!fm.fileExists(atPath: owned.path) && fm.fileExists(atPath: another.path),
                    "cleanup removes only the previous imported file")
        print("PASS: imported IPA remains readable without the original provider URL")
        let app = root.appendingPathComponent("Example.app")
        let helper = root.appendingPathComponent("Helper.app")
        let framework = app.appendingPathComponent("Frameworks/Example.framework")
        for folder in [helper, framework, app.appendingPathComponent("SC_Info"), app.appendingPathComponent("Watch/Unused.app")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var binary = Data()
        let words: [UInt32] = [0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0,
                               0x2C, 24, 0x4000, 0x4000, 1, 0]
        for value in words {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { binary.append(contentsOf: $0) }
        }
        binary.append(Data(repeating: 0xA5, count: 0x8000 - binary.count))
        try binary.write(to: app.appendingPathComponent("Example"))
        let signedBinary = signedMachO()
        try signedBinary.write(to: framework.appendingPathComponent("Example"))
        let info = ["CFBundleExecutable": "Example", "CFBundleIdentifier": "test.example",
                    "CFBundleDisplayName": "Facebook", "CFBundleName": "Runner", "CFBundleShortVersionString": "0.012"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let helperInfo: [String: Any] = ["CFBundleIdentifier": "test.helper", "TetherDecryptTemplate": true]
        try PropertyListSerialization.data(fromPropertyList: helperInfo, format: .xml, options: 0)
            .write(to: helper.appendingPathComponent("Info.plist"))
        try Data("test-license".utf8).write(to: app.appendingPathComponent("SC_Info/Example.sinf"))
        let manifest = ["SinfPaths": ["SC_Info/Example.sinf"],
                        "SinfReplicationPaths": ["Frameworks/Example.framework/SC_Info/Example.sinf"]]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("SC_Info/Manifest.plist"))

        let prepared = try PayloadLayout.prepare(app: app, in: helper, log: { print($0) })
        let (payload, decoded) = try PayloadLayout.installed(in: helper)
        try require(payload.lastPathComponent == "Target", "encrypted payload is not a nested .app")
        try require(prepared.appName == "Example", "original output name retained")
        try require(decoded.runnerFilename == "Facebook.0.012.runner.ipa", "runner uses display name and version")
        try require(decoded.decryptedFilename == "Facebook.0.012-decrypted.ipa", "export uses display name and version")
        let installedInfo = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: helper.appendingPathComponent("Info.plist")), options: [], format: nil) as! [String: Any]
        try require(installedInfo["CFBundleDisplayName"] as? String == "Facebook Runner", "installed runner uses the display name")
        try require(installedInfo["TetherDecryptPreparedVersion"] as? String == "0.012", "installed runner retains the target version")
        let unsafeNames = PayloadManifest(version: 2, appName: "App", directory: "Target", binaries: [:],
                                          licenses: [:], displayName: "../Face:book/", appVersion: "0.01/2")
        try require(unsafeNames.runnerFilename == "_Face_book_.0.01_2.runner.ipa", "names are safe Windows filename components")
        let unicodeName = PayloadLayout.filenameComponent(String(repeating: "界", count: 100), fallback: "App")
        try require(unicodeName.utf8.count <= 96, "Unicode export names stay below filesystem byte limits")
        try require(PayloadLayout.filenameComponent("CON", fallback: "App") == "_CON", "Windows device names are escaped")
        print("PASS: exact app/version export names and safe filename components")
        try require(decoded.binaries.count == 2, "main executable and framework inventoried")
        try require(decoded.signingDigests?.count == 1, "signed framework has a signature-independent fingerprint")
        try require(!fm.fileExists(atPath: payload.appendingPathComponent("Watch").path), "Watch content excluded")
        let replica = payload.appendingPathComponent("Frameworks/Example.framework/SC_Info/Example.sinf")
        try require(fm.fileExists(atPath: replica.path), "framework SINF replicated before signing")
        try PayloadLayout.validate(decoded, at: payload, log: { print($0) })
        print("PASS: helper layout, licensing and inventory")
        for file in [helper.appendingPathComponent(PayloadLayout.manifestName),
                     helper.appendingPathComponent("EmbeddedPayload/\(PayloadLayout.backupName)"),
                     helper.appendingPathComponent("Info.plist")] {
            let mode = (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try require(mode & 0o444 == 0o444, "helper metadata remains readable after installer ownership changes")
        }
        print("PASS: prepared manifest resource permissions")

        var fallbackInfo = info
        fallbackInfo.removeValue(forKey: "CFBundleDisplayName")
        fallbackInfo.removeValue(forKey: "CFBundleShortVersionString")
        fallbackInfo["CFBundleName"] = "Fallback"
        fallbackInfo["CFBundleVersion"] = "9"
        for (name, metadata, expected) in [
            ("FallbackHelper", fallbackInfo, "Fallback.9.runner.ipa"),
            ("UnknownHelper", ["CFBundleExecutable": "Example"], "Example.unknown.runner.ipa")
        ] {
            let alternate = root.appendingPathComponent(name)
            try fm.createDirectory(at: alternate, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: helperInfo, format: .xml, options: 0)
                .write(to: alternate.appendingPathComponent("Info.plist"))
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
            let result = try PayloadLayout.prepare(app: app, in: alternate, log: { _ in })
            try require(result.runnerFilename == expected, "fallback metadata produces \(expected)")
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        print("PASS: missing display/version metadata has deterministic fallbacks")

        // Exercise the real C writer/reader, then the actual Swift decoder.
        let stage = root.appendingPathComponent("stage/Payload")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.copyItem(at: helper, to: stage.appendingPathComponent("Helper.app"))
        let archive = root.appendingPathComponent("prepared-helper.ipa")
        let unpacked = root.appendingPathComponent("unpacked")
        var error = [CChar](repeating: 0, count: Int(FP_ERRMAX))
        let capacity = error.count
        let packed = stage.deletingLastPathComponent().path.withCString { source in
            archive.path.withCString { target in fp_zip_dir(source, target, &error, capacity) }
        }
        try require(packed == 0, "prepared helper packs through the native ZIP writer")
        let importedArchive = try IPAImport.stage(archive, in: imports)
        try fm.removeItem(at: archive)
        let extracted = importedArchive.path.withCString { source in
            unpacked.path.withCString { target in fp_unzip(source, target, &error, capacity) }
        }
        try require(extracted == 0, "prepared helper unpacks through the native ZIP reader")
        let (roundTripPayload, roundTripManifest) = try PayloadLayout.installed(
            in: unpacked.appendingPathComponent("Payload/Helper.app"))
        try PayloadLayout.validate(roundTripManifest, at: roundTripPayload, log: { _ in })
        try require(roundTripManifest.runnerFilename == decoded.runnerFilename &&
                    roundTripManifest.decryptedFilename == decoded.decryptedFilename,
                    "app/version metadata survives the native IPA round trip")
        print("PASS: prepared helper manifest survives a native IPA round trip")

        let alias = root.appendingPathComponent("HelperAlias.app")
        try fm.createSymbolicLink(at: alias, withDestinationURL: helper)
        let future = try PayloadLayout.child("not-created-output.ipa", in: alias)
        try require(future.path == helper.resolvingSymlinksInPath().appendingPathComponent("not-created-output.ipa").path,
                    "nonexistent output uses its canonical root")
        let (_, aliasManifest) = try PayloadLayout.installed(in: alias)
        try require(aliasManifest.binaries == decoded.binaries, "aliased installed helper resolves correctly")
        print("PASS: aliased roots and nonexistent output names")
        let outsideLink = helper.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: outsideLink, withDestinationURL: root)
        try expectFailure("escaping symlink parent with missing leaf is rejected") {
            _ = try PayloadLayout.child("outside-link/missing.sinf", in: helper)
        }
        try fm.removeItem(at: outsideLink)

        try Data("corrupt sidecar".utf8).write(to: helper.appendingPathComponent(PayloadLayout.manifestName))
        let (_, jsonFallback) = try PayloadLayout.installed(in: helper)
        try require(jsonFallback.binaries == decoded.binaries, "JSON backup recovers a damaged plist")
        try fm.removeItem(at: helper.appendingPathComponent("EmbeddedPayload/\(PayloadLayout.backupName)"))
        let (_, infoFallback) = try PayloadLayout.installed(in: helper)
        try require(infoFallback.binaries == decoded.binaries, "Info.plist data recovers stripped sidecars")
        try require(infoFallback.signingDigests == decoded.signingDigests, "backup retains signing fingerprints")
        try require(infoFallback.decryptedFilename == decoded.decryptedFilename, "fallback retains export naming metadata")
        print("PASS: both manifest fallback paths retain the original fingerprints")

        let installedFramework = payload.appendingPathComponent("Frameworks/Example.framework/Example")
        var resigned = signedBinary
        resigned.replaceSubrange(0x8000..<0x8040, with: repeatElement(UInt8(0x33), count: 64))
        resigned.append(Data(repeating: 0x33, count: 64))
        store(128, at: 140, bytes: 4, in: &resigned)
        store(0x8000, at: 88, bytes: 8, in: &resigned)
        store(128, at: 104, bytes: 8, in: &resigned)
        try resigned.write(to: installedFramework)
        try PayloadLayout.validate(decoded, at: payload, log: { print($0) })
        print("PASS: framework re-signing changes only signature data and permitted size fields")
        var padded = resigned
        padded.append(Data(repeating: 0, count: 64))
        try padded.write(to: installedFramework)
        try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        padded[padded.count - 1] = 1
        try padded.write(to: installedFramework)
        try expectFailure("nonzero data after a signature is rejected") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        var changedPlaintext = resigned
        changedPlaintext[0x2000] ^= 1
        try changedPlaintext.write(to: installedFramework)
        try expectFailure("changed unencrypted bytes are rejected after re-signing") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        var changedCode = resigned
        changedCode[0x4000] ^= 1
        try changedCode.write(to: installedFramework)
        try expectFailure("changed encrypted page is rejected after re-signing") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        var clearedFlag = resigned
        store(0, at: 48, bytes: 4, in: &clearedFlag)
        try clearedFlag.write(to: installedFramework)
        try expectFailure("cleared cryptid without decryption is rejected") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        var movedData = resigned
        store(0x9000, at: 96, bytes: 8, in: &movedData)
        try movedData.write(to: installedFramework)
        try expectFailure("non-signing load-command changes are rejected") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        try resigned.write(to: installedFramework)
        let legacy = PayloadManifest(version: 1, appName: decoded.appName, directory: decoded.directory,
                                     binaries: decoded.binaries, licenses: decoded.licenses)
        let legacyDecoded = try PropertyListDecoder().decode(PayloadManifest.self, from: PropertyListEncoder().encode(legacy))
        try require(legacyDecoded.decryptedFilename == "Example-decrypted.ipa", "old helpers decode without new metadata")
        try expectFailure("legacy manifests without a code baseline retain strict validation") {
            try PayloadLayout.validate(legacy, at: payload, log: { _ in })
        }
        try signedBinary.write(to: installedFramework)

        let empty = root.appendingPathComponent("EmptyHelper.app")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: helperInfo, format: .xml, options: 0)
            .write(to: empty.appendingPathComponent("Info.plist"))
        try expectFailure("empty template is rejected with a distinct error") {
            _ = try PayloadLayout.installed(in: empty)
        }

        try Data("modified-by-signer".utf8).write(to: payload.appendingPathComponent("Example"))
        try expectFailure("modified embedded binary is rejected") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        try binary.write(to: payload.appendingPathComponent("Example"))
        try fm.removeItem(at: replica)
        try expectFailure("a stripped framework license is rejected") {
            try PayloadLayout.validate(decoded, at: payload, log: { _ in })
        }
        try expectFailure("manifest path traversal is rejected") {
            _ = try PayloadLayout.child("../../outside.sinf", in: app)
        }
        let malicious = ["SinfPaths": ["SC_Info/Example.sinf"], "SinfReplicationPaths": ["../outside.sinf"]]
        try PropertyListSerialization.data(fromPropertyList: malicious, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("SC_Info/Manifest.plist"))
        try expectFailure("unsafe SINF replication is rejected") {
            try PayloadLayout.replicateLicenses(in: app, log: { _ in })
        }
        print("All payload layout checks passed.")
    }
}
