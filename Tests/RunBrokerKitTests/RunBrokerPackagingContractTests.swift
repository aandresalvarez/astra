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

    @Test("Release builds generate a Sparkle-signed successor manifest before outer signing")
    func releasePackagesSignedSuccessorManifest() throws {
        let root = repositoryRoot()
        let build = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"))
        let release = try String(contentsOf: root.appendingPathComponent("script/release_update.sh"))
        let generation = try build.indexOf("generate_run_broker_successor_manifest")
        let outerSigning = try build.indexOf("# Sign only the outer app")
        #expect(generation < outerSigning)
        #expect(build.contains("RunBrokerSuccessorManifest.json"))
        #expect(build.contains("RunBrokerSuccessorManifest.sig"))
        #expect(build.contains("$signer -p \"$manifest\""))
        #expect(build.contains("codesign --remove-signature \"$unsigned_copy\""))
        #expect(release.contains("SPARKLE_SIGN_UPDATE"))
        #expect(release.contains("ASTRA_SPARKLE_SIGN_UPDATE=\"$SIGN_UPDATE\""))
    }

    @Test("Broker acquires singleton ownership before credentials, ledger, and recovery")
    func brokerOwnershipPrecedesRecovery() throws {
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
        let ownership = try main.indexOf("RunBrokerUnixSocketListener(")
        let credentials = try main.indexOf("secureStore.loadOrCreateInstallationID(")
        let ledger = try main.indexOf("RunLedger(configuration:")
        let recovery = try main.indexOf("try scheduler.recover()")
        let reconciliation = try main.indexOf("startRuntimeSwitchReconciliation(")
        #expect(ownership < credentials)
        #expect(ownership < ledger)
        #expect(ownership < recovery)
        #expect(ownership < reconciliation)
    }

    @Test("same-UID providers cannot obtain the broker request capability from disk")
    func brokerCapabilityUsesExactCodeKeychainACL() throws {
        let root = repositoryRoot()
        let bootstrap = try String(contentsOf: root.appendingPathComponent(
            "RunBrokerKit/RunBrokerClientBootstrap.swift"
        ))
        let broker = try String(contentsOf: root.appendingPathComponent(
            "Tools/AstraRunBrokerTool/main.swift"
        ))
        let keychain = try String(contentsOf: root.appendingPathComponent(
            "AstraObjCSupport/AstraSecureKeychain.m"
        ))

        #expect(!bootstrap.contains("name: capability"))
        #expect(bootstrap.contains("RunBrokerCapabilityKeychainStore().load("))
        #expect(broker.contains("RunBrokerCapabilityKeychainStore().load("))
        #expect(!broker.contains("secrets.capabilitySecret"))
        #expect(keychain.contains("SecTrustedApplicationCreateFromPath("))
        #expect(keychain.contains("SecAccessCreate("))
        #expect(keychain.contains("if (paths.count < 2) { return NULL; }"))
        #expect(keychain.contains("[self disableKeychainUserInteractionSavingPrevious:"))
        #expect(keychain.contains("SecKeychainItemSetAccess(existing, access)"))
    }

    @Test("code identity gates supervisor secrets and capability authentication")
    func supervisorIdentityOrdering() throws {
        let root = repositoryRoot()
        let spawner = try String(contentsOf: root.appendingPathComponent(
            "RunBrokerService/DarwinRunBrokerSupervisorSpawner.swift"
        ))
        #expect(try spawner.indexOf("codeIdentityResolver.resolve(processID: pid)")
            < spawner.indexOf("RunSupervisorFrameIO.writeFrame("))

        let executable = try String(contentsOf: root.appendingPathComponent(
            "RunSupervisorSupport/RunSupervisorExecutable.swift"
        ))
        #expect(try executable.indexOf("resolve(processID: getppid())")
            < executable.indexOf("RunSupervisorFrameIO.readFrame("))

        let socket = try String(contentsOf: root.appendingPathComponent(
            "RunSupervisorSupport/RunSupervisorUnixSocket.swift"
        ))
        #expect(try socket.indexOf("peerVerifier.verify(processID: processID)")
            < socket.indexOf("authenticator.authenticate(request, peerUID: uid)"))
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
