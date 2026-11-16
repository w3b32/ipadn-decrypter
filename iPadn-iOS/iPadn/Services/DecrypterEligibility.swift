import Foundation

enum DecrypterEligibility {
    static func isCandidate(_ job: DownloadJob, file: URL?) -> Bool {
        job.status == .completed && job.rawFormat == nil && job.protectedMacPackage != true &&
            job.platformLabel != "tvOS" && file?.pathExtension.lowercased() == "ipa"
    }

    /// Imported files have no reliable storefront platform label. Validate the
    /// package metadata itself before passing any bytes to the proven core.
    static func validatePackage(_ file: URL) throws {
        let families = try PackageService.deviceFamilies(file)
        let platforms = try PackageService.supportedPlatforms(file).map { $0.lowercased() }
        guard (families.isEmpty || !families.isDisjoint(with: [1, 2])),
              (platforms.isEmpty || platforms.contains("iphoneos")) else {
            throw ToolError.message(AppText.text("This runner supports iPhone and iPad IPAs only."))
        }
    }
}
