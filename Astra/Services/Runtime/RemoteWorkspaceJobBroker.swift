import Foundation
import ASTRACore
import WorkspaceToolSupport

/// A registration broker, not a command executor. Only the native helper can
/// launch SSH; ASTRA subsequently observes/cancels its admitted job identities.
final class RemoteWorkspaceJobBroker: @unchecked Sendable {
    let token: String
    private(set) var directory: String?
    private var listener: HostControlBrokerDropListener?

    init(configuration: RemoteWorkspaceJobConfiguration, helperPath: String) throws {
        token = HostControlBrokerFileDrop.newToken()
        let listener = HostControlBrokerDropListener(token: token, authorize: { pid in
            configuration.ownerBinding?.authorizesHelper(pid, executable: helperPath) == true
        }, handle: { line in
            let manager = RemoteWorkspaceJobManager(configuration: configuration)
            let reply: RemoteWorkspaceJobBrokerClient.Reply
            do {
                let command = try JSONDecoder().decode(RemoteWorkspaceJobCLI.Command.self, from: Data(line.utf8))
                if case .start(let connection, let label, let timeout, let text) = command {
                    let admission = try manager.register(connectionTarget: connection, command: text, label: label, timeoutSeconds: timeout)
                    reply = .init(record: admission.record, connection: try manager.connection(target: connection), created: admission.created)
                } else {
                    reply = .init(output: RemoteWorkspaceJobCLI.run(command, manager: manager))
                }
            } catch {
                reply = .init(output: .init(exitCode: 1, stdout: "", stderr: error.localizedDescription + "\n"))
            }
            return (try? JSONEncoder().encode(reply)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        })
        guard let directory = listener.start(candidateDirectory: "/tmp/astra-remote-job-" + UUID().uuidString) else {
            throw RemoteWorkspaceJobError.invalidArgument("ASTRA could not prepare protected remote job registration.")
        }
        self.directory = directory
        self.listener = listener
    }

    deinit { listener?.invalidate() }
}
