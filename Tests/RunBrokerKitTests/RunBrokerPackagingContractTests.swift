import Foundation
import Testing
@testable import RunBrokerKit

@Suite("RunBroker packaging and deferred rollout contract")
struct RunBrokerPackagingContractTests {
    @Test("Metadata validates signed version digest and fixed executable identity")
    func metadataContract() throws {
        let digest = try RunBrokerSHA256Digest(rawValue: String(repeating: "a", count: 64))
        let supervisorDigest = try RunBrokerSHA256Digest(
            rawValue: String(repeating: "b", count: 64)
        )
        let cohortDigest = try RunBrokerCohort.digest(
            brokerSHA256: digest,
            supervisorSHA256: supervisorDigest
        )
        let metadata = try RunBrokerPackagedPayloadMetadata(infoDictionary: [
            RunBrokerPackagedPayloadMetadata.infoSchemaVersionKey: 2,
            RunBrokerPackagedPayloadMetadata.infoVersionKey:
                "1.2.3-42-\(cohortDigest.rawValue.prefix(32))",
            RunBrokerPackagedPayloadMetadata.infoSHA256Key: digest.rawValue,
            RunBrokerPackagedPayloadMetadata.infoExecutableKey: "astra-run-broker",
            RunBrokerPackagedPayloadMetadata.infoSupervisorSHA256Key: supervisorDigest.rawValue,
            RunBrokerPackagedPayloadMetadata.infoSupervisorExecutableKey: "astra-run-supervisor",
            RunBrokerPackagedPayloadMetadata.infoCohortSHA256Key: cohortDigest.rawValue
        ])
        #expect(metadata.version.rawValue == "1.2.3-42-\(cohortDigest.rawValue.prefix(32))")
        #expect(metadata.sha256 == digest)
        #expect(metadata.supervisorSHA256 == supervisorDigest)
        #expect(metadata.cohortSHA256 == cohortDigest)

        #expect(throws: RunBrokerPackageMetadataError.unexpectedExecutableName) {
            try RunBrokerPackagedPayloadMetadata(infoDictionary: [
                RunBrokerPackagedPayloadMetadata.infoSchemaVersionKey: 2,
                RunBrokerPackagedPayloadMetadata.infoVersionKey: "1",
                RunBrokerPackagedPayloadMetadata.infoSHA256Key: digest.rawValue,
                RunBrokerPackagedPayloadMetadata.infoExecutableKey: "other-tool",
                RunBrokerPackagedPayloadMetadata.infoSupervisorSHA256Key:
                    supervisorDigest.rawValue,
                RunBrokerPackagedPayloadMetadata.infoSupervisorExecutableKey:
                    "astra-run-supervisor",
                RunBrokerPackagedPayloadMetadata.infoCohortSHA256Key: cohortDigest.rawValue
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

    @Test("Broker executable opens and recovers the canonical RunLedger before serving")
    func brokerUsesCanonicalLedger() throws {
        let main = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "Tools/AstraRunBrokerTool/main.swift"
            )
        )
        #expect(main.contains("RunBrokerRunLedgerAdapter("))
        #expect(main.contains("try scheduler.recover()"))
        #expect(!main.contains("let ledger = UnavailableRunBrokerMonitorLedger()"))
        #expect(try main.indexOf("RunBrokerCohortResolver.resolve(") < main.indexOf(
            "RunBrokerRunLedgerAdapter("
        ))
        #expect(try main.indexOf("try scheduler.recover()") < main.indexOf(
            "RunBrokerUnixSocketListener("
        ))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension String {
    func indexOf(_ needle: String) throws -> String.Index {
        try #require(range(of: needle)?.lowerBound)
    }
}
