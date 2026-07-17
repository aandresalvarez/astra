import Foundation
import Darwin
import RunBrokerKit
import ASTRACore

private enum BrokerMainError: Error {
    case invalidArguments
    case installationIdentityMismatch
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

    let secureStore = RunBrokerSecureStore(expectedUserID: getuid())
    let secrets = try secureStore.loadOrCreate(identity: identity)
    guard secrets.installationID == arguments.installationID else {
        throw BrokerMainError.installationIdentityMismatch
    }

    let ledger = UnavailableRunBrokerMonitorLedger()
    let scheduler = RunBrokerMonitorScheduler(
        ledger: ledger,
        monitor: UnavailableRunBrokerExternalOperationMonitor()
    )
    let authenticator = RunBrokerRequestAuthenticator(secret: secrets.capabilitySecret)
    let peerPolicy = RunBrokerPeerIdentityPolicy(expectedUserID: getuid())
    let brokerVersion = identity.currentExecutableURL
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .lastPathComponent
    let endpoint = RunBrokerRequestEndpoint(
        channel: arguments.channel,
        installationID: arguments.installationID,
        brokerVersion: brokerVersion,
        authenticator: authenticator,
        peerPolicy: peerPolicy,
        scheduler: scheduler
    )
    let listener = try RunBrokerUnixSocketListener(
        identity: identity,
        secureStore: secureStore,
        expectedUserID: getuid()
    )
    return try RunBrokerServer(listener: listener, endpoint: endpoint).runForever()
}

do {
    try run()
} catch {
    let message = "astra-run-broker failed closed: \(String(describing: type(of: error)))\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
