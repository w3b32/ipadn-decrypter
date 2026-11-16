// swift-tools-version:6.0
import PackageDescription
import Foundation

let generatedExcludes = ["Tests/__pycache__"].filter {
    FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent($0).path)
}

let package = Package(
    name: "DecrypterHostChecks",
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")],
    targets: [
        .target(name: "FPCoreNative", path: "Core", sources: ["FPCore.c"],
                publicHeadersPath: ".", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "PayloadLayoutTests", dependencies: [
            "FPCoreNative", .product(name: "Crypto", package: "swift-crypto")
        ], path: ".", exclude: ["Runner", "PROVENANCE.json", "README.md",
            "Core/Decryptor.swift", "Core/FPCore.c", "Core/FPCore.h", "Core/Bridging.h",
            "Tests/test_native.py", "Tests/test_integration_packaging.py", "Tests/kernel_stub.c"] + generatedExcludes, sources: [
            "Core/PayloadLayout.swift", "Core/IPAImport.swift", "Tests/PayloadLayoutTests.swift"
        ])
    ], swiftLanguageModes: [.v5]
)
