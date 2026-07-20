import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Runner-level wiring for the execution sandbox: how `AgentRuntimeProcessRunner`
/// turns an `ExecutionSandbox` decision into a launch plan or a fail-closed block,
/// audits each decision, and releases the shared-state gate even when blocked.
///
/// Sandbox settings are injected per-test via isolated `UserDefaults(suiteName:)`
/// instances (never `.standard`), so this suite no longer races other suites that
/// also flip global sandbox keys. Still serialized because tests share the global
/// `AgentRuntimeSharedStateGate` singleton — parallel execution would race that.
@Suite(.serialized)
@MainActor
struct ExecutionSandboxRunnerTests {

    // MARK: - Test doubles

    /// Minimal adapter that yields a controllable launch plan. Every other
    /// protocol requirement is satisfied by the default-impl extension.
    private final class FakeLaunchAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
        let id: AgentRuntimeID
        let descriptor: AgentRuntimeDescriptor
        let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
        let planCurrentDirectory: String
        let planExecutablePath: String
        let planArguments: [String]
        let planCommandPlannedFields: [String: String]
        let sharedKey: AgentRuntimeSharedStateKey?

        init(
            runtime: AgentRuntimeID = .claudeCode,
            currentDirectory: String,
            executablePath: String = "/bin/sh",
            arguments: [String] = ["-c", "true"],
            commandPlannedFields: [String: String] = [:],
            sharedKey: AgentRuntimeSharedStateKey? = nil
        ) {
            self.id = runtime
            self.descriptor = AgentRuntimeDescriptor(
                id: runtime,
                displayName: "Fake",
                executableName: "fake",
                installHint: "",
                authHint: "",
                defaultModels: ["m"],
                supportsAstraRunProtocol: false
            )
            self.planCurrentDirectory = currentDirectory
            self.planExecutablePath = executablePath
            self.planArguments = arguments
            self.planCommandPlannedFields = commandPlannedFields
            self.sharedKey = sharedKey
        }

        func sharedLaunchStateKey(context _: AgentRuntimeProcessLaunchContext) -> AgentRuntimeSharedStateKey? {
            sharedKey
        }

        func makeProcessLaunchPlan(context _: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan {
            AgentRuntimeProcessLaunchPlan(
                runtime: id,
                executablePath: planExecutablePath,
                arguments: planArguments,
                currentDirectory: planCurrentDirectory,
                environment: ["HOME": NSTemporaryDirectory()],
                browserShimDirectory: nil,
                providerVersion: nil,
                parsesJSONLines: false,
                directoriesToCreate: [],
                providerDetectedFields: [:],
                commandPlannedFields: planCommandPlannedFields
            )
        }

        func parseProcessEvents(line _: String, parsesJSONLines _: Bool) -> [ParsedEvent] { [] }
        func blockingProcessPermissionMessage(line _: String, parsesJSONLines _: Bool) -> String? { nil }
    }

    // MARK: - Helpers

    private func makeContext(
        workspacePath: String,
        permissionPolicy: PermissionPolicy = .restricted,
        executionPolicy: AgentRuntimeExecutionPolicy = .default,
        contextText: String = "",
        launchResourcePlan: TaskLaunchResourcePlan? = nil
    ) -> AgentRuntimeProcessLaunchContext {
        AgentRuntimeProcessLaunchContext(
            prompt: "p",
            task: AgentTask(title: "Sbx", goal: "g"),
            workspacePath: workspacePath,
            executablePath: "/bin/sh",
            providerHomeDirectory: "",
            permissionPolicy: permissionPolicy,
            executionPolicy: executionPolicy,
            permissionManifest: nil,
            timeoutSeconds: 1,
            contextText: contextText,
            launchResourcePlan: launchResourcePlan
        )
    }

    /// Builds sandbox settings from an isolated `UserDefaults` suite (never
    /// `.standard`) so concurrently-running suites that also flip global sandbox
    /// keys (`ExecutionSandboxTests`, `AgentUtilityRuntimeTests`) can't race this
    /// one. Pass the yielded provider into `AgentRuntimeProcessRunner(sandboxSettingsProvider:)`.
    @discardableResult
    private func withStandardEnforcement<T>(
        _ value: ExecutionSandboxEnforcement,
        _ body: (@escaping AgentRuntimeProcessRunner.SandboxSettingsProvider) -> T
    ) -> T {
        let suiteName = "astra-sandbox-runner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(value.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        defaults.set(ExecutionSandboxReadScope.audit.rawValue, forKey: AppStorageKeys.sandboxReadScope)
        return body { permissionPolicy in
            ExecutionSandboxSettings.current(permissionPolicy: permissionPolicy, defaults: defaults)
        }
    }

    /// Acquire `key` within `seconds`, returning whether it succeeded. Implemented
    /// via cancellation so a never-released gate can't hang the suite.
    private func acquireWithin(_ key: AgentRuntimeSharedStateKey, seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await AgentRuntimeSharedStateGate.shared.acquire(key); return true }
                catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Decision wiring

