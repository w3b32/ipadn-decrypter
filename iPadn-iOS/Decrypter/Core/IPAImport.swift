import Foundation

/// Own the imported bytes before the picker/provider revokes its temporary URL.
/// This also keeps preparation independent of security-scope return values for
/// files already copied into our sandbox by UIDocumentPicker's import mode.
enum IPAImport {
    static func stage(_ source: URL, in root: URL) throws -> URL {
        let fm = FileManager.default
        guard source.isFileURL, source.pathExtension.lowercased() == "ipa" else {
            throw PayloadLayoutError.invalid("Choose a file ending in .ipa.")
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PayloadLayoutError.invalid("The selected IPA is not a regular file.")
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: destination)
            let file = try FileHandle(forReadingFrom: destination)
            defer { try? file.close() }
            // Real IPA contents are validated by the native ZIP reader later.
            // Reject a renamed HTML/error page now, before it becomes selected.
            guard try file.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw PayloadLayoutError.invalid("This file is not a readable IPA/ZIP archive.")
            }
            return destination
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    static func removeOwned(_ url: URL?, in root: URL) {
        guard let url else { return }
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard folder.deletingLastPathComponent().path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              UUID(uuidString: folder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
