import Foundation
import ASTRACore
import WorkspaceToolSupport

/// A registration broker, not a command executor. Only the native helper can
/// launch SSH; ASTRA subsequently observes/cancels its admitted job identities.
final class RemoteWorkspaceJobBroker: @unchecked Sendable {
    let evidence = RuntimeManagedSSHBrokerEvidence()
    let token: String
    private(set) var directory: String?
    private var listener: HostControlBrokerDropListener?

    init(configuration: RemoteWorkspaceJobConfiguration, helperPath: String) throws {
        token = HostControlBrokerFileDrop.newToken()
        let evidence = self.evidence
        let listener = HostControlBrokerDropListener(token: token, authorize: { pid in
            configuration.ownerBinding?.authorizesHelper(pid, executable: helperPath) == true
        }, handle: { line in
            let reply = Self.reply(to: line, manager: RemoteWorkspaceJobManager(configuration: configuration), evidence: evidence)
            return (try? JSONEncoder().encode(reply)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        })
        guard let directory = listener.start(candidateDirectory: "/tmp/astra-remote-job-" + UUID().uuidString) else {
            throw RemoteWorkspaceJobError.invalidArgument("ASTRA could not prepare protected remote job registration.")
        }
        self.directory = directory
        self.listener = listener
    }

    /// The same handler is exercised through the local file-drop fixture.
    static func reply(to line: String, manager: RemoteWorkspaceJobManager,
                      evidence: RuntimeManagedSSHBrokerEvidence) -> RemoteWorkspaceJobBrokerClient.Reply {
        let reply: RemoteWorkspaceJobBrokerClient.Reply
        do {
            let command = try JSONDecoder().decode(RemoteWorkspaceJobCLI.Command.self, from: Data(line.utf8))
            evidence.beginCommand()
            if case .start(let connection, let label, let timeout, let text) = command {
                let admission = try manager.register(connectionTarget: connection, command: text, label: label, timeoutSeconds: timeout)
                // Older helpers stop when no launch clock is returned. Only
                // the new permit exchange receives launchable parameters.
                var registration = admission.record
                registration.remoteClock = nil
                reply = .init(record: registration, connection: try manager.connection(target: connection), created: admission.created)
                evidence.acknowledge(command)
            } else if case .authorizeLaunch(let jobID) = command {
                reply = .init(record: try manager.authorizeLaunch(jobID: jobID))
            } else {
                reply = .init(output: RemoteWorkspaceJobCLI.run(command, manager: manager))
                evidence.acknowledge(command)
            }
        } catch {
            reply = .init(output: .init(exitCode: 1, stdout: "", stderr: error.localizedDescription + "\n"))
        }
        return reply
    }

    deinit { listener?.invalidate() }
}
