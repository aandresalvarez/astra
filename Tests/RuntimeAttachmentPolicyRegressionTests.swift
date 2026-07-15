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
    @Test("Preflight projects user inputs and approved sandbox retries without exposing git-credential paths")
    func manifestProjectsOnlyUserSelectedReadPaths() throws {
        let fileManager = FileManager.default
        let workspaceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-workspace-\(UUID().uuidString)", isDirectory: true)
        let attachment = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-literature-\(UUID().uuidString).pdf")
        let providerDependency = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-provider-\(UUID().uuidString)")
        let sandboxApprovedPath = fileManager.temporaryDirectory
            .appendingPathComponent("astra-policy-sandbox-approved-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: workspaceRoot)
            try? fileManager.removeItem(at: attachment)
            try? fileManager.removeItem(at: providerDependency)
            try? fileManager.removeItem(at: sandboxApprovedPath)
        }
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: attachment)
        try Data("credential".utf8).write(to: providerDependency)
        try Data("approved".utf8).write(to: sandboxApprovedPath)

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
        // `.gitCredential` stays excluded from the in-app read scope (it only
        // exists to project git config/credential files into the sandbox, not
        // to widen what Read/Grep/Glob may touch). `.sandboxApproval` is a
        // user-approved Seatbelt denial retry (e.g. `Read` on an out-of-scope
        // path) and must widen the read scope, or the retry can never
        // actually succeed - see RuntimeSandboxDenialApproval.
        plan.hostPathGrants.append(RuntimePathGrant(
            path: providerDependency.path,
            access: .read,
            source: .gitCredential,
            reason: "Provider-only dependency fixture.",
            sensitivity: .credential,
            lifetime: .run,
            exists: true
        ))
        plan.hostPathGrants.append(RuntimePathGrant(
            path: sandboxApprovedPath.path,
            access: .read,
            source: .sandboxApproval,
            reason: "User approved this sandbox path for the current run retry.",
            sensitivity: .normal,
            lifetime: .run,
            exists: true
        ))

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

        #expect(Set(manifest.additionalReadOnlyPaths) == Set([
            attachment.standardizedFileURL.path,
            sandboxApprovedPath.standardizedFileURL.path
        ]))
        #expect(!manifest.additionalReadOnlyPaths.contains(providerDependency.standardizedFileURL.path))
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
            #expect(guardUnderTest.violation(for: .toolUse(
                name: tool,
                id: "sandbox-approved-retry",
                input: ["pattern": "*", "path": sandboxApprovedPath.path]
            )) == nil)
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

        // Broad/Auto mode skips normal per-tool validation for every tool
        // except Write/Edit/MultiEdit. A shell command that plainly deletes
        // or overwrites the same read-only attachment must still be caught -
        // provider file tools are stopped above, so a bare `rm`/redirect
        // shouldn't be the silent bypass.
        let broadGuard = AgentRuntimePolicyGuard(manifest: broadManifest)
        let shellRemoveViolation = try #require(broadGuard.violation(for: .toolUse(
            name: "Bash", id: "bash-rm", input: ["command": "rm \(attachment.path)"]
        )))
        #expect(shellRemoveViolation.violationCategory == "read_only_input_mutation")
        #expect(shellRemoveViolation.detail == attachment.path)
        #expect(broadGuard.violation(for: .toolUse(
            name: "Bash", id: "bash-cat", input: ["command": "cat \(attachment.path)"]
        )) == nil)

        // Mutating an unrelated temporary directory in one command segment
        // must not make a later, read-only attachment inspection look like an
        // attachment mutation. This is the command shape used when an agent
        // safely expands an attached archive into a scratch directory.
        let inspectArchive = """
        cd /tmp && rm -rf dcq_inspect && mkdir dcq_inspect && cd dcq_inspect && unzip -q \(attachment.path)
        """
        #expect(broadGuard.violation(for: .toolUse(
            name: "Bash", id: "bash-inspect-archive", input: ["command": inspectArchive]
        )) == nil)
    }

    @Test("Broad shell guard preserves mutation data flow across shell syntax")
    func broadShellGuardPreservesMutationDataFlow() throws {
        let attachment = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-attached;final-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: attachment) }
        try Data("literature".utf8).write(to: attachment)
        let manifest = makeManifest(
            allowedTools: ["*"],
            readOnlyPaths: [attachment.path],
            permissionMode: .autonomous,
            policyLevel: .autonomous,
            usesBroadProviderPermissions: true
        )
        let guardUnderTest = AgentRuntimePolicyGuard(manifest: manifest)
        let mutationCommands = [
            "input='\(attachment.path)' && rm \"$input\"",
            "rm $(printf %s '\(attachment.path)')",
            "rm `printf %s '\(attachment.path)'`",
            "ATTACH='\(attachment.path)' /bin/sh -lc 'rm \"$ATTACH\"'",
            "rm '\(attachment.path)'",
            "printf '%s\\n' '\(attachment.path)' | xargs rm -f",
            "input=$(printf %s '\(attachment.path)') && rm \"$input\"",
            "rm '\(attachment.path)' && /bin/sh -lc 'true'",
            "input='\(attachment.path)' && rm \"${input:?missing}\"",
            "declare input='\(attachment.path)' && rm \"$input\"",
            "typeset input='\(attachment.path)' && rm \"$input\""
        ]

        for (index, command) in mutationCommands.enumerated() {
            let violation = try #require(guardUnderTest.violation(for: .toolUse(
                name: "Bash",
                id: "shell-data-flow-\(index)",
                input: ["command": command]
            )))
            #expect(violation.violationCategory == "read_only_input_mutation")
            #expect(violation.detail == attachment.path)
        }

        #expect(guardUnderTest.violation(for: .toolUse(
            name: "Bash",
            id: "unused-wrapper-assignment",
            input: [
                "command": "ATTACH='\(attachment.path)' /bin/sh -lc 'rm /tmp/unrelated-output'"
            ]
        )) == nil)
        #expect(guardUnderTest.violation(for: .toolUse(
            name: "Bash",
            id: "reverse-pipeline-data-flow",
            input: [
                "command": "rm /tmp/unrelated-output | printf '%s\\n' '\(attachment.path)'"
            ]
        )) == nil)
    }

    @Test("Docker broad shell guard translates container paths before checking read-only inputs")
    func dockerBroadShellGuardTranslatesReadOnlyInputPaths() throws {
        let workspacePath = "/tmp/astra-policy-guard"
        let hostInputPath = "\(workspacePath)/attached.md"
        let manifest = makeManifest(
            allowedTools: ["*"],
            readOnlyPaths: [hostInputPath],
            permissionMode: .autonomous,
            policyLevel: .autonomous,
            usesBroadProviderPermissions: true
        )
        let mapper = ExecutionEnvironmentPathMapper(mounts: [
            ExecutionEnvironmentMount(
                hostPath: workspacePath,
                containerPath: "/workspace",
                access: .readWrite,
                role: .workspace
            )
        ])
        let guardUnderTest = AgentRuntimePolicyGuard(manifest: manifest, pathMapper: mapper)

        let violation = try #require(guardUnderTest.violation(for: .toolUse(
            name: "Bash",
            id: "docker-rm",
            input: ["command": "rm /workspace/attached.md"]
        )))
        #expect(violation.violationCategory == "read_only_input_mutation")
        #expect(violation.detail == hostInputPath)
        #expect(guardUnderTest.violation(for: .toolUse(
            name: "Bash",
            id: "docker-cat",
            input: ["command": "cat /workspace/attached.md"]
        )) == nil)
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
