import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private final class AttachmentPolicyMockProcess: AgentRuntimeProcessControl {
    private(set) var didTerminate = false
    var isRunning: Bool { !didTerminate }
    var terminationStatus: Int32 { didTerminate ? 143 : 0 }

    func terminate() {
        didTerminate = true
    }
}

@Suite("Runtime Attachment Policy Regressions", .serialized)
@MainActor
struct RuntimeAttachmentPolicyRegressionTests {
    @Test("Preflight projects user inputs without exposing provider dependency paths")
    func manifestProjectsOnlyUserSelectedReadPaths() throws {
        let fileManager = FileManager.default
        let workspaceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-workspace-\(UUID().uuidString)", isDirectory: true)
        let attachment = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-literature-\(UUID().uuidString).pdf")
        let providerDependency = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-provider-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: workspaceRoot)
            try? fileManager.removeItem(at: attachment)
            try? fileManager.removeItem(at: providerDependency)
        }
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: attachment)
        try Data("credential".utf8).write(to: providerDependency)

        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Literature", primaryPath: workspaceRoot.path)
        let task = AgentTask(title: "Review literature", goal: "Read the attached PDF", workspace: workspace)
        task.inputs = [attachment.path]
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        var plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: run.id,
            runtime: .claudeCode,
            phase: "test",
            prompt: "Review the attached literature",
            contextText: "Attached files:\n- \(attachment.path)",
            workspacePath: workspaceRoot.path,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
        for source in [TaskLaunchResourceSource.gitCredential, .sandboxApproval] {
            plan.hostPathGrants.append(RuntimePathGrant(
                path: providerDependency.path,
                access: .read,
                source: source,
                reason: "Provider-only dependency fixture.",
                sensitivity: source == .gitCredential ? .credential : .normal,
                lifetime: .run,
                exists: true
            ))
        }

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspaceRoot.path,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            launchResourcePlan: plan,
            modelContext: context
        )
        let guardUnderTest = AgentRuntimePolicyGuard(manifest: manifest)

        #expect(manifest.additionalReadOnlyPaths == [attachment.standardizedFileURL.path])
        #expect(!manifest.additionalPaths.contains { contains(attachment.path, root: $0) })
        #expect(manifest.providerRender.allowedTools.contains("Read"))
        #expect(manifest.providerRender.askFirstTools.contains("Write"))
        #expect(guardUnderTest.violation(for: .toolUse(
            name: "Read", id: "read-pdf", input: ["file_path": attachment.path]
        )) == nil)
        for tool in ["Read", "Grep", "Glob"] {
            #expect(guardUnderTest.violation(for: .toolUse(
                name: tool,
                id: "provider-dependency",
                input: ["pattern": "*", "path": providerDependency.path]
            )) != nil)
        }

        let roundTrip = try JSONDecoder().decode(
            RunPermissionManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(roundTrip.additionalReadOnlyPaths == manifest.additionalReadOnlyPaths)
    }

    @Test("Claude read continues while attachment mutations hard-stop in Ask and Auto")
    func claudeStreamReadContinuesAndMutationsStop() throws {
        let attachment = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-attached-literature-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: attachment) }
        try Data("literature".utf8).write(to: attachment)
        let manifest = makeManifest(
            allowedTools: ["Read"],
            askFirstTools: ["Write", "Edit", "MultiEdit"],
            readOnlyPaths: [attachment.path]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )
        let process = AttachmentPolicyMockProcess()
        let readEvent = try #require(StreamEventParser.parseAll(line: """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Read","id":"read","input":{"file_path":"\(attachment.path)"}}]}}
        """).first)
        let writeEvent = try #require(StreamEventParser.parseAll(line: """
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Write","id":"write","input":{"file_path":"\(attachment.path)","content":"replacement"}}]}}
        """).first)

        #expect(monitor.processEvent(readEvent, process: process) == false)
        #expect(monitor.processEvent(writeEvent, process: process) == true)
        #expect(process.didTerminate)
        #expect(monitor.policyViolation)
        #expect(!monitor.policyApprovalRequired)
        #expect(monitor.policyApprovalMessage == nil)

        let guardUnderTest = AgentRuntimePolicyGuard(manifest: manifest)
        let mutations: [ParsedEvent] = [
            .toolUse(name: "Edit", id: "edit", input: ["file_path": attachment.path]),
            .toolUse(name: "MultiEdit", id: "multi-edit", input: ["file_path": attachment.path]),
            .toolUse(name: "apply_patch", id: "patch", input: [
                "summary": "*** Update File: \(attachment.path)\n"
            ])
        ]
        for event in mutations {
            let violation = try #require(guardUnderTest.violation(for: event))
            #expect(violation.detail == attachment.path)
            #expect(violation.violationCategory == "read_only_input_mutation")
            #expect(!violation.requiresApproval)
            #expect(violation.permissionRequest == nil)
        }

        let broadManifest = makeManifest(
            allowedTools: ["*"],
            readOnlyPaths: [attachment.path],
            permissionMode: .autonomous,
            policyLevel: .autonomous,
            usesBroadProviderPermissions: true
        )
        let broadViolation = try #require(AgentRuntimePolicyGuard(manifest: broadManifest).violation(for: writeEvent))
        #expect(broadViolation.violationCategory == "read_only_input_mutation")
        #expect(!broadViolation.requiresApproval)
    }

    @Test("Seatbelt reads external attachment without permitting mutation")
    func seatbeltKeepsExternalAttachmentReadOnly() throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let base = fileManager.temporaryDirectory.appendingPathComponent("astra-sandbox-input-\(UUID().uuidString)")
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let attachmentRoot = base.appendingPathComponent("attachments", isDirectory: true)
        let attachment = attachmentRoot.appendingPathComponent("literature.pdf")
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentRoot, withIntermediateDirectories: true)
        try Data("literature".utf8).write(to: attachment)
        defer { try? fileManager.removeItem(at: base) }

        let writableRoot = try #require(ExecutionSandbox.canonicalize(workspace.path))
        let readableRoot = try #require(ExecutionSandbox.canonicalize(attachment.path))
        let profile = ExecutionSandbox.makeProfile(
            writableRootCount: 1,
            readableRootCount: 1,
            allowNetwork: true,
            readScope: .enforce
        )
        let read = runConfined(
            profile: profile,
            writableRoots: [writableRoot],
            readableRoots: [readableRoot],
            executable: "/bin/cat",
            arguments: [readableRoot]
        )
        let write = runConfined(
            profile: profile,
            writableRoots: [writableRoot],
            readableRoots: [readableRoot],
            executable: "/bin/sh",
            arguments: ["-c", "printf replacement > '\(readableRoot)'"]
        )

        #expect(read.status == 0)
        #expect(read.stdout == "literature")
        #expect(write.status != 0)
        #expect(try Data(contentsOf: attachment) == Data("literature".utf8))
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeManifest(
        allowedTools: [String],
        askFirstTools: [String] = [],
        readOnlyPaths: [String],
        permissionMode: ProviderPermissionMode = .restricted,
        policyLevel: AgentPolicyLevel = .review,
        usesBroadProviderPermissions: Bool = false
    ) -> RunPermissionManifest {
        let render = ProviderPolicyRender(
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: policyLevel,
            configOwnership: .generated,
            permissionMode: permissionMode,
            allowedTools: allowedTools,
            askFirstTools: askFirstTools,
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: usesBroadProviderPermissions
        )
        return RunPermissionManifest(
            taskID: UUID(),
            runID: UUID(),
            phase: "test",
            providerID: .claudeCode,
            providerVersion: nil,
            model: "test",
            policyLevel: policyLevel,
            policyScope: .taskOverride,
            providerRender: render,
            workspacePath: "/tmp/astra-policy-guard",
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            additionalReadOnlyPaths: readOnlyPaths
        )
    }

    private func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func runConfined(
        profile: String,
        writableRoots: [String],
        readableRoots: [String],
        executable: String,
        arguments: [String]
    ) -> (status: Int32, stdout: String) {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: ExecutionSandbox.sandboxExecPath)
        process.arguments = ExecutionSandbox.makeArguments(
            profile: profile,
            writableRoots: writableRoots,
            readableRoots: readableRoots,
            executablePath: executable,
            arguments: arguments
        )
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Issue.record("Failed to launch sandbox-exec: \(error)")
            return (-1, "")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
