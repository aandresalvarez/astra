import Foundation
import Testing
@testable import RunBrokerKit

@Suite("RunBroker packaging and deferred rollout contract")
struct RunBrokerPackagingContractTests {
    @Test("Metadata validates signed version digest and fixed executable identity")
    func metadataContract() throws {
        let digest = String(repeating: "a", count: 64)
        let metadata = try RunBrokerPackagedPayloadMetadata(infoDictionary: [
            RunBrokerPackagedPayloadMetadata.infoSchemaVersionKey: 1,
            RunBrokerPackagedPayloadMetadata.infoVersionKey: "1.2.3-42-\(digest.prefix(32))",
            RunBrokerPackagedPayloadMetadata.infoSHA256Key: digest,
            RunBrokerPackagedPayloadMetadata.infoExecutableKey: "astra-run-broker"
        ])
        #expect(metadata.version.rawValue == "1.2.3-42-\(digest.prefix(32))")
        #expect(metadata.sha256.rawValue == digest)

        #expect(throws: RunBrokerPackageMetadataError.unexpectedExecutableName) {
            try RunBrokerPackagedPayloadMetadata(infoDictionary: [
                RunBrokerPackagedPayloadMetadata.infoSchemaVersionKey: 1,
                RunBrokerPackagedPayloadMetadata.infoVersionKey: "1",
                RunBrokerPackagedPayloadMetadata.infoSHA256Key: digest,
                RunBrokerPackagedPayloadMetadata.infoExecutableKey: "other-tool"
            ])
        }
    }

    @Test("Build packages broker payload but app startup has no implicit installer side effect")
    func packagedButNotAutoInstalled() throws {
        let root = repositoryRoot()
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"))
        let buildScript = try String(
            contentsOf: root.appendingPathComponent("script/build_and_run.sh")
        )
        let bundledInstaller = try String(
            contentsOf: root.appendingPathComponent(
                "Astra/Services/Capabilities/BundledToolInstaller.swift"
            )
        )
        let app = try String(contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"))

        #expect(package.contains(".executable(name: \"astra-run-broker\""))
        #expect(buildScript.contains("\"astra-run-broker\""))
        #expect(!bundledInstaller.contains("RunBrokerInstaller"))
        #expect(!app.contains("RunBrokerInstaller"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
