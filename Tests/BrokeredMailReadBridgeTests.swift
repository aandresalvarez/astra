import Foundation
import Testing
import ASTRAModels
import HostControlToolSupport
@testable import ASTRA

@MainActor
@Suite("Brokered mail read cancellation")
struct BrokeredMailReadBridgeTests {
    private final class State {
        var started = false
        var cancelled = false
        var completed = false
    }

    @Test("Stopping the broker cancels the actual asynchronous read and rejects later requests")
    func stoppingCancelsInFlightRead() async throws {
        let state = State()
        let bridge = BrokeredMailReadBridge(timeout: 10) { _ in
            if state.cancelled { return Data("{}".utf8) }
            state.started = true
            do {
                try await Task.sleep(for: .seconds(10))
                state.completed = true
                return Data("{}".utf8)
            } catch { state.cancelled = true; throw error }
        }
        let server = HostControlMCPServer(configuration: HostControlToolConfiguration(allowedTools: ["mail"]), mailReader: bridge)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mail","arguments":{"operation":"accounts"}}}"#
        let running = Task.detached { server.handleLine(line) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !state.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.started)
        server.cancelActiveOperations()
        let reply = await running.value
        #expect(reply?.contains("could not read") == true)
        #expect(state.cancelled)
        #expect(!state.completed)
        let request = try #require(MailReadRequest.parse(["operation": "accounts"]))
        // Replacing a socket session cancels pending calls but keeps the
        // same run-bound reader available to the replacement session.
        let retried = try await Task.detached { try bridge.readMail(request) }.value
        #expect(retried == Data("{}".utf8))
        bridge.closeMailAccess()
        let refused = await Task.detached {
            do { _ = try bridge.readMail(request); return false }
            catch BrokeredMailReadBridge.Failure.stopped { return true }
            catch { return false }
        }.value
        #expect(refused)
    }

    @Test("Replacing the actual broker session does not close its shared run-bound mail reader")
    func replacingSessionKeepsReaderAvailable() async throws {
        let env = try PluginOperationsTests.Environment()
        let task = AgentTask(title: "Mail transport", goal: "Read captured mail", workspace: env.workspace)
        env.context.insert(task)
        try env.context.save()
        let runID = UUID()
        let registry = HostControlBrokerSessionRegistry.shared
        let bridge = BrokeredMailReadBridge { _ in Data("{}".utf8) }
        registry.bindMailReader(bridge, taskID: task.id, runID: runID)
        defer {
            registry.stop(taskID: task.id, runID: runID)
            registry.unbindMailReader(taskID: task.id, runID: runID)
        }
        let scope = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: task.goal).providerLaunch
        for _ in 0..<2 {
            #expect(registry.prepare(task: task, runID: runID, runtime: nil, capabilityScope: scope,
                requiredTools: ["history"], currentDirectory: env.root.path, expectedHelperPath: "/usr/bin/true"))
        }
        let reader = try #require(registry.mailReader(taskID: task.id, runID: runID))
        let request = try #require(MailReadRequest.parse(["operation": "accounts"]))
        let result = try await Task.detached { try reader.readMail(request) }.value
        #expect(result == Data("{}".utf8))
    }

    @Test("A transport timeout cancels the read instead of leaving network work running")
    func timeoutCancelsRead() async throws {
        let state = State()
        let bridge = BrokeredMailReadBridge(timeout: 0.05) { _ in
            state.started = true
            do {
                try await Task.sleep(for: .seconds(10))
                state.completed = true
                return Data("{}".utf8)
            } catch { state.cancelled = true; throw error }
        }
        let request = try #require(MailReadRequest.parse(["operation": "accounts"]))
        let timedOut = await Task.detached {
            do { _ = try bridge.readMail(request); return false }
            catch BrokeredMailReadBridge.Failure.timedOut { return true }
            catch { return false }
        }.value
        #expect(timedOut)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !state.cancelled && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        // A saturated actor may not have started the read by the deadline;
        // cancellation before entry is valid too and must never start it later.
        #expect(state.cancelled || !state.started)
        #expect(!state.completed)
    }
}
