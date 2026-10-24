import Darwin
import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Automatic recovery process boundary", .serialized)
struct RuntimeRecoveryProcessTests {
    @Test("Recovery signals only the same unreaped suspended child", arguments: [false, true])
    func processOwnership(cancel: Bool) async throws {
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh",
            arguments: ["-c", "kill -STOP $$; printf recovered"], currentDirectory: "/tmp", environment: [:])
        let completion = Task {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(returning: -1) }
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while process.suspendedProcessIdentifier == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(process.suspendedProcessIdentifier)
        #expect(!process.resumeSuspendedProcess(expectedPID: pid + 1))
        if cancel { _ = process.requestGracefulStop() }
        #expect(process.resumeSuspendedProcess(expectedPID: pid) == !cancel)
        if cancel { process.terminate() }
        let status = await completion.value
        #expect(cancel ? status != 0 : status == 0)
        let output = String(decoding: process.stdoutFileHandle.readDataToEndOfFile(), as: UTF8.self)
        #expect(output == (cancel ? "" : "recovered"))
        #expect(process.processIdentifier == pid)
        #expect(process.suspendedProcessIdentifier == nil)
        #expect(!process.resumeSuspendedProcess(expectedPID: pid))
        #expect(!processIsRunning(pid))
    }

    @Test("Every provider uses same-process recovery with exactly one launch", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    @MainActor
    func providerContract(runtime: AgentRuntimeID) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        let reports = AgentLockedBuffer()
        var context = RuntimeSupervisionContext(goal: "Synthetic", runtime: runtime.rawValue, taskFolder: root.path,
            remoteCoverage: "Unknown", investigator: { evidence in
                #expect(evidence.observation.ownedProcessSuspended == true)
                return .init(assessment: .suspectedStalled, explanation: "Synthetic stall", evidenceIDs: ["runtime"])
            }, report: { _ in })
        context.recovery = .init(authorize: { _ in true }, report: { reports.append($0.phase.rawValue + "\n") })
        runner.configureSupervision(context)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: runtime, executablePath: "/bin/sh",
            arguments: ["-c", "echo $$ >> launches; kill -STOP $$; echo recovered"],
            currentDirectory: root.path, environment: [:], browserShimDirectory: nil,
            providerVersion: nil, parsesJSONLines: false)
        let task = AgentTask(title: "Recovery", goal: "Synthetic"); task.runtimeID = runtime.rawValue
        let result = await runner.runRuntimeProcess(adapter: RecoveryFixtureAdapter(plan: plan),
            prompt: "Synthetic", task: task, workspacePath: root.path, executablePath: "/bin/sh",
            homeDirectory: root.path, permissionPolicy: .restricted, timeoutSeconds: 0.1,
            noSemanticProgressTimeoutSeconds: 0.1, maxRunSeconds: 10, onLine: { _, _ in })
        #expect(result.exitCode == 0)
        #expect(!result.stoppedByASTRA)
        #expect(result.supervisionReservedTokens == 16_384)
        #expect(reports.value.contains("resumed"))
        #expect(reports.value.contains("progress"))
        let launches = try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n")
        #expect(launches.count == 1)
        #expect(!processIsRunning(try #require(Int32(launches[0]))))
    }
}

private struct RecoveryFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let plan: AgentRuntimeProcessLaunchPlan
    var id: AgentRuntimeID { plan.runtime }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan { plan }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] { [.text(text: line)] }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
