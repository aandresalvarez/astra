import Foundation
import Testing
import ASTRACore
import WorkspaceToolSupport
@testable import ASTRA

@Suite("Remote job native broker launch protocol", .serialized)
struct RemoteWorkspaceJobBrokerProtocolTests {
    @Test("The native file-drop client needs a one-shot permit before sending SSH start", arguments: ["start", "withdraw", "oldHelper"])
    func launchProtocol(mode: String) async throws {
        let host = try FakeSSHHost(); defer { host.cleanup() }
        let configuration = host.configuration
        let evidence = RuntimeManagedSSHBrokerEvidence()
        let token = HostControlBrokerFileDrop.newToken()
        let command = RemoteWorkspaceJobCLI.Command.start(connection: "pcornet-backup", label: nil,
            timeoutSeconds: 10, command: "touch protocol-launched")
        let listener = HostControlBrokerDropListener(token: token,
            authorize: { $0 == ProcessInfo.processInfo.processIdentifier }, handle: { line in
                let manager = host.manager()
                let reply = RemoteWorkspaceJobBroker.reply(to: line, manager: manager, evidence: evidence)
                if mode == "withdraw", reply.created, let jobID = reply.record?.jobID {
                    _ = manager.cancel(jobID: jobID)
                }
                return String(decoding: try! JSONEncoder().encode(reply), as: UTF8.self)
            })
        let directory = try #require(listener.start(candidateDirectory: "/tmp/astra-job-protocol-" + UUID().uuidString))
        defer { listener.invalidate(); try? FileManager.default.removeItem(atPath: directory) }
        if mode == "oldHelper" {
            let request = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            let raw = try HostControlBrokerFileDropClient.exchange(request, directory: directory, token: token, timeout: 20)
            let reply = try JSONDecoder().decode(RemoteWorkspaceJobBrokerClient.Reply.self, from: Data(raw.utf8))
            // The old client explicitly refuses a missing launch clock, so a
            // pending permit is never usable through the old handshake.
            #expect(reply.created && reply.record?.remoteClock == nil)
        } else {
            let output = RemoteWorkspaceJobBrokerClient.run(command, configuration: configuration,
                environment: [RemoteWorkspaceJobBrokerClient.directoryKey: directory, RemoteWorkspaceJobBrokerClient.tokenKey: token])
            #expect(output.exitCode == (mode == "start" ? 0 : 1), "\(output.stderr)")
        }
        var job = try #require(host.manager().store.records().first)
        if mode == "start" {
            for _ in 0..<100 where !job.status.isTerminal {
                try await Task.sleep(for: .milliseconds(50))
                _ = host.manager().status(jobID: job.jobID)
                job = try host.manager().store.load(jobID: job.jobID)
            }
            #expect(job.status.isTerminal)
        }
        #expect(job.launchPermit == (mode == "start" ? .issued : mode == "withdraw" ? .withdrawn : .pending))
        #expect(FileManager.default.fileExists(atPath: host.home.appendingPathComponent("protocol-launched").path) == (mode == "start"))
        #expect(evidence.accounts(for: [command]))
    }
}
