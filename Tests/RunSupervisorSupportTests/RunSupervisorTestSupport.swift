import ASTRACore
import Darwin
import Foundation
import RunSupervisorSupport

enum RunSupervisorTestSupport {
    static let fixedDate = Date(timeIntervalSince1970: 2_000_000_000)

    static func temporaryDirectory(_ suffix: String = "run") throws -> URL {
        let token = UUID().uuidString.prefix(8).lowercased()
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("as-\(suffix.prefix(8))-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func payload(
        executablePath: String = "/usr/bin/true",
        arguments: [String] = [],
        workingDirectory: String = "/tmp",
        environment: [String: String] = ["PATH": "/bin:/usr/bin"],
        supervisionPolicy: ExecutionSupervisionPolicySnapshot? = nil,
        identitySeed: UInt8 = 1,
        authorityEpoch: UInt64 = 1,
        capability: RunSupervisorCapability? = nil
    ) throws -> RunSupervisorBootstrapPayload {
        let summary: ExecutionLaunchArgumentSummary
        if arguments.isEmpty {
            summary = .none
        } else {
            summary = try .init(
                redactedArgumentCount: UInt(arguments.count),
                argumentsSHA256: RunSupervisorDigests.arguments(arguments)
            )
        }
        let manifest = ExecutionLaunchManifest(
            installationID: .init(rawValue: uuid(identitySeed)),
            storeID: .init(rawValue: uuid(identitySeed &+ 1)),
            executionID: .init(rawValue: uuid(identitySeed &+ 2)),
            taskID: uuid(identitySeed &+ 3),
            authority: .init(
                id: .init(rawValue: uuid(identitySeed &+ 4)),
                epoch: .init(rawValue: authorityEpoch)
            ),
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: executablePath,
                launchArguments: summary,
                workingDirectory: workingDirectory,
                environmentVariableNames: Array(environment.keys),
                configurationRevision: "test-revision"
            ),
            declaredEffects: [.computeOnly],
            supervisionPolicy: supervisionPolicy,
            createdAt: fixedDate
        )
        return .init(
            manifest: manifest,
            manifestSHA256: try RunSupervisorDigests.manifest(manifest),
            expectedIdentity: .init(manifest: manifest),
            arguments: arguments,
            environment: environment,
            capability: try capability ?? .init(bytes: Data(repeating: identitySeed, count: 32))
        )
    }

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    static func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func readPID(_ url: URL) throws -> pid_t {
        pid_t(try String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
