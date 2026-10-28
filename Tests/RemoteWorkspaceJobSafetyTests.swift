import Foundation
import Testing
@testable import WorkspaceToolSupport

@Suite("Remote job launch and observation safety")
struct RemoteWorkspaceJobSafetyTests {
    @Test("Repeating an uncertain launch reuses its durable intent")
    func retryDoesNotLaunchAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CountingRemoteTransport()
        let configuration = RemoteWorkspaceJobConfiguration(recordRootPath: root.path, sshExecutable: "/usr/bin/ssh",
            connections: [.init(id: "host", name: "QA", target: "qa", arguments: ["qa"])], taskID: "task", runID: "run")
        let first = RemoteWorkspaceJobManager(configuration: configuration, transport: transport)
        let second = RemoteWorkspaceJobManager(configuration: configuration, transport: transport)
        let a = try #require(record(first.start(connectionTarget: "qa", command: "sleep 30")))
        let b = try #require(record(second.start(connectionTarget: "qa", command: "sleep 30")))
        #expect(a.jobID == b.jobID)
        #expect(transport.launches == 1)
    }

    @Test("A probe marker with missing fields cannot prove process absence")
    func incompleteProbeIsUnknown() {
        #expect(RemoteWorkspaceJobHostSnapshot.parse("astra_probe=1\nstate=present\n") == nil)
    }

    @Test("Admission rejects an implicit SSH target even with one connection")
    func explicitTargetRequired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = RemoteWorkspaceJobConfiguration(recordRootPath: root.path, sshExecutable: "/usr/bin/ssh",
            connections: [.init(id: "qa", name: "QA", target: "qa", arguments: ["qa"])])
        #expect(throws: (any Error).self) { try RemoteWorkspaceJobManager(configuration: config).register(connectionTarget: nil, command: "sudo example") }
        #expect(throws: (any Error).self) { try RemoteWorkspaceJobCLI.parse(["start", "--", "sudo example"]) }
    }

    private func record(_ outcome: RemoteWorkspaceJobOutcome) -> RemoteWorkspaceJobRecord? {
        switch outcome {
        case .record(let value): value
        case .failure(_, let value): value
        }
    }
}

private final class CountingRemoteTransport: RemoteWorkspaceJobTransport {
    var launches = 0
    func run(connection: RemoteWorkspaceJobConnection, script: String, timeoutSeconds: TimeInterval) -> RemoteWorkspaceJobTransportResult {
        if script.contains("astra_clock") {
            return .init(exitCode: 0, stdout: "{\"astra_clock\":2,\"clock_domain\":\"posix-clock-monotonic-v1\",\"boot_id\":\"qa-boot\",\"monotonic\":1234}", stderr: "")
        }
        if script.contains("command.sh") { launches += 1 }
        return .init(exitCode: 255, stdout: "", stderr: "connection lost")
    }
}