    @Test("sandboxedPlan wraps the executable in sandbox-exec when the sandbox applies")
    func sandboxedPlanApplied() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let ws = fm.temporaryDirectory.appendingPathComponent("astra-runner-\(UUID().uuidString)")
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ws) }

        withStandardEnforcement(.bestEffort) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ws.path),
                context: makeContext(workspacePath: ws.path)
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected .plan, got blocked")
                return
            }
            #expect(plan.executablePath == ExecutionSandbox.sandboxExecPath)
            // The original executable is preserved in the wrapped argument tail.
            #expect(plan.arguments.contains("/bin/sh"))
        }
    }

    @Test("sandboxedPlan blocks (fail-closed) under strict when the sandbox can't apply")
    func sandboxedPlanBlockedFailClosed() {
        withStandardEnforcement(.strict) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            // Empty currentDirectory -> no_execution_path -> failClosed under strict.
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ""),
                context: makeContext(workspacePath: "")
            )
            guard case .blocked(let result) = outcome else {
                Issue.record("Expected .blocked under strict")
                return
            }
            #expect(result.exitCode == -1)
            #expect(result.runtimeStopReason == "sandbox_unavailable")
        }
    }

    @Test("sandboxedPlan runs the original plan unchanged when wrapping is skipped")
    func sandboxedPlanSkipped() {
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: "/tmp/whatever"),
                context: makeContext(workspacePath: "/tmp/whatever")
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected .plan when disabled")
                return
            }
            #expect(plan.executablePath == "/bin/sh") // unwrapped original
        }
    }

    @Test("sandboxedPlan projects task-scoped Docker client config before sandboxing")
    func sandboxedPlanProjectsTaskScopedDockerClientConfig() throws {
        let fm = FileManager.default
        let ws = fm.temporaryDirectory.appendingPathComponent("astra-runner-docker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ws) }

        let workspace = Workspace(name: "Docker Workspace", primaryPath: ws.path)
        let task = AgentTask(title: "Docker", goal: "Run commands", workspace: workspace, runtime: .codexCLI)
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:workspace",
            kind: .dockerImage,
            displayName: "Workspace Image",
            image: "astra/workspace:latest"
        ))
        let runID = UUID()
        let context = AgentRuntimeProcessLaunchContext(
            prompt: "run pwd through the workspace shell",
            task: task,
            workspacePath: ws.path,
            executablePath: "/bin/codex",
            providerHomeDirectory: "",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            permissionManifest: nil,
            timeoutSeconds: 1,
            runID: runID
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: ws.path),
                context: context
            )

            guard case .plan(let plan) = outcome else {
                Issue.record("Expected Docker workspace execution to proceed to a launch plan")
                return
            }
            guard let dockerConfigDirectory = DockerWorkspaceMCPProjection.taskScopedDockerConfigDirectory(
                task: task,
                runID: runID
            ) else {
                Issue.record("Expected task-scoped Docker client config directory")
                return
            }
            #expect(plan.sandboxReadablePaths.contains(dockerConfigDirectory))
            #expect(plan.commandPlannedFields["launch_resource_host_readable_count"] != "0")
            #expect(plan.commandPlannedFields["launch_resource_diagnostic_count"] != "0")
            #expect(!plan.sandboxReadablePaths.contains { $0.hasSuffix("/.docker/config.json") })
            #expect(FileManager.default.fileExists(atPath: (dockerConfigDirectory as NSString).appendingPathComponent("config.json")))
        }
    }

    @Test("sandboxedPlan attaches Git credential readable roots before sandboxing")
    func sandboxedPlanAddsGitCredentialContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-git-context-\(UUID().uuidString)")
        let gitConfig = root.appendingPathComponent("gitconfig")
        let knownHosts = root.appendingPathComponent("known-hosts")
        let gitDirectory = root.appendingPathComponent("external-gitdir", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: gitConfig)
        try Data("hosts".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: root) }
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitConfig.path, knownHosts.path],
                    writablePaths: [gitDirectory.path],
                    transports: [.ssh],
                    diagnostics: ["ssh_default_identities"]
                )
            })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: "/tmp/whatever"),
                context: makeContext(workspacePath: "/tmp/whatever")
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected .plan when disabled")
                return
            }
            #expect(plan.sandboxReadablePaths.contains(gitConfig.path))
            #expect(plan.sandboxReadablePaths.contains(knownHosts.path))
            // Git credentials are readable and host write-protected, but they are
            // not read-only *inputs*: they must not create an input-boundary
            // receipt (which would force them into agent-readable container
            // input mounts). Host write protection is retained independently.
            #expect(plan.readOnlyBoundaryReceipt == nil)
            #expect(plan.sandboxProtectedWriteDenyPaths.contains(gitConfig.path))
            #expect(plan.commandPlannedFields["git_credential_context"] == "true")
            #expect(plan.commandPlannedFields["git_credential_readable_path_count"] == "2")
            #expect(plan.commandPlannedFields["git_credential_writable_path_count"] == "1")
            #expect(plan.commandPlannedFields["git_credential_transports"] == "ssh")
        }
    }

    @Test("sandboxedPlan projects explicit attached files as read-only roots")
    func sandboxedPlanAddsAttachmentReadablePaths() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let ws = fm.temporaryDirectory.appendingPathComponent("astra-runner-\(UUID().uuidString)", isDirectory: true)
        let attachmentRoot = ws.appendingPathComponent("inputs", isDirectory: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        try fm.createDirectory(at: attachmentRoot, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: ws)
        }

        let attachment = attachmentRoot.appendingPathComponent("DBT Unit Tests (1).md")
        try "team dbt unit-test notes".write(to: attachment, atomically: true, encoding: .utf8)
        let contextText = """
        Please merge the attached testing document into the guidelines.

        Attached files:
        - \(attachment.path)
        """

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ws.path),
                context: makeContext(workspacePath: ws.path, contextText: contextText)
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected .plan when disabled")
                return
            }

            let expectedAttachmentPath = attachment.standardizedFileURL.path
            #expect(plan.sandboxReadablePaths.contains(expectedAttachmentPath))
            #expect(plan.sandboxProtectedWriteDenyPaths.contains(expectedAttachmentPath))
            #expect(plan.commandPlannedFields["attachment_readable_path_count"] == "1")
            #expect(plan.commandPlannedFields["read_only_input_boundary_required"] == "true")
            #expect(plan.commandPlannedFields["read_only_input_boundary_mode"] == "host_seatbelt")
            #expect(plan.executablePath == ExecutionSandbox.sandboxExecPath)
            let canonicalAttachmentPath = ExecutionSandbox.canonicalize(expectedAttachmentPath)
                ?? expectedAttachmentPath
            #expect(plan.arguments.contains {
                $0.hasPrefix("PROTECTED_WRITE_DENY_ROOT_") && $0.hasSuffix("=\(canonicalAttachmentPath)")
            })
            let canonicalAttachmentDirectory = ExecutionSandbox.canonicalize(attachmentRoot.path)
                ?? attachmentRoot.path
            #expect(plan.arguments.contains {
                $0.hasPrefix("PROTECTED_WRITE_ANCESTOR_DENY_ROOT_")
                    && $0.hasSuffix("=\(canonicalAttachmentDirectory)")
            })
        }
    }

    @Test("read-only inputs fail closed even when the general sandbox is off")
    func readOnlyInputsFailClosedWhenSandboxIsOff() throws {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-required-read-only-input-\(UUID().uuidString)")
        try Data("input".utf8).write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let inputPath = inputURL.path
        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: UUID(),
            runID: UUID(),
            runtime: AgentRuntimeID.claudeCode.rawValue,
            phase: "run",
            workspacePath: "",
            executionEnvironmentID: WorkspaceExecutionEnvironment.host.id,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            hostPathGrants: [RuntimePathGrant(
                path: inputPath,
                access: .read,
                source: .taskInput,
                reason: "Task input selected by the user.",
                sensitivity: .normal,
                lifetime: .run,
                exists: true
            )]
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ""),
                context: makeContext(
                    workspacePath: "",
                    launchResourcePlan: launchResourcePlan
                )
            )
            guard case .blocked(let result) = outcome else {
                Issue.record("Expected the mandatory input boundary to fail closed")
                return
            }
            #expect(result.runtimeStopReason == "read_only_input_boundary_unavailable")
            #expect(result.runtimeStopMessage?.contains("no_execution_path") == true)
            #expect(result.runtimeStopMessage?.contains("never downgraded") == true)
            #expect(result.readOnlyBoundaryEvidence?.status == .unavailable)
            #expect(result.readOnlyBoundaryEvidence?.resourceCount == 1)
            #expect(result.readOnlyBoundaryEvidence?.requiredSurfaces == ["host_seatbelt"])
            #expect(result.readOnlyBoundaryEvidence?.appliedSurfaces.isEmpty == true)
        }
    }

    @Test("sandboxedPlan blocks restricted Codex when external Git credentials need native access")
    func sandboxedPlanBlocksRestrictedCodexExternalGitCredentialAccess() throws {
        let gitConfig = FileManager.default.temporaryDirectory.appendingPathComponent("astra-gitconfig-\(UUID().uuidString)")
        try Data("config".utf8).write(to: gitConfig)
        defer { try? FileManager.default.removeItem(at: gitConfig) }
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitConfig.path],
                    writablePaths: [],
                    transports: [.ssh],
                    diagnostics: []
                )
            })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: makeContext(workspacePath: "/tmp/whatever", permissionPolicy: .restricted)
            )
            guard case .blocked(let result) = outcome else {
                Issue.record("Expected restricted Codex to fail closed when native credential access is unsupported")
                return
            }
            #expect(result.exitCode == -1)
            #expect(result.runtimeStopReason == "credential_native_access_unavailable")
            #expect(result.runtimeStopMessage?.contains("read-only native path grant") == true)
        }
    }

    @Test("sandboxedPlan layers host Codex with a mandatory read-only input boundary")
    func sandboxedPlanLayersHostCodexReadOnlyInputBoundary() throws {
        let inputURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("astra-read-only-input-\(UUID().uuidString)")
        try Data("input".utf8).write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let inputPath = inputURL.path
        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: UUID(),
            runID: UUID(),
            runtime: AgentRuntimeID.codexCLI.rawValue,
            phase: "run",
            workspacePath: "/tmp/whatever",
            executionEnvironmentID: WorkspaceExecutionEnvironment.host.id,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            hostPathGrants: [RuntimePathGrant(
                path: inputPath,
                access: .read,
                source: .taskInput,
                reason: "Task input selected by the user.",
                sensitivity: .normal,
                lifetime: .run,
                exists: true
            )]
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: makeContext(
                    workspacePath: "/tmp/whatever",
                    permissionPolicy: .autonomous,
                    launchResourcePlan: launchResourcePlan
                )
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected Codex to launch inside ASTRA's mandatory input boundary")
                return
            }
            #expect(plan.executablePath == ExecutionSandbox.sandboxExecPath)
            #expect(plan.commandPlannedFields["read_only_input_boundary_mode"] == "host_seatbelt")
            let canonicalInputPath = ExecutionSandbox.canonicalize(inputPath) ?? inputPath
            #expect(plan.arguments.contains {
                $0.hasPrefix("PROTECTED_WRITE_DENY_ROOT_") && $0.hasSuffix("=\(canonicalInputPath)")
            })
            #expect(plan.readOnlyBoundaryReceipt?.protects(inputPath) == true)
            #expect(plan.readOnlyBoundaryReceipt?.surfaces == [.hostSeatbelt])
        }
    }

    @Test("sandboxedPlan blocks restricted host Codex instead of widening an exact file grant")
    func sandboxedPlanBlocksRestrictedCodexExactExternalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-codex-exact-file-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let attachmentDirectory = root.appendingPathComponent("private-inputs", isDirectory: true)
        let attachment = attachmentDirectory.appendingPathComponent("attached.pdf")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try Data("input".utf8).write(to: attachment)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = AgentTask(
            title: "Exact file",
            goal: "Read one attachment",
            workspace: Workspace(name: "Codex", primaryPath: workspace.path),
            runtime: .codexCLI
        )
        task.inputs = [attachment.path]
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let outcome = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider).sandboxedPlan(
                adapter: CodexCLIRuntimeAdapter(),
                context: AgentRuntimeProcessLaunchContext(
                    prompt: "Read the attachment",
                    task: task,
                    workspacePath: workspace.path,
                    executablePath: "/bin/codex-not-present",
                    providerHomeDirectory: "",
                    permissionPolicy: .restricted,
                    executionPolicy: .default,
                    permissionManifest: nil,
                    timeoutSeconds: 1
                )
            )
            guard case .blocked(let result) = outcome else {
                Issue.record("Expected exact-file authority to fail closed for restricted host Codex")
                return
            }
            #expect(result.runtimeStopReason == "provider_native_file_read_unavailable")
            #expect(result.runtimeStopMessage?.contains("expose sibling files") == true)
        }
    }

    @Test("sandboxedPlan resolves fallback resources before building the Codex command")
    func sandboxedPlanResolvesFallbackResourcesBeforeCodexCommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-codex-fallback-resource-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let inputDirectory = root.appendingPathComponent("approved-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = AgentTask(
            title: "Fallback directory",
            goal: "Read the approved directory",
            workspace: Workspace(name: "Codex", primaryPath: workspace.path),
            runtime: .codexCLI
        )
        task.inputs = [inputDirectory.path]
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let outcome = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider).sandboxedPlan(
                adapter: CodexCLIRuntimeAdapter(),
                context: AgentRuntimeProcessLaunchContext(
                    prompt: "Read the directory",
                    task: task,
                    workspacePath: workspace.path,
                    executablePath: "/bin/codex-not-present",
                    providerHomeDirectory: "",
                    permissionPolicy: .restricted,
                    executionPolicy: .default,
                    permissionManifest: nil,
                    timeoutSeconds: 1
                )
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected fallback resource resolution to produce a Codex launch plan")
                return
            }
            let addDirValues = plan.arguments.indices
                .filter { plan.arguments[$0] == "--add-dir" }
                .compactMap { plan.arguments.indices.contains($0 + 1) ? plan.arguments[$0 + 1] : nil }
            #expect(addDirValues.contains(inputDirectory.path))
        }
    }

    @Test("sandboxedPlan issues a verified receipt for a container provider")
    func sandboxedPlanIssuesContainerProviderReceipt() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("astra-container-boundary-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let input = root.appendingPathComponent("attached.pdf")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("input".utf8).write(to: input)
        defer { try? fm.removeItem(at: root) }

        let environment = WorkspaceExecutionEnvironment(
            id: "image:provider",
            kind: .dockerImage,
            displayName: "Provider Image",
            image: "astra/provider:latest",
            runtimeExecutablePath: "/bin/claude",
            providerPlacement: .container
        )
        let task = AgentTask(title: "Container input", goal: "Read the attachment")
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(environment)
        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: task.id,
            runID: UUID(),
            runtime: AgentRuntimeID.claudeCode.rawValue,
            phase: "run",
            workspacePath: workspace.path,
            executionEnvironmentID: environment.id,
            executionEnvironmentKind: environment.kind.rawValue,
            providerPlacement: environment.effectiveProviderPlacement.rawValue,
            hostPathGrants: [RuntimePathGrant(
                path: input.path,
                access: .read,
                source: .userAttachment,
                reason: "File attached by the user in the current message.",
                sensitivity: .normal,
                lifetime: .run,
                exists: true
            )]
        )
        let context = AgentRuntimeProcessLaunchContext(
            prompt: "Read the attachment",
            task: task,
            workspacePath: workspace.path,
            executablePath: "/bin/claude",
            providerHomeDirectory: "",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            permissionManifest: nil,
            timeoutSeconds: 1,
            launchResourcePlan: launchResourcePlan
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(
                sandboxSettingsProvider: sandboxSettingsProvider,
                dockerRuntimeProvider: {
                    DockerRuntimeResolver.resolution(
                        executablePath: "/Applications/Docker.app/Contents/Resources/bin/docker",
                        environment: ["PATH": "/usr/bin:/bin"]
                    )
                }
            )
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(
                    currentDirectory: workspace.path,
                    executablePath: "/bin/claude"
                ),
                context: context
            )

            guard case .plan(let plan) = outcome else {
                Issue.record("Expected the container provider to receive a verified launch plan")
                return
            }
            #expect(plan.executionEnvironment.providerRunsInsideContainer)
            #expect(plan.executablePath == "/Applications/Docker.app/Contents/Resources/bin/docker")
            #expect(plan.arguments.first == "run")
            #expect(plan.environment["PATH"] == "/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin")
            #expect(plan.readOnlyBoundaryReceipt?.surfaces == [.providerContainer])
            #expect(plan.readOnlyBoundaryReceipt?.protects(input.path) == true)
            #expect(plan.readOnlyBoundaryReceipt?.protects("/mnt/astra/input-1") == true)
            #expect(plan.executionEnvironment.mounts.contains {
                $0.hostPath == input.path
                    && $0.containerPath == "/mnt/astra/input-1"
                    && $0.access == .readOnly
            })
        }
    }

    @Test("sandboxedPlan does not block restricted Codex when Git credential context has no paths")
    func sandboxedPlanDoesNotBlockRestrictedCodexWhenGitCredentialContextHasNoPaths() {
        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: UUID(),
            runID: UUID(),
            runtime: AgentRuntimeID.codexCLI.rawValue,
            phase: "run",
            workspacePath: "/tmp/whatever",
            executionEnvironmentID: WorkspaceExecutionEnvironment.host.id,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            gitCredential: RuntimeGitCredentialResource(
                readablePaths: [],
                writablePaths: [],
                transports: [GitCredentialContextResolver.RemoteTransport.ssh.rawValue],
                diagnostics: []
            )
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in .empty })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: makeContext(
                    workspacePath: "/tmp/whatever",
                    permissionPolicy: .restricted,
                    launchResourcePlan: launchResourcePlan
                )
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected pathless Git credential context to avoid a native path-access block")
                return
            }
            #expect(plan.commandPlannedFields["provider_native_credential_read_path_count"] == "0")
            #expect(plan.commandPlannedFields["git_provider_native_read_access"] == nil)
        }
    }

    @Test("sandboxedPlan does not block restricted Codex for local Git config reads")
    func sandboxedPlanDoesNotBlockRestrictedCodexLocalGitConfigReads() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("astra-home-\(UUID().uuidString)")
        let gitConfig = home.appendingPathComponent(".gitconfig")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: gitConfig)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: UUID(),
            runID: UUID(),
            runtime: AgentRuntimeID.codexCLI.rawValue,
            phase: "run",
            workspacePath: "/tmp/whatever",
            executionEnvironmentID: WorkspaceExecutionEnvironment.host.id,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            hostPathGrants: [
                RuntimePathGrant(
                    path: gitConfig.path,
                    access: .read,
                    source: .gitCredential,
                    reason: "Local Git inspection requires external Git config.",
                    sensitivity: .credential,
                    lifetime: .run,
                    exists: true
                )
            ],
            gitCredential: RuntimeGitCredentialResource(
                readablePaths: [gitConfig.path],
                writablePaths: [],
                transports: [],
                diagnostics: ["local_git_config"]
            )
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in .empty })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: makeContext(
                    workspacePath: "/tmp/whatever",
                    permissionPolicy: .restricted,
                    launchResourcePlan: launchResourcePlan
                )
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected local Git config reads to avoid a native credential-access block")
                return
            }
            #expect(plan.sandboxReadablePaths.contains(gitConfig.path))
            // Git config is a credential, not a read-only input: it is readable
            // and host write-protected, but never enters the input-boundary
            // receipt (which would force it into agent-readable container mounts).
            #expect(plan.readOnlyBoundaryReceipt == nil)
            #expect(plan.sandboxProtectedWriteDenyPaths.contains(gitConfig.path))
            #expect(plan.commandPlannedFields["provider_native_credential_read_path_count"] == "0")
            #expect(plan.commandPlannedFields["git_credential_transports"] == "")
        }
    }

    @Test("sandboxedPlan blocks restricted Codex when SSH resource grants need native access")
    func sandboxedPlanBlocksRestrictedCodexSSHResourceCredentialAccess() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("astra-ssh-home-\(UUID().uuidString)")
        let sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        let sshConfig = sshDirectory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        try Data("Host test".utf8).write(to: sshConfig)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: UUID(),
            runID: UUID(),
            runtime: AgentRuntimeID.codexCLI.rawValue,
            phase: "run",
            workspacePath: "/tmp/whatever",
            executionEnvironmentID: WorkspaceExecutionEnvironment.host.id,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            hostPathGrants: [
                RuntimePathGrant(
                    path: sshConfig.path,
                    access: .read,
                    source: .remoteWorkspace,
                    reason: "Configured remote workspace SSH aliases require the user's SSH config.",
                    sensitivity: .credential,
                    lifetime: .run,
                    exists: true
                )
            ],
            credentialGrants: [
                RuntimeCredentialGrant(
                    label: "Remote workspace SSH",
                    source: .remoteWorkspace,
                    reason: "Remote workspace commands use SSH config, identity files, and known-host metadata.",
                    projectedAsEnvironment: false,
                    projectedAsFile: true
                )
            ],
            gitCredential: nil
        )

        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in .empty })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: makeContext(
                    workspacePath: "/tmp/whatever",
                    permissionPolicy: .restricted,
                    launchResourcePlan: launchResourcePlan
                )
            )
            guard case .blocked(let result) = outcome else {
                Issue.record("Expected restricted Codex to fail closed for SSH credential path grants")
                return
            }
            #expect(result.exitCode == -1)
            #expect(result.runtimeStopReason == "credential_native_access_unavailable")
            #expect(result.runtimeStopMessage?.contains("read-only native path grant") == true)
        }
    }

    @Test("sandboxedPlan leaves autonomous Codex resume prompt unshifted for Git credential context")
    func sandboxedPlanLeavesAutonomousCodexResumePromptUnshiftedForGitCredentialContext() throws {
        let gitConfig = FileManager.default.temporaryDirectory.appendingPathComponent("astra-gitconfig-\(UUID().uuidString)")
        try Data("config".utf8).write(to: gitConfig)
        defer { try? FileManager.default.removeItem(at: gitConfig) }
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitConfig.path],
                    writablePaths: [],
                    transports: [.ssh],
                    diagnostics: []
                )
            })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(
                    runtime: .codexCLI,
                    currentDirectory: "/tmp/whatever",
                    arguments: ["exec", "resume", "--json", "--skip-git-repo-check", "session-id", "git pull origin main"]
                ),
                context: makeContext(workspacePath: "/tmp/whatever", permissionPolicy: .autonomous)
            )
            guard case .plan(let plan) = outcome,
                  let skipIndex = plan.arguments.firstIndex(of: "--skip-git-repo-check") else {
                Issue.record("Expected Codex plan with --skip-git-repo-check")
                return
            }
            #expect(!plan.arguments.contains("sandbox_permissions=[\"disk-full-read-access\"]"))
            #expect(plan.arguments[skipIndex + 1] == "session-id")
            #expect(plan.arguments.last == "git pull origin main")
            #expect(plan.sandboxReadablePaths.contains(gitConfig.path))
        }
    }

    @Test("sandboxedPlan does not append Copilot path access outside render evidence")
    func sandboxedPlanDoesNotAppendCopilotGitCredentialAccessOutsideRenderEvidence() throws {
        let gitConfig = FileManager.default.temporaryDirectory.appendingPathComponent("astra-gitconfig-\(UUID().uuidString)")
        try Data("config".utf8).write(to: gitConfig)
        defer { try? FileManager.default.removeItem(at: gitConfig) }
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitConfig.path],
                    writablePaths: [],
                    transports: [.ssh],
                    diagnostics: []
                )
            })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(
                    runtime: .copilotCLI,
                    currentDirectory: "/tmp/whatever",
                    arguments: ["--prompt", "git pull origin main"],
                    commandPlannedFields: ["supports_allow_all_paths": "true"]
                ),
                context: makeContext(workspacePath: "/tmp/whatever", permissionPolicy: .restricted)
            )
            guard case .plan(let plan) = outcome else {
                Issue.record("Expected .plan when disabled")
                return
            }
            #expect(!plan.arguments.contains("--allow-all-paths"))
            #expect(plan.commandPlannedFields["git_provider_native_read_access"] == nil)
        }
    }

    @Test("sandboxedPlan blocks runtimes without Docker workspace command support")
    func sandboxedPlanBlocksRuntimeWithoutDockerWorkspaceSupport() {
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let task = AgentTask(title: "Docker", goal: "Run commands", runtime: .cursorCLI)
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
                id: "image:workspace",
                kind: .dockerImage,
                displayName: "Workspace Image",
                image: "astra/workspace:latest"
            ))
            let context = AgentRuntimeProcessLaunchContext(
                prompt: "p",
                task: task,
                workspacePath: "/tmp/whatever",
                executablePath: "/bin/cursor-agent",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 1
            )

            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .cursorCLI, currentDirectory: "/tmp/whatever"),
                context: context
            )

            guard case .blocked(let result) = outcome else {
                Issue.record("Expected unsupported runtime to fail closed for Docker workspace execution")
                return
            }
            #expect(result.exitCode == -1)
            #expect(result.runtimeStopReason == "docker_workspace_executor_unsupported_runtime")
            #expect(result.runtimeStopMessage?.contains("cannot yet route workspace shell commands") == true)
        }
    }

    @Test("sandboxedPlan allows Codex Docker workspace command support")
    func sandboxedPlanAllowsCodexDockerWorkspaceSupport() {
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let task = AgentTask(title: "Docker", goal: "Run commands", runtime: .codexCLI)
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
                id: "image:workspace",
                kind: .dockerImage,
                displayName: "Workspace Image",
                image: "astra/workspace:latest"
            ))
            let context = AgentRuntimeProcessLaunchContext(
                prompt: "p",
                task: task,
                workspacePath: "/tmp/whatever",
                executablePath: "/bin/codex",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 1
            )

            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: context
            )

            guard case .plan(let plan) = outcome else {
                Issue.record("Expected Codex Docker workspace execution to proceed to a launch plan")
                return
            }
            #expect(plan.commandPlannedFields["workspace_executor_mode"] == "host_provider_container_workspace")
            #expect(plan.commandPlannedFields["workspace_executor"] == "docker")
        }
    }

    @Test("sandboxedPlan composes Git credential context with Docker workspace execution")
    func sandboxedPlanComposesGitCredentialContextWithDockerWorkspaceExecution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-docker-git-\(UUID().uuidString)")
        let gitConfig = root.appendingPathComponent("gitconfig")
        let gitDirectory = root.appendingPathComponent("external-gitdir", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: gitConfig)
        defer { try? FileManager.default.removeItem(at: root) }
        withStandardEnforcement(.off) { sandboxSettingsProvider in
            let task = AgentTask(title: "Docker Git", goal: "Pull latest changes", runtime: .codexCLI)
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
                id: "image:workspace",
                kind: .dockerImage,
                displayName: "Workspace Image",
                image: "astra/workspace:latest"
            ))
            let context = AgentRuntimeProcessLaunchContext(
                prompt: "git pull origin main",
                task: task,
                workspacePath: "/tmp/whatever",
                executablePath: "/bin/codex",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 1
            )

            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider, gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitConfig.path],
                    writablePaths: [gitDirectory.path],
                    transports: [.ssh],
                    diagnostics: []
                )
            })
            let outcome = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(runtime: .codexCLI, currentDirectory: "/tmp/whatever"),
                context: context
            )

            guard case .plan(let plan) = outcome else {
                Issue.record("Expected Git credential preflight and Docker workspace execution to share one plan")
                return
            }
            #expect(plan.commandPlannedFields["git_credential_context"] == "true")
            #expect(plan.commandPlannedFields["git_provider_native_read_access"] == nil)
            #expect(plan.commandPlannedFields["workspace_executor_mode"] == "host_provider_container_workspace")
            #expect(plan.commandPlannedFields["workspace_executor"] == "docker")
            #expect(plan.sandboxReadablePaths.contains(gitConfig.path))
            #expect(plan.executionEnvironment.workspaceCommandsRunInsideContainer)
            #expect(plan.pathMapper?.containerPath(forHostPath: "/tmp/whatever") == "/workspace")
            // Git credentials compose with Docker workspace execution WITHOUT
            // being flattened into the read-only input contract. With no task
            // inputs present the input boundary is not required, and the
            // credential is never bind-mounted at an agent-readable
            // /mnt/astra/input-N path inside the workspace container. Host write
            // protection is still retained through the deny paths.
            #expect(plan.readOnlyBoundaryReceipt == nil)
            #expect(plan.sandboxProtectedWriteDenyPaths.contains(gitConfig.path))
            #expect(plan.executionEnvironment.mounts.allSatisfy { mount in
                !mount.containerPath.hasPrefix("/mnt/astra/input-")
            })
        }
    }

    @Test("Git credential plan helpers preserve Docker execution metadata")
    func gitCredentialPlanHelpersPreserveDockerExecutionMetadata() {
        let environment = WorkspaceExecutionEnvironment(
            id: "image:workspace",
            kind: .dockerImage,
            displayName: "Workspace Image",
            image: "astra/workspace:latest"
        )
        let mapper = ExecutionEnvironmentPathMapper(mounts: [
            ExecutionEnvironmentMount(
                hostPath: "/tmp/whatever",
                containerPath: "/workspace",
                access: .readWrite,
                role: .workspace
            )
        ])
        let base = AgentRuntimeProcessLaunchPlan(
            runtime: .codexCLI,
            executablePath: "/bin/codex",
            arguments: ["exec", "git pull origin main"],
            currentDirectory: "/tmp/whatever",
            environment: [:],
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: false,
            commandPlannedFields: [:],
            pathMapper: mapper,
            executionEnvironment: environment
        )
        let context = GitCredentialSandboxContext(
            readablePaths: ["/tmp/astra-gitconfig"],
            writablePaths: ["/tmp/astra-external-gitdir"],
            transports: [.ssh],
            diagnostics: []
        )

        let plan = base.addingGitCredentialContext(context)

        #expect(plan.executionEnvironment.id == "image:workspace")
        #expect(plan.pathMapper?.containerPath(forHostPath: "/tmp/whatever") == "/workspace")
        #expect(plan.commandPlannedFields["git_credential_context"] == "true")
    }

    @Test("sandboxedPlan keeps execution sandbox independent from Auto override")
    func sandboxedPlanKeepsSandboxIndependentFromPermissionOverride() {
        withStandardEnforcement(.bestEffort) { sandboxSettingsProvider in
            let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)

            // Base policy .restricted + best-effort + an unsatisfiable plan (empty
            // currentDirectory) -> fall back and run unconfined.
            let base = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ""),
                context: makeContext(workspacePath: "", permissionPolicy: .restricted)
            )
            guard case .plan = base else {
                Issue.record("Without the override, best-effort should fall back to .plan")
                return
            }

            // Auto changes provider prompt handling, not the explicit sandbox
            // setting. The same best-effort failure therefore still falls back.
            let overridePolicy = AgentRuntimeExecutionPolicy(
                permissionPolicyOverride: .autonomous,
                allowedToolsOverride: nil,
                permissionGrantsOverride: nil
            )
            let overridden = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ""),
                context: makeContext(workspacePath: "", permissionPolicy: .restricted, executionPolicy: overridePolicy)
            )
            guard case .plan = overridden else {
                Issue.record("Auto must not silently change best-effort sandbox enforcement")
                return
            }
        }
    }

    // MARK: - Auditing

    @Test("Each sandbox decision emits its matching audit event, isolated by task id")
    func auditEmissionsPerDecision() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        let ws = fm.temporaryDirectory.appendingPathComponent("astra-runner-\(UUID().uuidString)")
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ws) }

        func messagesForDecision(
            enforcement: ExecutionSandboxEnforcement,
            currentDirectory: String
        ) -> [String] {
            var messages: [String] = []
            withStandardEnforcement(enforcement) { sandboxSettingsProvider in
                let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: sandboxSettingsProvider)
                let context = makeContext(workspacePath: currentDirectory)
                let taskID = context.task.id
                _ = runner.sandboxedPlan(
                    adapter: FakeLaunchAdapter(currentDirectory: currentDirectory),
                    context: context
                )
                messages = AppLogger.entries.filter { $0.taskID == taskID }.map { $0.message }
            }
            return messages
        }

        let appliedMessages = messagesForDecision(enforcement: .bestEffort, currentDirectory: ws.path)
        #expect(appliedMessages.contains { $0.hasPrefix("sandbox.applied") })
        #expect(appliedMessages.contains { $0.contains("read_scope=audit") })
        #expect(appliedMessages.contains { $0.contains("read_scope_audit=true") })
        #expect(messagesForDecision(enforcement: .off, currentDirectory: ws.path)
            .contains { $0.hasPrefix("sandbox.skipped") })
        #expect(messagesForDecision(enforcement: .bestEffort, currentDirectory: "")
            .contains { $0.hasPrefix("sandbox.fallback") })
        #expect(messagesForDecision(enforcement: .strict, currentDirectory: "")
            .contains { $0.hasPrefix("sandbox.failed") })
    }

    // MARK: - Shared-state gate

    @Test("A strict run blocked by the sandbox still releases the shared-state gate")
    func releasesSharedStateGateOnBlocked() async {
        let key = AgentRuntimeSharedStateKey(runtime: .claudeCode, identifier: "sbx-gate-\(UUID().uuidString)")

        let suiteName = "astra-sandbox-runner-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ExecutionSandboxEnforcement.strict.rawValue, forKey: AppStorageKeys.sandboxEnforcement)

        let runner = AgentRuntimeProcessRunner(sandboxSettingsProvider: { permissionPolicy in
            ExecutionSandboxSettings.current(permissionPolicy: permissionPolicy, defaults: defaults)
        })
        let adapter = FakeLaunchAdapter(currentDirectory: "", sharedKey: key)
        let result = await runner.runRuntimeProcess(
            adapter: adapter,
            prompt: "p",
            task: AgentTask(title: "Sbx", goal: "g"),
            workspacePath: "",
            executablePath: "/bin/sh",
            homeDirectory: "",
            permissionPolicy: .restricted,
            timeoutSeconds: 1,
            onLine: { _, _ in }
        )

        // The run is blocked fail-closed...
        #expect(result.exitCode == -1)
        #expect(result.runtimeStopReason == "sandbox_unavailable")

        // ...and the gate it acquired must have been released, so a fresh acquire
        // succeeds promptly rather than hanging on a leaked hold.
        let acquired = await acquireWithin(key, seconds: 2)
        #expect(acquired)
        if acquired { await AgentRuntimeSharedStateGate.shared.release(key) }
    }
}
