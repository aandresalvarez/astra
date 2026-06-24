import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@MainActor
struct TaskLaunchResourcePlanTests {
    @Test("Resource resolver records user attachments and Git credential grants")
    func resolverRecordsAttachmentAndGitResources() throws {
        let fm = FileManager.default
        let workspaceRoot = try makeTempDir("resource-plan-workspace")
        defer { try? fm.removeItem(atPath: workspaceRoot.path) }

        let attachment = workspaceRoot.appendingPathComponent("DBT Unit Tests (1).md")
        try "dbt unit test guidance".write(to: attachment, atomically: true, encoding: .utf8)
        let gitReadable = workspaceRoot.appendingPathComponent("gitconfig")
        let gitWritable = workspaceRoot.appendingPathComponent("external-gitdir", isDirectory: true)
        try "config".write(to: gitReadable, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: gitWritable, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Resources", primaryPath: workspaceRoot.path)
        let task = AgentTask(title: "Update guidelines", goal: "Pull latest and use the attached doc", workspace: workspace)
        task.inputs = [attachment.path]

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "resume",
            prompt: "git pull origin main",
            contextText: """
            Use this attached file.

            Attached files:
            - \(attachment.path)
            """,
            workspacePath: workspaceRoot.path,
            gitCredentialContextProvider: { _, _, _, _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitReadable.path],
                    writablePaths: [gitWritable.path],
                    transports: [.ssh],
                    diagnostics: ["ssh_default_identities"]
                )
            }
        )

        #expect(plan.hostReadablePaths.contains(attachment.standardizedFileURL.path))
        #expect(plan.hostReadablePaths.contains(gitReadable.standardizedFileURL.path))
        #expect(plan.hostWritablePaths.contains(gitWritable.standardizedFileURL.path))
        #expect(plan.gitCredentialSandboxContext.transports == [.ssh])
        #expect(plan.commandPlannedFields["attachment_readable_path_count"] == "1")
        #expect(plan.commandPlannedFields["git_credential_transports"] == "ssh")
        #expect(plan.credentialGrants.contains { $0.source == .gitCredential })
    }

    @Test("Resource resolver records local Git config projection without credential grant")
    func resolverRecordsLocalGitConfigProjection() throws {
        let fm = FileManager.default
        let workspaceRoot = try makeTempDir("resource-plan-local-git")
        defer { try? fm.removeItem(atPath: workspaceRoot.path) }

        let gitConfig = workspaceRoot.appendingPathComponent("home.gitconfig")
        try "[diff]\nstatGraphWidth = 80\n".write(to: gitConfig, atomically: true, encoding: .utf8)

        let workspace = Workspace(name: "Local Git", primaryPath: workspaceRoot.path)
        let task = AgentTask(title: "Review local diff", goal: "Verify no unrelated files", workspace: workspace)

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .copilotCLI,
            phase: "run",
            prompt: "git diff --stat",
            contextText: "Before handoff, run git diff --stat.",
            workspacePath: workspaceRoot.path,
            gitCredentialContextProvider: { _, _, _, _ in
                GitCredentialSandboxContext(
                    readablePaths: [gitConfig.path],
                    writablePaths: [],
                    transports: [],
                    diagnostics: ["local_git_config"]
                )
            }
        )

        #expect(plan.hostReadablePaths.contains(gitConfig.standardizedFileURL.path))
        #expect(plan.gitCredentialSandboxContext.transports.isEmpty)
        #expect(plan.commandPlannedFields["git_credential_context"] == "true")
        #expect(plan.commandPlannedFields["git_credential_transports"] == "")
        #expect(!plan.credentialGrants.contains { $0.source == .gitCredential })
    }

    @Test("Resource resolver records Docker credential projection shape without secret values")
    func resolverRecordsDockerCredentialProjection() throws {
        let workspaceRoot = try makeTempDir("resource-plan-docker")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot.path) }

        let workspace = Workspace(name: "Docker", primaryPath: workspaceRoot.path)
        let task = AgentTask(title: "Check dbt", goal: "Run dbt against BigQuery", workspace: workspace)
        let runID = UUID()
        let environment = WorkspaceExecutionEnvironment(
            id: "image:workspace",
            kind: .dockerImage,
            displayName: "Workspace Image",
            image: "astra/workspace:latest",
            mounts: [
                ExecutionEnvironmentMount(
                    hostPath: workspaceRoot.path,
                    containerPath: "/workspace",
                    access: .readWrite,
                    role: .workspace
                )
            ],
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC()
            ]
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: runID,
            runtime: .codexCLI,
            phase: "run",
            prompt: "is dbt installed and working?",
            contextText: "is dbt installed and working?",
            workspacePath: workspaceRoot.path,
            executionEnvironment: environment,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        #expect(plan.executionEnvironmentKind == "docker_image")
        #expect(plan.providerPlacement == "host")
        #expect(plan.workspaceCommandPlacement == "docker")
        #expect(plan.shellRoute == "astra_workspace_mcp")
        #expect(plan.commandPlannedFields["workspace_command_placement"] == "docker")
        #expect(plan.commandPlannedFields["shell_route"] == "astra_workspace_mcp")
        #expect(plan.containerMounts.contains { $0.role == "credential" && $0.containerPath == "/root/.config/gcloud" })
        #expect(plan.environmentGrants.contains { $0.key == "GOOGLE_APPLICATION_CREDENTIALS" && $0.sensitivity == .cloudAuth })
        #expect(plan.environmentGrants.contains { $0.key == "DOCKER_CONFIG" && $0.source == .dockerEnvironment })
        #expect(plan.credentialGrants.contains { $0.label == "GCP Application Default Credentials" && $0.projectedAsFile })
        #expect(plan.providerRequirements.contains { $0.capability == "docker_workspace_executor" })
        let dockerConfigDirectory = try #require(DockerWorkspaceMCPProjection.taskScopedDockerConfigDirectory(
            task: task,
            runID: runID
        ))
        let dockerConfigFile = (dockerConfigDirectory as NSString).appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: dockerConfigFile))
        #expect(plan.hostReadablePaths.contains(dockerConfigDirectory))
        #expect(plan.hostWritablePaths.contains(dockerConfigDirectory))
        #expect(plan.diagnostics.contains { $0.code == "docker_client_config_task_scoped" })
        #expect(!plan.hostReadablePaths.contains { $0.hasSuffix("/.docker/config.json") })
        #expect(!String(describing: plan).contains("application_default_credentials.json\":"))
    }

    @Test("Resource manifest store persists latest and run-scoped manifests")
    func manifestStorePersistsLatestAndRunScopedFiles() throws {
        let workspaceRoot = try makeTempDir("resource-plan-store")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot.path) }

        let workspace = Workspace(name: "Store", primaryPath: workspaceRoot.path)
        let task = AgentTask(title: "Store", goal: "Persist resources", workspace: workspace)
        let runID = UUID()
        let plan = TaskLaunchResourcePlan(
            taskID: task.id,
            runID: runID,
            runtime: AgentRuntimeID.claudeCode.rawValue,
            phase: "run",
            workspacePath: workspaceRoot.path,
            executionEnvironmentID: "host",
            executionEnvironmentKind: "host",
            providerPlacement: "host",
            workspaceCommandPlacement: "host",
            shellRoute: "native_host",
            hostPathGrants: [
                RuntimePathGrant(
                    path: workspaceRoot.path,
                    access: .readWrite,
                    source: .workspace,
                    reason: "Workspace path selected by the user.",
                    sensitivity: .normal,
                    lifetime: .workspace,
                    exists: true
                )
            ]
        )

        let latestPath = try #require(TaskLaunchResourceManifestStore.persist(plan, task: task))
        let runPath = workspaceRoot
            .appendingPathComponent(".astra/tasks/\(String(task.id.uuidString.prefix(8)))/diagnostics/run_resource_manifest_\(String(runID.uuidString.prefix(8))).json")
            .path
        let legacyRootManifestPath = workspaceRoot
            .appendingPathComponent(".astra/tasks/\(String(task.id.uuidString.prefix(8)))/run_resource_manifest.json")
            .path
        try "{}".write(toFile: legacyRootManifestPath, atomically: true, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: latestPath))
        #expect(latestPath.contains("/diagnostics/"))
        #expect(FileManager.default.fileExists(atPath: runPath))
        #expect(TaskLaunchResourceManifestStore.loadLatest(task: task)?.runID == runID)
        #expect(!TaskOutputDiscovery.files(for: task).contains { $0.relativePath == "run_resource_manifest.json" })
        #expect(!TaskOutputDiscovery.files(for: task).contains { $0.relativePath.hasPrefix("diagnostics/") })
    }

    @Test("Resource manifest decodes legacy placement fields")
    func resourceManifestDecodesLegacyPlacementFields() throws {
        let taskID = UUID()
        let runID = UUID()
        let json = """
        {
          "version": 1,
          "taskID": "\(taskID.uuidString)",
          "runID": "\(runID.uuidString)",
          "runtime": "claude_code",
          "phase": "run",
          "workspacePath": "/tmp/workspace",
          "executionEnvironmentID": "image:test",
          "executionEnvironmentKind": "docker_image",
          "providerPlacement": "host",
          "generatedAt": "2026-06-23T00:00:00Z",
          "hostPathGrants": [],
          "containerMounts": [],
          "environmentGrants": [],
          "credentialGrants": [],
          "providerRequirements": [],
          "diagnostics": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = try decoder.decode(TaskLaunchResourcePlan.self, from: json)

        #expect(plan.workspaceCommandPlacement == "docker")
        #expect(plan.shellRoute == "astra_workspace_mcp")
        #expect(plan.commandPlannedFields["workspace_command_placement"] == "docker")
        #expect(plan.commandPlannedFields["shell_route"] == "astra_workspace_mcp")
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
