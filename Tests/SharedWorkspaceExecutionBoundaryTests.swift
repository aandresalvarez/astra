import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Shared workspace execution boundary")
struct SharedWorkspaceExecutionBoundaryTests {
    @Test("Kernel boundary denies workspace writes but permits task output writes")
    func hostKernelBoundary() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let base = fm.temporaryDirectory.appendingPathComponent("astra-shared-sbx-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let taskFolder = workspace.appendingPathComponent(".astra/tasks/test", isDirectory: true)
        try fm.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func wrappedPlan(writing path: String) -> AgentRuntimeProcessLaunchPlan? {
            let plan = AgentRuntimeProcessLaunchPlan(
                runtime: .claudeCode,
                executablePath: "/bin/sh",
                arguments: ["-c", "printf x > '\(path)'"],
                currentDirectory: workspace.path,
                environment: ["HOME": base.appendingPathComponent("provider-home").path],
                browserShimDirectory: nil,
                providerVersion: nil,
                parsesJSONLines: false,
                directoriesToCreate: [taskFolder.path],
                providerDetectedFields: [:],
                commandPlannedFields: [:]
            )
            guard case .applied(let wrapped, let roots) = ExecutionSandbox.decide(
                plan: plan,
                providerHomeDirectory: "",
                additionalWritablePaths: [taskFolder.path],
                workspaceWritable: false,
                settings: ExecutionSandboxSettings(enforcement: .strict)
            ) else { return nil }
            #expect(!roots.contains(ExecutionSandbox.canonicalize(workspace.path) ?? workspace.path))
            return wrapped
        }

        let workspaceFile = workspace.appendingPathComponent("blocked.txt").path
        let outputFile = taskFolder.appendingPathComponent("allowed.txt").path
        let deniedPlan = try #require(wrappedPlan(writing: workspaceFile))
        let allowedPlan = try #require(wrappedPlan(writing: outputFile))

        #expect(run(deniedPlan) != 0)
        #expect(!fm.fileExists(atPath: workspaceFile))
        #expect(run(allowedPlan) == 0)
        #expect(fm.fileExists(atPath: outputFile))
    }

    private func run(_ plan: AgentRuntimeProcessLaunchPlan) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            Issue.record("Failed to launch wrapped plan: \(error)")
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
