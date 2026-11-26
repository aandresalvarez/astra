import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A queued run's broker is prepared from the run's launch copy, whose grants
/// are the ones its request froze. A grant saved after that and before the
/// provider starts still has to reach that broker: otherwise the chat says the
/// connector was allowed and the run answers that its credential is held back.
@Suite("Brokered credentials from saved grants", .serialized)
@MainActor
struct BrokeredCredentialSavedGrantTests {
    private typealias Fixture = BrokeredCredentialApprovalLoopTests.Fixture

    @Test("A connector Auto allows at launch, answering an open offer, is usable by that run's broker")
    func autoGrantAtLaunchReachesTheBroker() async throws {
        let launch = try QueuedFollowUp()
        defer { launch.cleanUp() }
        try launch.offerREDCapFromAnAskRun()

        let replies = try await launch.brokerStatus(atLaunch: { run, admitted in
            let preflight = await AgentRuntimeLaunchPreflight.preflightConnectorsBeforeLaunchResult(
                task: launch.fixture.task,
                run: run,
                modelContext: launch.fixture.context,
                phase: .resume,
                contextText: Fixture.unrelatedTurn,
                permissionPolicy: .autonomous,
                capabilityResolutionSnapshot: admitted,
                secretStore: launch.fixture.store,
                persistAutoCredentialGrant: { _, context in (try? context.save()) != nil }
            )
            #expect(preflight.didPass)
        })

        #expect(launch.fixture.task.events.contains {
            $0.payload == "Auto allowed Registry Export to use its saved credentials for this task."
        })
        #expect(replies.redcap.contains("api_token_present: true"), "\(replies.redcap)")
        #expect(!replies.redcap.contains("credentials_withheld"))
        // Only what was granted: the connector nobody offered stays held back.
        #expect(replies.jira.contains("api_token_present: withheld"), "\(replies.jira)")
        replies.expectNoSecrets()
    }

    @Test("An approval saved while the request waits reaches its run's broker")
    func approvalWhileQueuedReachesTheBroker() async throws {
        let launch = try QueuedFollowUp()
        defer { launch.cleanUp() }
        try launch.offerREDCapFromAnAskRun()

        let replies = try await launch.brokerStatus(whileQueued: {
            guard case .saved = PermissionApprovalResolutionService.approve(
                task: launch.fixture.task, scope: .task, modelContext: launch.fixture.context
            ) else {
                Issue.record("Expected the offer to be saved for future use")
                return
            }
        })

        #expect(replies.redcap.contains("api_token_present: true"), "\(replies.redcap)")
        #expect(replies.jira.contains("api_token_present: withheld"), "\(replies.jira)")
        replies.expectNoSecrets()
    }

    /// A grant counts once the store holds it, and only for the provider it was
    /// made for.
    @Test("An unsaved grant, or another provider's, stays held back",
          arguments: [(false, AgentRuntimeID.claudeCode), (true, AgentRuntimeID.copilotCLI)])
    func onlySavedGrantsForThisProviderOpen(saved: Bool, provider: AgentRuntimeID) async throws {
        let launch = try QueuedFollowUp()
        defer { launch.cleanUp() }
        let context = launch.fixture.context
        context.autosaveEnabled = false

        let replies = try await launch.brokerStatus(atLaunch: { _, _ in
            _ = TaskRuntimePermissionGrants.record(
                grants: [.credential(label: Fixture.redcapCredentialLabel(launch.fixture.redcapConnector.id))],
                providerID: provider,
                task: launch.fixture.task,
                modelContext: context,
                source: "auto_policy"
            )
            if saved { try context.save() }
        })

        #expect(replies.redcap.contains("api_token_present: withheld"), "\(replies.redcap)")
        replies.expectNoSecrets()
    }

    private struct Replies {
        let redcap: String
        let jira: String

        func expectNoSecrets() {
            for reply in [redcap, jira] {
                #expect(!reply.contains(Fixture.redcapSecret))
                #expect(!reply.contains(Fixture.jiraSecret))
            }
        }
    }

    /// One queued follow-up on a turn that names neither connector, launched in
    /// the order `AgentRuntimeWorker` launches it, with the real broker session.
    @MainActor
    private struct QueuedFollowUp {
        let fixture: Fixture
        let directory: URL

        init() throws {
            fixture = try Fixture()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("astra-saved-grant-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fixture.workspace.primaryPath = directory.path
            try fixture.context.save()
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// What an Ask run that reached REDCap leaves behind.
        func offerREDCapFromAnAskRun() throws {
            let run = fixture.finishedRun()
            run.runtimeID = AgentRuntimeID.claudeCode.rawValue
            let ledger = BrokeredCredentialApprovalLedger.shared
            ledger.record(
                .init(connectorID: fixture.redcapConnector.id, connectorName: fixture.redcapConnector.name,
                      alias: "registry-export", serviceType: "redcap",
                      credentialLabels: [Fixture.redcapCredentialLabel(fixture.redcapConnector.id)]),
                taskID: fixture.task.id,
                runID: run.id
            )
            BrokeredCredentialApprovalDiscovery.recordWithheldCredentialRequests(
                task: fixture.task, run: run, modelContext: fixture.context,
                policyLevel: .review, runFinishedCleanly: true, ledger: ledger
            )
            try fixture.context.save()
            #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        }

        func brokerStatus(
            whileQueued: () throws -> Void = {},
            atLaunch: (TaskRun, TaskCapabilityResolutionSnapshot) async throws -> Void = { _, _ in }
        ) async throws -> Replies {
            let task = fixture.task
            let context = fixture.context
            let submission = try ExecutionRequestSubmissionService
                .submitFollowUp(message: Fixture.unrelatedTurn, for: task, into: context).get()
            try whileQueued()
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            // The worker makes the launch copy before the preflight.
            let projection = DetachedLaunchProjection(snapshot, from: task)
            let admitted = TaskCapabilityResolutionSnapshot.capture(
                for: projection.task, providerLaunchContextText: Fixture.unrelatedTurn,
                runtime: .claudeCode, secretStore: fixture.store
            )
            let run = TaskRun(task: task)
            run.runtimeID = AgentRuntimeID.claudeCode.rawValue
            context.insert(run)
            try context.save()

            try await atLaunch(run, admitted)

            let scope = admitted.addingApprovedCredentialLabels(
                TaskRuntimePermissionGrants.approvedCredentialLabels(for: task, runtime: .claudeCode),
                secretStore: fixture.store
            ).providerLaunch
            let execution = AgentRuntimeExecutionContext.make(
                launchTask: projection.task, executionPath: directory.path, shouldCleanupIsolation: false
            )
            defer { withExtendedLifetime((projection, execution)) {} }

            let registry = HostControlBrokerSessionRegistry.shared
            registry.bindHistory(container: fixture.container, taskID: task.id, runID: run.id,
                                 ownerID: task.persistentModelID)
            defer { registry.unbindHistory(taskID: task.id, runID: run.id, ownerID: task.persistentModelID) }
            // This test process stands in for the host-control helper, and its
            // parent for the provider that launched it.
            try #require(registry.prepare(
                task: execution.task, runID: run.id, runtime: .claudeCode, capabilityScope: scope,
                requiredTools: ["jira", "redcap"], currentDirectory: directory.path,
                expectedHelperPath: Self.testProcessPath(), secretStore: fixture.store
            ))
            defer { registry.stop(taskID: task.id, runID: run.id) }
            registry.registerProviderProcess(taskID: task.id, runID: run.id, processID: getppid())
            let socketPath = try #require(registry.endpoint(taskID: task.id, runID: run.id))

            return Replies(
                redcap: try await Self.status("redcap", socketPath: socketPath),
                jira: try await Self.status("jira", socketPath: socketPath)
            )
        }

        private static func testProcessPath() -> String {
            var buffer = [CChar](repeating: 0, count: 4_096)
            _ = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
            return String(cString: buffer)
        }

        /// One `status` call over the broker's socket, off the main thread as
        /// the relay makes it.
        private static func status(_ tool: String, socketPath: String) async throws -> String {
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": tool, "arguments": ["operation": "status"]]
            ]
            let line = try JSONSerialization.data(withJSONObject: request)
            let reply: Data = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: exchange(line, socketPath: socketPath))
                }
            }
            let object = try #require(
                JSONSerialization.jsonObject(with: reply) as? [String: Any],
                "The broker closed the connection without a reply"
            )
            let result = try #require(object["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            return try #require(content.first?["text"] as? String)
        }

        /// The reply line, or empty when the broker did not answer.
        private nonisolated static func exchange(_ line: Data, socketPath: String) -> Data {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return Data() }
            defer { Darwin.close(descriptor) }
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: socketPath.utf8.prefix(destination.count - 1))
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let message = line + Data([0x0A])
            guard connected == 0,
                  message.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == message.count else {
                return Data()
            }
            var reply = Data()
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while !reply.contains(0x0A) {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { return Data() }
                reply.append(contentsOf: chunk.prefix(count))
            }
            return reply.prefix { $0 != 0x0A }
        }
    }
}
