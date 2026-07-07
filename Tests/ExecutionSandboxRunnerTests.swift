import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Runner-level wiring for the execution sandbox: how `AgentRuntimeProcessRunner`
/// turns an `ExecutionSandbox` decision into a launch plan or a fail-closed block,
/// audits each decision, and releases the shared-state gate even when blocked.
///
/// Serialized because the runner reads `ExecutionSandboxSettings.current(...)`
/// from `UserDefaults.standard` (which these tests mutate) and shares the global
/// `AgentRuntimeSharedStateGate` — parallel execution would race both.
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

    private func withStandardEnforcement(_ value: ExecutionSandboxEnforcement, _ body: () -> Void) {
        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let readScopeKey = AppStorageKeys.sandboxReadScope
        let originalEnforcement = UserDefaults.standard.string(forKey: enforcementKey)
        let originalReadScope = UserDefaults.standard.string(forKey: readScopeKey)
        UserDefaults.standard.set(value.rawValue, forKey: enforcementKey)
        UserDefaults.standard.set(ExecutionSandboxReadScope.audit.rawValue, forKey: readScopeKey)
        defer {
            if let originalEnforcement { UserDefaults.standard.set(originalEnforcement, forKey: enforcementKey) }
            else { UserDefaults.standard.removeObject(forKey: enforcementKey) }
            if let originalReadScope { UserDefaults.standard.set(originalReadScope, forKey: readScopeKey) }
            else { UserDefaults.standard.removeObject(forKey: readScopeKey) }
        }
        body()
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

        withStandardEnforcement(.bestEffort) {
            let runner = AgentRuntimeProcessRunner()
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
        withStandardEnforcement(.strict) {
            let runner = AgentRuntimeProcessRunner()
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
        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner()
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

        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner()
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
    func sandboxedPlanAddsGitCredentialContext() {
        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: ["/tmp/astra-gitconfig", "/tmp/astra-known-hosts"],
                    writablePaths: ["/tmp/astra-external-gitdir"],
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
            #expect(plan.sandboxReadablePaths.contains("/tmp/astra-gitconfig"))
            #expect(plan.sandboxReadablePaths.contains("/tmp/astra-known-hosts"))
            #expect(plan.commandPlannedFields["git_credential_context"] == "true")
            #expect(plan.commandPlannedFields["git_credential_readable_path_count"] == "2")
            #expect(plan.commandPlannedFields["git_credential_writable_path_count"] == "1")
            #expect(plan.commandPlannedFields["git_credential_transports"] == "ssh")
        }
    }

    @Test("sandboxedPlan projects explicit attached files as read-only roots")
    func sandboxedPlanAddsAttachmentReadablePaths() throws {
        let fm = FileManager.default
        let ws = fm.temporaryDirectory.appendingPathComponent("astra-runner-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ws) }

        let attachment = ws.appendingPathComponent("DBT Unit Tests (1).md")
        try "team dbt unit-test notes".write(to: attachment, atomically: true, encoding: .utf8)
        let contextText = """
        Please merge the attached testing document into the guidelines.

        Attached files:
        - \(attachment.path)
        """

        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner()
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
            #expect(plan.commandPlannedFields["attachment_readable_path_count"] == "1")
        }
    }

    @Test("sandboxedPlan blocks restricted Codex when external Git credentials need native access")
    func sandboxedPlanBlocksRestrictedCodexExternalGitCredentialAccess() {
        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: ["/tmp/astra-gitconfig"],
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

        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in .empty })
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
    func sandboxedPlanDoesNotBlockRestrictedCodexLocalGitConfigReads() {
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
                    path: "/tmp/astra-home/.gitconfig",
                    access: .read,
                    source: .gitCredential,
                    reason: "Local Git inspection requires external Git config.",
                    sensitivity: .credential,
                    lifetime: .run,
                    exists: true
                )
            ],
            gitCredential: RuntimeGitCredentialResource(
                readablePaths: ["/tmp/astra-home/.gitconfig"],
                writablePaths: [],
                transports: [],
                diagnostics: ["local_git_config"]
            )
        )

        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in .empty })
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
            #expect(plan.sandboxReadablePaths.contains("/tmp/astra-home/.gitconfig"))
            #expect(plan.commandPlannedFields["provider_native_credential_read_path_count"] == "0")
            #expect(plan.commandPlannedFields["git_credential_transports"] == "")
        }
    }

    @Test("sandboxedPlan blocks restricted Codex when SSH resource grants need native access")
    func sandboxedPlanBlocksRestrictedCodexSSHResourceCredentialAccess() {
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
                    path: "/tmp/astra-home/.ssh/config",
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

        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in .empty })
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
    func sandboxedPlanLeavesAutonomousCodexResumePromptUnshiftedForGitCredentialContext() {
        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: ["/tmp/astra-gitconfig"],
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
            #expect(plan.sandboxReadablePaths.contains("/tmp/astra-gitconfig"))
        }
    }

    @Test("sandboxedPlan does not append Copilot path access outside render evidence")
    func sandboxedPlanDoesNotAppendCopilotGitCredentialAccessOutsideRenderEvidence() {
        withStandardEnforcement(.off) {
            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: ["/tmp/astra-gitconfig"],
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
        withStandardEnforcement(.off) {
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

            let runner = AgentRuntimeProcessRunner()
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
        withStandardEnforcement(.off) {
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

            let runner = AgentRuntimeProcessRunner()
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
    func sandboxedPlanComposesGitCredentialContextWithDockerWorkspaceExecution() {
        withStandardEnforcement(.off) {
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

            let runner = AgentRuntimeProcessRunner(gitCredentialContextProvider: { _ in
                GitCredentialSandboxContext(
                    readablePaths: ["/tmp/astra-gitconfig"],
                    writablePaths: ["/tmp/astra-external-gitdir"],
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
            #expect(plan.sandboxReadablePaths.contains("/tmp/astra-gitconfig"))
            #expect(plan.executionEnvironment.workspaceCommandsRunInsideContainer)
            #expect(plan.pathMapper?.containerPath(forHostPath: "/tmp/whatever") == "/workspace")
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

    @Test("sandboxedPlan honors the execution-policy permissionPolicy override (autonomous escalates to strict)")
    func sandboxedPlanHonorsPermissionPolicyOverride() {
        withStandardEnforcement(.bestEffort) {
            let runner = AgentRuntimeProcessRunner()

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

            // Same run, but an execution-policy override escalates to autonomous ->
            // best-effort becomes strict -> the unsatisfiable plan is blocked.
            // (If the runner ignored the override, this would also be .plan.)
            let overridePolicy = AgentRuntimeExecutionPolicy(
                permissionPolicyOverride: .autonomous,
                allowedToolsOverride: nil,
                permissionGrantsOverride: nil
            )
            let escalated = runner.sandboxedPlan(
                adapter: FakeLaunchAdapter(currentDirectory: ""),
                context: makeContext(workspacePath: "", permissionPolicy: .restricted, executionPolicy: overridePolicy)
            )
            guard case .blocked(let result) = escalated else {
                Issue.record("The autonomous override should escalate best-effort to strict -> .blocked")
                return
            }
            #expect(result.runtimeStopReason == "sandbox_unavailable")
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

        let runner = AgentRuntimeProcessRunner()

        func messagesForDecision(
            enforcement: ExecutionSandboxEnforcement,
            currentDirectory: String
        ) -> [String] {
            var messages: [String] = []
            withStandardEnforcement(enforcement) {
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

        let enforcementKey = AppStorageKeys.sandboxEnforcement
        let original = UserDefaults.standard.string(forKey: enforcementKey)
        UserDefaults.standard.set(ExecutionSandboxEnforcement.strict.rawValue, forKey: enforcementKey)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: enforcementKey) }
            else { UserDefaults.standard.removeObject(forKey: enforcementKey) }
        }

        let runner = AgentRuntimeProcessRunner()
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
