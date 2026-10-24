import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime supervision process integration", .serialized)
@MainActor
struct RuntimeSupervisionProcessTests {
    @Test("All registered providers share investigation before stopping", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func providerContract(runtime: AgentRuntimeID) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        let reports = AgentLockedBuffer()
        runner.configureSupervision(.init(goal: "Synthetic", runtime: runtime.rawValue, taskFolder: root.path,
            remoteCoverage: "Unknown", investigator: { _ in
                .init(assessment: .suspectedStalled, explanation: "The synthetic worker has stopped advancing.", evidenceIDs: ["runtime"])
            }, report: { reports.append($0.phase.rawValue + "\n") }))
        let plan = AgentRuntimeProcessLaunchPlan(runtime: runtime, executablePath: "/bin/sleep", arguments: ["20"],
            currentDirectory: root.path, environment: ["HOME": root.path], browserShimDirectory: nil,
            providerVersion: nil, parsesJSONLines: false)
        let task = AgentTask(title: "Supervision", goal: "Synthetic")
        task.runtimeID = runtime.rawValue
        let started = ContinuousClock.now
        let result = await runner.runRuntimeProcess(adapter: SupervisionFixtureAdapter(plan: plan),
            prompt: "Synthetic", task: task, workspacePath: root.path, executablePath: "/bin/sleep",
            homeDirectory: root.path, permissionPolicy: .restricted, timeoutSeconds: 0.1,
            noSemanticProgressTimeoutSeconds: 0.1, onLine: { _, _ in })
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(result.runtimeStopReason == "provider_supervisor_stalled")
        #expect(result.supervisionReservedTokens == 16_384)
        #expect(reports.value.contains("checking"))
        #expect(reports.value.contains("stopping"))
    }

    @Test("Both utility streams obey the investigator's output bound", arguments: [false, true])
    func utilityOutputBound(stderr: Bool) async throws {
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: "/bin/sh",
            arguments: ["-c", "head -c 100000 /dev/zero \(stderr ? ">&2" : ""); sleep 20"],
            currentDirectory: "/tmp", environment: ["PATH": "/usr/bin:/bin"], browserShimDirectory: nil,
            providerVersion: nil, parsesJSONLines: false)
        let started = ContinuousClock.now
        let result = await AgentUtilityExecutionLimits.$maximumOutputBytes.withValue(1_024) {
            await runner.runUtilityProcess(.init(process: plan, providerHomeDirectory: "", permissionPolicy: .restricted, timeoutSeconds: 15))
        }
        #expect(started.duration(to: .now) < .seconds(10))
        #expect(result.exitCode != 0)
        #expect(result.error.contains("output exceeded"))
        #expect(result.output.utf8.count <= 1_024)
    }

    @Test("File evidence detects changes without reading file contents or following symlinks")
    func files() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await RuntimeSupervisionFileCollector.capture(root: root.path)
        try "answer".write(to: root.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try "private".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc")
        let after = await RuntimeSupervisionFileCollector.capture(root: root.path)
        #expect(before.unavailable == nil)
        #expect(after.unavailable == nil)
        #expect(after.changes(since: before) == ["report.md"])
    }

    @Test("Git workspace evidence detects edits to already-dirty files and stays inside the workspace")
    func gitWorkspaceFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-git-\(UUID())")
        let folder = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = await ProcessBinaryRunner().run(path: "/usr/bin/git", args: ["init", root.path], timeout: 3, environment: nil)
        #expect(initialized.isSuccess)
        let report = folder.appendingPathComponent("report.md")
        try "before".write(to: report, atomically: true, encoding: .utf8)
        try "outside".write(to: root.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
        let before = await RuntimeSupervisionFileCollector.captureWorkspace(root: folder.path)
        try "after with more bytes".write(to: report, atomically: true, encoding: .utf8)
        let after = await RuntimeSupervisionFileCollector.captureWorkspace(root: folder.path)
        #expect(before.unavailable == nil)
        #expect(after.unavailable == nil)
        #expect(after.changes(since: before) == ["report.md"])
        #expect(after.metadata.count == 1)
        let missing = await RuntimeSupervisionFileCollector.capture(root: root.appendingPathComponent("missing").path)
        #expect(missing.unavailable != nil)
    }

    @Test("Cancellation during evidence collection prevents the provider launch")
    func cancelPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launched")
        let started = AgentLockedBuffer()
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.configureSupervision(.init(goal: "Synthetic", runtime: "claude_code", taskFolder: root.path,
            remoteCoverage: "Unknown", investigator: { _ in .inconclusive("Unused") }, report: { _ in }, collector: {
                started.append("yes")
                do { try await Task.sleep(for: .seconds(20)) } catch {}
                return .init()
            }))
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: "/usr/bin/touch",
            arguments: [marker.path], currentDirectory: root.path, environment: ["HOME": root.path],
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let task = AgentTask(title: "Cancel", goal: "Synthetic")
        let running = Task {
            await runner.runRuntimeProcess(adapter: SupervisionFixtureAdapter(plan: plan), prompt: "Synthetic",
                task: task, workspacePath: root.path, executablePath: "/usr/bin/touch", homeDirectory: root.path,
                permissionPolicy: .restricted, timeoutSeconds: 10, onLine: { _, _ in })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while started.value.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!started.value.isEmpty)
        runner.cancel()
        let result = await running.value
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("The independent utility uses enforced isolation and rejects invalid output", arguments: [true, false])
    func actualInvestigator(valid: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("supervision-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        let response = valid ? #"{"assessment":"waiting","explanation":"Known operation is open","evidenceIDs":["runtime"]}"# : "malformed"
        try """
        #!/bin/sh
        tools_disabled=false
        safe=false
        strict=false
        hooks=false
        turns=false
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --tools) shift; [ "$1" = "" ] && tools_disabled=true ;;
            --safe-mode) safe=true ;;
            --strict-mcp-config) strict=true ;;
            --settings) shift; [ "$1" = '{"disableAllHooks":true}' ] && hooks=true ;;
            --max-turns) shift; [ "$1" = '1' ] && turns=true ;;
          esac
          shift
        done
        if $tools_disabled && $safe && $strict && $hooks && $turns && [ "$CLAUDE_CODE_MAX_OUTPUT_TOKENS" = 2048 ]; then
          printf '%s\\n' '\(response)'
        else
          printf 'Investigator inherited tools or customization'
          exit 1
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let evidence = RuntimeSupervisionEvidence(goal: "Synthetic", runtime: "claude_code",
            observation: .init(progressRevision: 0, quietSeconds: 600, stdoutBytes: 0, stderrBytes: 0,
                unknownFrames: 0, activeTools: ["tool-1"], managedJobs: [], recentOutput: ""),
            changedFiles: [], fileCoverage: "Available", remoteCoverage: "Unknown")
        let assessment = await AgentUtilityExecutionLimits.$supervisionEnvironment.withValue(["HOME": root.path, "PATH": "/usr/bin:/bin"]) {
            await RuntimeSupervisionInvestigator.assess(evidence,
                configuration: .init(runtime: .claudeCode, claudePath: executable.path, timeoutSeconds: 5))
        }
        #expect(assessment.assessment == (valid ? .waiting : .inconclusive))
    }
}

private struct SupervisionFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let plan: AgentRuntimeProcessLaunchPlan
    var id: AgentRuntimeID { plan.runtime }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan { plan }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] { [] }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}
