import XCTest
import Combine
import ZIPFoundation
@testable import iPadn

final class DecrypterIntegrationTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file) }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func package(families: [Int], platforms: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
        temporaryFiles.append(url)
        let archive = try Archive(url: url, accessMode: .create)
        let info: [String: Any] = ["CFBundleDisplayName": "Fixture", "CFBundleExecutable": "App",
                                   "UIDeviceFamily": families, "CFBundleSupportedPlatforms": platforms]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try archive.addEntry(with: "Payload/Fixture.app/Info.plist", type: .file,
                             uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
            data.subdata(in: Int(position)..<Int(position) + count)
        }
        return url
    }

    func testActionIsLimitedToCompletedIPAs() {
        let file = URL(fileURLWithPath: "/tmp/test.ipa")
        var job = DownloadJob(app: StoreApp(id: "1", name: "Fixture"))
        XCTAssertFalse(DecrypterEligibility.isCandidate(job, file: file))
        job.status = .completed
        XCTAssertTrue(DecrypterEligibility.isCandidate(job, file: file))
        XCTAssertFalse(DecrypterEligibility.isCandidate(job, file: nil))
        XCTAssertFalse(DecrypterEligibility.isCandidate(job, file: URL(fileURLWithPath: "/tmp/test.pkg")))
        job.rawFormat = "pkg"
        XCTAssertFalse(DecrypterEligibility.isCandidate(job, file: file))
        job.rawFormat = nil
        job.protectedMacPackage = true
        XCTAssertFalse(DecrypterEligibility.isCandidate(job, file: file))
    }

    func testActualPackagePlatformIsCheckedForImports() throws {
        XCTAssertNoThrow(try DecrypterEligibility.validatePackage(package(families: [1, 2], platforms: ["iPhoneOS"])))
        XCTAssertNoThrow(try DecrypterEligibility.validatePackage(package(families: [2], platforms: ["iPhoneOS"])))
        XCTAssertThrowsError(try DecrypterEligibility.validatePackage(package(families: [3], platforms: ["AppleTVOS"])))
        XCTAssertThrowsError(try DecrypterEligibility.validatePackage(package(families: [6], platforms: ["MacOSX"])))
    }

    func testVersionedNamesRemainSeparateFromBundleFolderName() {
        let manifest = PayloadManifest(version: 2, appName: "Runner", directory: "Target", binaries: [:],
                                       licenses: [:], displayName: "Facebook", appVersion: "0.012")
        XCTAssertEqual(manifest.runnerFilename, "Facebook.0.012.runner.ipa")
        XCTAssertEqual(manifest.decryptedFilename, "Facebook.0.012-decrypted.ipa")
        XCTAssertEqual(manifest.appName, "Runner")
    }

    @available(iOS 17.4, *)
    @MainActor
    func testConcurrentPreparationIsRejectedWithoutLeakingTheGate() {
        DecrypterPreparationModel.preparationBusy = true
        defer { DecrypterPreparationModel.preparationBusy = false }
        let model = DecrypterPreparationModel(source: URL(fileURLWithPath: "/tmp/test.ipa"))
        model.prepare()
        XCTAssertFalse(model.isPreparing)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(DecrypterPreparationModel.preparationBusy)
    }

    @available(iOS 17.4, *)
    @MainActor
    func testPreparationFailureReleasesTheGateAndPreservesTheInput() async throws {
        let file = try package(families: [1], platforms: ["iPhoneOS"])
        let original = try Data(contentsOf: file)
        let model = DecrypterPreparationModel(source: file)
        let finished = expectation(description: "Preparation fails cleanly on a fixture without executable/licenses")
        var started = false
        let subscription = model.$isPreparing.sink { running in
            if running { started = true }
            else if started { finished.fulfill() }
        }
        model.prepare()
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(subscription) {}
        XCTAssertFalse(DecrypterPreparationModel.preparationBusy)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.resultURL)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
