import Foundation
import ASTRACore

/// Registration belongs to ASTRA. The helper performs the initial SSH command
/// in the provider's sandbox, preserving the provider's permission boundary.
public enum RemoteWorkspaceJobBrokerClient {
    public static let directoryKey = "ASTRA_REMOTE_JOB_BROKER_DROP"
    public static let tokenKey = "ASTRA_REMOTE_JOB_BROKER_TOKEN"

    public struct Reply: Codable, Sendable {
        public var record: RemoteWorkspaceJobRecord?
        public var connection: RemoteWorkspaceJobConnection?
        public var created: Bool
        public var output: RemoteWorkspaceJobCLI.Output?
        public init(record: RemoteWorkspaceJobRecord? = nil, connection: RemoteWorkspaceJobConnection? = nil,
                    created: Bool = false, output: RemoteWorkspaceJobCLI.Output? = nil) {
            self.record = record; self.connection = connection; self.created = created; self.output = output
        }
    }

    public static func run(_ command: RemoteWorkspaceJobCLI.Command,
                           configuration: RemoteWorkspaceJobConfiguration, environment: [String: String]) -> RemoteWorkspaceJobCLI.Output {
        do {
            guard let directory = environment[directoryKey], let token = environment[tokenKey] else {
                throw RemoteWorkspaceJobError.notOffered
            }
            func exchange(_ command: RemoteWorkspaceJobCLI.Command) throws -> Reply {
                let line = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
                let reply = try HostControlBrokerFileDropClient.exchange(line, directory: directory, token: token, timeout: 80)
                return try JSONDecoder().decode(Reply.self, from: Data(reply.utf8))
            }
            let reply = try exchange(command)
            if let output = reply.output { return output }
            guard let record = reply.record else { throw RemoteWorkspaceJobError.notOffered }
            if reply.created {
                guard case .start = command, let connection = reply.connection, let nonce = record.launchNonce,
                      record.taskID == configuration.taskID, record.runID == configuration.runID,
                      record.ownerID == configuration.ownerBinding?.ownerID,
                      record.executionID == configuration.ownerBinding?.executionID else {
                    throw RemoteWorkspaceJobError.notOffered
                }
                guard let remoteClock = record.remoteClock else {
                    return .init(exitCode: 1, stdout: "remote_job_id: \(record.jobID)\nstatus: unverified\n",
                        stderr: (record.message ?? "Remote clock unavailable; no command was launched.") + "\n")
                }
                try configuration.ownerBinding?.validateLaunch()
                let result = SSHRemoteWorkspaceJobTransport(sshExecutable: configuration.sshExecutable).run(
                    connection: connection, script: RemoteWorkspaceJobScripts.start(jobID: record.jobID,
                        command: record.command, timeoutSeconds: record.timeoutSeconds, nonce: nonce, clock: remoteClock), timeoutSeconds: 90)
                if result.exitCode != 0 || result.timedOut {
                    return .init(exitCode: 1, stdout: "remote_job_id: \(record.jobID)\nstatus: unverified\n",
                        stderr: "The launch reply is uncertain. ASTRA is checking the existing job; do not repeat the remote command. \(result.stderr)\n")
                }
            }
            guard let output = try exchange(.status(jobID: record.jobID)).output else {
                throw RemoteWorkspaceJobError.invalidArgument("ASTRA registered job \(record.jobID); status is unavailable. No second launch is permitted.")
            }
            return output
        } catch {
            return .init(exitCode: 1, stdout: "", stderr: error.localizedDescription + "\n")
        }
    }
}
