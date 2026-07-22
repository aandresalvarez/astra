import Foundation
import Darwin
import RunBrokerKit
import ASTRACore
import ASTRARunLedger
import RunBrokerService
import RunSupervisorSupport

private enum BrokerMainError: Error {
    case invalidArguments
    case installationIdentityMismatch
    case unsafeRuntimeDirectory
}

private struct Arguments {
    let channel: RunBrokerChannel
    let installationID: RunBrokerInstallationID
    let supportDirectory: URL

    init(_ values: [String]) throws {
        var fields: [String: String] = [:]
        var index = 0
        while index < values.count {
            guard values[index].hasPrefix("--"), index + 1 < values.count else {
                throw BrokerMainError.invalidArguments
            }
            fields[values[index]] = values[index + 1]
            index += 2
        }
        guard let rawChannel = fields["--channel"],
              let channel = RunBrokerChannel(rawValue: rawChannel),
              let rawInstallationID = fields["--installation-id"],
              let installationUUID = UUID(uuidString: rawInstallationID),
              let rawSupportDirectory = fields["--support-directory"],
              NSString(string: rawSupportDirectory).isAbsolutePath else {
            throw BrokerMainError.invalidArguments
        }
        self.channel = channel
        self.installationID = RunBrokerInstallationID(rawValue: installationUUID)
        self.supportDirectory = URL(fileURLWithPath: rawSupportDirectory, isDirectory: true)
            .standardizedFileURL
    }
}

private struct BrokerStderrLogger: RunBrokerServiceLogging {
    func record(event: String, fields: [String: String]) {
        let suffix = fields.keys.sorted().map { key in
            "\(key)=\(fields[key] ?? "")"
        }.joined(separator: " ")
        let line = suffix.isEmpty ? event : "\(event) \(suffix)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private func run() throws -> Never {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let identity = RunBrokerChannelIdentity(
        channel: arguments.channel,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        channelApplicationSupportDirectory: arguments.supportDirectory.deletingLastPathComponent()
    )
    guard identity.supportDirectory == arguments.supportDirectory else {
        throw BrokerMainError.invalidArguments
    }
    let cohort = try RunBrokerCohortResolver.resolve(
        brokerExecutableURL: URL(fileURLWithPath: CommandLine.arguments[0])
    )
    let brokerVersion = cohort.brokerExecutableURL
        .deletingLastPathComponent()
        .lastPathComponent

    let secureStore = RunBrokerSecureStore(expectedUserID: getuid())
    // The socket is the broker's process-ownership lease. Acquire it before
    // creating credentials, opening the ledger, or starting recovery work so
    // a duplicate launch cannot produce durable or external side effects.
    let listener = try RunBrokerUnixSocketListener(
        identity: identity,
        secureStore: secureStore,
        expectedUserID: getuid()
    )
    let secrets = try secureStore.loadOrCreate(identity: identity)
    guard secrets.installationID == arguments.installationID else {
        throw BrokerMainError.installationIdentityMismatch
    }

    // One canonical ledger instance is shared by the scheduler, durable run
    // orchestrator, status reader, and projection outbox. No adapter owns a
    // second mutable database connection or projection cursor.
    let canonicalLedger = try RunLedger(configuration: .init(
        ledgerDirectoryURL: identity.ledgerDirectoryURL,
        installationID: secrets.installationID,
        exclusiveWriter: true
    ))
    let monitorLedger = RunBrokerRunLedgerAdapter(ledger: canonicalLedger)
    let runRoot = identity.supportDirectory.appendingPathComponent("Executions", isDirectory: true)
    let capabilityDirectory = identity.supportDirectory
        .appendingPathComponent("SupervisorCapabilities", isDirectory: true)
    try ensurePrivateDirectory(runRoot)
    let trustedRoot = try RunSupervisorTrustedRoot(path: runRoot.path)
    let vault = DarwinRunBrokerCapabilityVault(directoryURL: capabilityDirectory)
    let supervisorTransport = DarwinRunBrokerSupervisorTransport(trustedRoot: trustedRoot)
    let orchestrator = RunBrokerOrchestrator(
        ledger: canonicalLedger,
        vault: vault,
        spawner: DarwinRunBrokerSupervisorSpawner(runRootURL: runRoot),
        transport: supervisorTransport,
        installedBrokerExecutableURL: cohort.brokerExecutableURL,
        allowAuthenticatedImmediateTermination: true
    )
    let scheduler = RunBrokerMonitorScheduler(
        ledger: monitorLedger,
        monitor: UnavailableRunBrokerExternalOperationMonitor()
    )
    try scheduler.recover()
    let applicationService = RunBrokerApplicationService(
        ledger: canonicalLedger,
        orchestrator: orchestrator,
        vault: vault
    )
    applicationService.startExecutionReconciliation(logger: BrokerStderrLogger())
    applicationService.startRuntimeSwitchReconciliation(logger: BrokerStderrLogger())
    let authenticator = RunBrokerRequestAuthenticator(secret: secrets.capabilitySecret)
    let codeIdentityVerifier = DarwinRunBrokerPeerCodeIdentityVerifier()
    let peerPolicy = RunBrokerPeerIdentityPolicy(
        expectedUserID: getuid(),
        requiresCodeIdentity: codeIdentityVerifier.requiresDeveloperIDIdentity,
        codeIdentityVerifier: codeIdentityVerifier
    )
    let endpoint = RunBrokerRequestEndpoint(
        channel: arguments.channel,
        installationID: arguments.installationID,
        brokerVersion: brokerVersion,
        authenticator: authenticator,
        peerPolicy: peerPolicy,
        scheduler: scheduler,
        applicationHandler: applicationService
    )
    return try RunBrokerServer(
        listener: listener,
        endpoint: endpoint,
        responseAuthenticator: authenticator
    ).runForever()
}

/// Creates only broker-owned runtime storage. This is not installation or
/// rollout activation and never touches ASTRA.app or LaunchAgent state.
private func ensurePrivateDirectory(_ url: URL) throws {
    if mkdir(url.path, 0o700) != 0, errno != EEXIST {
        throw BrokerMainError.unsafeRuntimeDirectory
    }
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw BrokerMainError.unsafeRuntimeDirectory }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFDIR,
          status.st_uid == geteuid(),
          UInt16(status.st_mode & 0o777) == 0o700,
          status.st_nlink >= 2 else {
        throw BrokerMainError.unsafeRuntimeDirectory
    }
}

do {
    try run()
} catch {
    let message = "astra-run-broker failed closed: \(String(describing: type(of: error)))\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
