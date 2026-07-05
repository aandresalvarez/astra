import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskLaunchResourcePlanContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

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
        #expect(plan.commandPlannedFields["provider_native_credential_read_path_count"] == "0")
        #expect(!plan.needsProviderNativeCredentialReadAccess)
        #expect(!plan.credentialGrants.contains { $0.source == .gitCredential })
    }

    @Test("GitHub metadata routes through host control without native Git credential projection")
    func githubMetadataRoutesThroughHostControlWithoutGitCredentialProjection() throws {
        let workspaceRoot = try makeTempDir("resource-plan-github-metadata")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot.path) }

        let gitCredentialPath = workspaceRoot.appendingPathComponent("host-gitconfig")
        try "[credential]\nhelper = osxkeychain\n".write(to: gitCredentialPath, atomically: true, encoding: .utf8)

        let workspace = Workspace(name: "GitHub Metadata", primaryPath: workspaceRoot.path)
        workspace.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let task = AgentTask(
            title: "Review PR metadata",
            goal: "Use GitHub to inspect pull request metadata and checks",
            workspace: workspace
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: "Use GitHub to list open pull requests and check statuses."
        )
        var gitCredentialProviderWasCalled = false

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "resume",
            prompt: "Review PR metadata",
            contextText: "Use GitHub to list open pull requests and check statuses.",
            workspacePath: workspaceRoot.path,
            capabilityResolutionSnapshot: snapshot,
            gitCredentialContextProvider: { _, _, _, _ in
                gitCredentialProviderWasCalled = true
                return GitCredentialSandboxContext(
                    readablePaths: [gitCredentialPath.path],
                    writablePaths: [],
                    transports: [.https],
                    diagnostics: []
                )
            }
        )

        #expect(!gitCredentialProviderWasCalled)
        #expect(plan.gitCredential == nil)
        #expect(!plan.credentialGrants.contains { $0.source == .gitCredential })
        #expect(plan.controlPlaneResources.contains {
            $0.capability == "github" && $0.placement == "host_capability"
        })
    }

    @Test("Launch resource contract distinguishes file Git credentials from env secrets")
    func launchResourceContractDistinguishesFileGitCredentialFromEnvironmentSecret() throws {
        let plan = makeContractFixturePlan(
            credentialGrants: [
                RuntimeCredentialGrant(
                    label: "git:credential-context:read-only",
                    source: .gitCredential,
                    reason: "Git HTTPS credential helper context is projected for this run.",
                    projectedAsEnvironment: false,
                    projectedAsFile: true
                )
            ]
        )

        let contract = LaunchResourceContract(plan: plan)

        let gitCredential = try #require(contract.resources.first {
            $0.credentialLabel == "git:credential-context:read-only" &&
                $0.deliveryChannel == .file
        })
        #expect(gitCredential.source == .gitCredential)
        #expect(gitCredential.consumer == .providerProcess)
        #expect(gitCredential.sensitivity == .credential)
        #expect(gitCredential.enforcementBoundary == .launchResourceProjection)
        #expect(gitCredential.visibility == .providerReadableFile)
        #expect(gitCredential.redactionAssumption == .fileContentsNotProviderRedacted)
        #expect(contract.providerEnvironmentSecretResources.isEmpty)
        #expect(contract.providerFileCredentialResources == [gitCredential])
    }

    @Test("Launch resource contract represents env secret credential delivery")
    func launchResourceContractRepresentsEnvironmentSecretCredentialDelivery() throws {
        let plan = makeContractFixturePlan(
            environmentGrants: [
                RuntimeEnvironmentGrant(
                    key: "JIRA_API_TOKEN",
                    source: .connector,
                    reason: "Connector credential key is projected when the provider launches.",
                    sensitivity: .credential,
                    valueProjected: true
                )
            ],
            credentialGrants: [
                RuntimeCredentialGrant(
                    label: "Jira:JIRA_API_TOKEN",
                    source: .connector,
                    reason: "Connector declares credential key JIRA_API_TOKEN.",
                    projectedAsEnvironment: true,
                    projectedAsFile: false
                )
            ]
        )

        let contract = LaunchResourceContract(plan: plan)

        let environmentSecret = try #require(contract.providerEnvironmentSecretResources.first {
            $0.environmentKey == "JIRA_API_TOKEN"
        })
        #expect(environmentSecret.source == .connector)
        #expect(environmentSecret.deliveryChannel == .environment)
        #expect(environmentSecret.consumer == .providerProcess)
        #expect(environmentSecret.sensitivity == .credential)
        #expect(environmentSecret.visibility == .providerEnvironmentValue)
        #expect(environmentSecret.redactionAssumption == .providerSecretEnvironmentRedaction)
        #expect(contract.providerFileCredentialResources.isEmpty)
    }

    @Test("Launch resource contract treats connector file credentials as provider-readable")
    func launchResourceContractTreatsConnectorFileCredentialsAsProviderReadable() throws {
        let credentialPath = "/tmp/astra-launch-resource-contract/.config/gcloud"
        let plan = makeContractFixturePlan(
            hostPathGrants: [
                RuntimePathGrant(
                    path: credentialPath,
                    access: .readWrite,
                    source: .connector,
                    reason: "Google Cloud connector uses local gcloud authentication state.",
                    sensitivity: .cloudAuth,
                    lifetime: .run,
                    exists: true
                )
            ]
        )

        let contract = LaunchResourceContract(plan: plan)

        let fileCredential = try #require(contract.providerFileCredentialResources.first {
            $0.path == credentialPath
        })
        #expect(fileCredential.source == .connector)
        #expect(fileCredential.consumer == .providerProcess)
        #expect(fileCredential.sensitivity == .cloudAuth)
        #expect(fileCredential.visibility == .providerReadableFile)
        #expect(fileCredential.redactionAssumption == .fileContentsNotProviderRedacted)
    }

    @Test("Launch resource contract represents host control-plane-only resources")
    func launchResourceContractRepresentsHostControlPlaneOnlyResources() throws {
        let plan = makeContractFixturePlan(
            providerRequirements: [
                RuntimeProviderRequirement(
                    capability: "host_control_plane_capabilities",
                    source: .controlPlane,
                    reason: "Provider stays host-managed while shell commands run elsewhere.",
                    required: true
                )
            ],
            controlPlaneResources: [
                RuntimeControlPlaneResource(
                    capability: "github",
                    source: .controlPlane,
                    placement: "host_capability",
                    readiness: .configured,
                    reason: "GitHub metadata should flow through ASTRA's host capability layer.",
                    failureText: nil,
                    repairAction: "Enable or repair the GitHub capability."
                )
            ]
        )

        let contract = LaunchResourceContract(plan: plan)

        let resource = try #require(contract.resources.first {
            $0.capability == "github" &&
                $0.deliveryChannel == .hostControlPlane
        })
        #expect(resource.consumer == .hostControlPlane)
        #expect(resource.enforcementBoundary == .hostControlPlane)
        #expect(resource.visibility == .hostControlPlaneOnly)
        #expect(resource.redactionAssumption == .astraManagedBoundary)
        #expect(contract.providerVisibleSensitiveResources.isEmpty)
    }

    @Test("Launch resource contract preserves container mount access in identity")
    func launchResourceContractPreservesContainerMountAccessInIdentity() {
        let hostPath = "/tmp/astra-launch-resource-contract/workspace"
        let containerPath = "/workspace"
        let plan = makeContractFixturePlan(
            containerMounts: [
                RuntimeContainerMountGrant(
                    hostPath: hostPath,
                    containerPath: containerPath,
                    access: ExecutionEnvironmentMountAccess.readOnly.rawValue,
                    role: ExecutionEnvironmentMountRole.workspace.rawValue
                ),
                RuntimeContainerMountGrant(
                    hostPath: hostPath,
                    containerPath: containerPath,
                    access: ExecutionEnvironmentMountAccess.readWrite.rawValue,
                    role: ExecutionEnvironmentMountRole.workspace.rawValue
                )
            ]
        )

        let contract = LaunchResourceContract(plan: plan)

        let mounts = contract.resources.filter {
            $0.deliveryChannel == .containerMount &&
                $0.path == hostPath &&
                $0.placement == containerPath
        }
        #expect(mounts.count == 2)
        #expect(Set(mounts.compactMap(\.access)) == Set([TaskLaunchResourceAccess.read, .readWrite]))
    }

    @Test("Launch resource contract derivation leaves the resource plan intact")
    func launchResourceContractDerivationLeavesResourcePlanIntact() {
        let plan = makeContractFixturePlan(
            credentialGrants: [
                RuntimeCredentialGrant(
                    label: "git:credential-context:read-only",
                    source: .gitCredential,
                    reason: "Git HTTPS credential helper context is projected for this run.",
                    projectedAsEnvironment: false,
                    projectedAsFile: true
                )
            ]
        )
        let originalPlan = plan
        let originalFields = plan.commandPlannedFields

        _ = LaunchResourceContract(plan: plan)

        #expect(plan == originalPlan)
        #expect(plan.commandPlannedFields == originalFields)
        #expect(plan.commandPlannedFields["launch_resource_credential_label_count"] == "1")
        #expect(plan.credentialGrants.first?.projectedAsFile == true)
        #expect(plan.credentialGrants.first?.projectedAsEnvironment == false)
    }

    @Test("Resource resolver projects remote workspace SSH resources")
    func resolverProjectsRemoteWorkspaceSSHResources() throws {
        let fm = FileManager.default
        let root = try makeTempDir("resource-plan-remote-ssh")
        defer { try? fm.removeItem(atPath: root.path) }
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sshDir = home.appendingPathComponent(".ssh", isDirectory: true)
        try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)

        let sshConfig = sshDir.appendingPathComponent("config")
        let identityFile = sshDir.appendingPathComponent("google_compute_engine")
        let knownHosts = sshDir.appendingPathComponent("known_hosts")
        try """
        Host deid-jsn-workbench
          HostName deid-as-service-jsn
          User alvaro1_stanford_edu
          ProxyCommand gcloud compute start-iap-tunnel %h %p --listen-on-stdin
        """.write(to: sshConfig, atomically: true, encoding: .utf8)
        try "private-key-placeholder".write(to: identityFile, atomically: true, encoding: .utf8)
        try "deid-jsn-workbench ssh-ed25519 AAAA\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        SSHConnectionManager.save([
            SSHConnection(
                name: "deid-jsn-workbench",
                host: "deid-as-service-jsn",
                user: "alvaro1_stanford_edu",
                keyPath: "~/.ssh/google_compute_engine",
                configAlias: "deid-jsn-workbench"
            )
        ], workspacePath: workspaceRoot.path)

        let workspace = Workspace(name: "JSL", primaryPath: workspaceRoot.path)
        let task = AgentTask(
            title: "Stop remote server via gcloud",
            goal: "use gcloud to stop the remote server",
            workspace: workspace,
            runtime: .claudeCode
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "run",
            prompt: AgentPromptBuilder.buildPrompt(for: task),
            contextText: task.goal,
            workspacePath: workspaceRoot.path,
            homeDirectoryPath: home.path,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace &&
                $0.access == .read &&
                $0.path == sshConfig.standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace &&
                $0.access == .read &&
                $0.path == identityFile.standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace &&
                $0.access == .readWrite &&
                $0.path == knownHosts.standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .remoteWorkspace &&
                $0.access == .write &&
                $0.path == sshDir.standardizedFileURL.path
        })
        #expect(plan.hostProtectedWriteDenyPaths.contains(sshConfig.standardizedFileURL.path))
        #expect(plan.hostProtectedWriteDenyPaths.contains(identityFile.standardizedFileURL.path))
        #expect(!plan.hostProtectedWriteDenyPaths.contains(knownHosts.standardizedFileURL.path))
        #expect(plan.providerRequirements.contains {
            $0.source == .remoteWorkspace && $0.capability == "remote_workspace_ssh"
        })
        #expect(plan.controlPlaneResources.contains {
            $0.capability == "ssh" &&
                $0.placement == "host_capability" &&
                $0.readiness == .configured
        })
        #expect(plan.credentialGrants.contains {
            $0.source == .remoteWorkspace && $0.label == "Remote workspace SSH"
        })
        #expect(plan.commandPlannedFields["remote_workspace_readable_path_count"] == "3")
    }

    @Test("Resource resolver projects host gcloud config for Google Cloud connector")
    func resolverProjectsHostGCloudConfigForGoogleCloudConnector() throws {
        let fm = FileManager.default
        let root = try makeTempDir("resource-plan-gcloud")
        defer { try? fm.removeItem(atPath: root.path) }
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let gcloudConfig = home.appendingPathComponent(".config/gcloud", isDirectory: true)
        let fakeBin = root.appendingPathComponent("usr-local-bin", isDirectory: true)
        let sdkRoot = home.appendingPathComponent("google-cloud-sdk", isDirectory: true)
        let sdkBin = sdkRoot.appendingPathComponent("bin", isDirectory: true)
        let sdkGCloud = sdkBin.appendingPathComponent("gcloud")
        let gcloudShim = fakeBin.appendingPathComponent("gcloud")
        try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: gcloudConfig, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: sdkBin, withIntermediateDirectories: true)
        try "{}".write(
            to: gcloudConfig.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nexec python3 \"$0\"\n".write(to: sdkGCloud, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: gcloudShim.path, withDestinationPath: sdkGCloud.path)

        let container = try makeTaskLaunchResourcePlanContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "JSL", primaryPath: workspaceRoot.path)
        context.insert(workspace)

        let gcloudSkill = Skill(
            name: "GCloud Agent",
            skillDescription: "Inspect Google Cloud projects",
            allowedTools: ["Bash"],
            behaviorInstructions: "Use gcloud for cloud inventory."
        )
        gcloudSkill.isGlobal = true
        context.insert(gcloudSkill)

        let gcloudConnector = Connector(
            name: "Google Cloud",
            serviceType: "gcloud",
            connectorDescription: "Google Cloud API",
            baseURL: "https://cloud.google.com",
            authMethod: "none"
        )
        gcloudConnector.isGlobal = true
        gcloudConnector.skill = gcloudSkill
        gcloudConnector.configKeys = ["GCP_PROJECT", "GCP_REGION"]
        gcloudConnector.configValues = ["som-rit-phi-starr-dev", "us-central1"]
        context.insert(gcloudConnector)
        workspace.enabledGlobalConnectorIDs = [gcloudConnector.id.uuidString]

        let task = AgentTask(
            title: "Stop remote server via gcloud",
            goal: "use gcloud to stop the remote server",
            workspace: workspace,
            runtime: .claudeCode
        )
        context.insert(task)
        try context.save()

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "run",
            prompt: "use gcloud to stop the remote server",
            contextText: task.goal,
            workspacePath: workspaceRoot.path,
            homeDirectoryPath: home.path,
            gcloudExecutablePathProvider: { _ in gcloudShim.path },
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        #expect(plan.providerRequirements.contains {
            $0.source == .connector && $0.capability == "connector:gcloud"
        })
        #expect(plan.controlPlaneResources.contains {
            $0.capability == "google_cloud" &&
                $0.placement == "host_capability" &&
                $0.readiness == .ready
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .connector &&
                $0.sensitivity == .cloudAuth &&
                $0.access == .readWrite &&
                $0.path == gcloudConfig.standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .connector &&
                $0.sensitivity == .normal &&
                $0.access == .read &&
                $0.path == fakeBin.standardizedFileURL.path
        })
        #expect(plan.hostPathGrants.contains {
            $0.source == .connector &&
                $0.sensitivity == .normal &&
                $0.access == .read &&
                $0.path == sdkRoot.standardizedFileURL.path
        })
        #expect(plan.credentialGrants.contains {
            $0.source == .connector && $0.label == "Google Cloud local gcloud config"
        })
        #expect(plan.commandPlannedFields["connector_readable_path_count"] == "4")
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
        #expect(plan.controlPlaneToolPlacement == "host_capabilities")
        #expect(plan.shellRoute == "astra_workspace_mcp")
        #expect(plan.commandPlannedFields["workspace_command_placement"] == "docker")
        #expect(plan.commandPlannedFields["control_plane_tool_placement"] == "host_capabilities")
        #expect(plan.commandPlannedFields["shell_route"] == "astra_workspace_mcp")
        #expect(plan.containerMounts.contains { $0.role == "credential" && $0.containerPath == "/root/.config/gcloud" })
        #expect(plan.environmentGrants.contains { $0.key == "GOOGLE_APPLICATION_CREDENTIALS" && $0.sensitivity == .cloudAuth })
        #expect(plan.environmentGrants.contains { $0.key == "DOCKER_CONFIG" && $0.source == .dockerEnvironment })
        #expect(plan.credentialGrants.contains { $0.label == "GCP Application Default Credentials" && $0.projectedAsFile })
        #expect(plan.providerRequirements.contains { $0.capability == "docker_workspace_executor" })
        #expect(plan.providerRequirements.contains { $0.capability == "host_control_plane_capabilities" })
        #expect(plan.controlPlaneResources.contains {
            $0.capability == "host_control_plane" &&
                $0.placement == "host_capabilities"
        })
        #expect(plan.controlPlaneResources.contains {
            $0.capability == "docker_workspace_shell" &&
                $0.placement == "docker_workspace_mcp" &&
                $0.readiness == .ready
        })
        #expect(plan.diagnostics.contains { $0.code == "mixed_runtime_routing" })
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

    @Test("Resource resolver records Jira as host control-plane resource for Docker task")
    func resolverRecordsJiraHostCapabilityForDockerTask() throws {
        let workspaceRoot = try makeTempDir("resource-plan-jira-docker")
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot.path) }
        let container = try makeTaskLaunchResourcePlanContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Docker", primaryPath: workspaceRoot.path)
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Query and update Jira tickets",
            allowedTools: [],
            behaviorInstructions: "Use Jira for sprint work."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira Cloud",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        jiraConnector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        context.insert(jiraConnector)
        workspace.enabledGlobalConnectorIDs = [jiraConnector.id.uuidString]

        let task = AgentTask(title: "Sprint", goal: "Fetch Jira comments then run dbt in Docker", workspace: workspace)
        context.insert(task)
        try context.save()

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
            ]
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "run",
            prompt: "Fetch Jira context, then run dbt in Docker",
            contextText: "Use Jira ticket details before running dbt.",
            workspacePath: workspaceRoot.path,
            executionEnvironment: environment,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        #expect(plan.workspaceCommandPlacement == "docker")
        #expect(plan.controlPlaneToolPlacement == "host_capabilities")
        #expect(plan.providerRequirements.contains { $0.capability == "connector:jira" })
        let jiraResource = try #require(plan.controlPlaneResources.first { $0.capability == "jira" })
        #expect(jiraResource.placement == "host_capability")
        #expect(jiraResource.readiness == .configured)
        #expect(jiraResource.repairAction?.contains("JIRA_EMAIL") == true)
        #expect(jiraResource.repairAction?.contains("JIRA_API_TOKEN") == true)
        #expect(plan.credentialGrants.contains { $0.label == "Jira:JIRA_EMAIL" })
        #expect(plan.credentialGrants.contains { $0.label == "Jira:JIRA_API_TOKEN" })
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
            controlPlaneToolPlacement: "host",
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
        #expect(plan.controlPlaneToolPlacement == "host_capabilities")
        #expect(plan.shellRoute == "astra_workspace_mcp")
        #expect(plan.commandPlannedFields["workspace_command_placement"] == "docker")
        #expect(plan.commandPlannedFields["control_plane_tool_placement"] == "host_capabilities")
        #expect(plan.commandPlannedFields["shell_route"] == "astra_workspace_mcp")
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeContractFixturePlan(
        hostPathGrants: [RuntimePathGrant] = [],
        containerMounts: [RuntimeContainerMountGrant] = [],
        environmentGrants: [RuntimeEnvironmentGrant] = [],
        credentialGrants: [RuntimeCredentialGrant] = [],
        providerRequirements: [RuntimeProviderRequirement] = [],
        controlPlaneResources: [RuntimeControlPlaneResource] = []
    ) -> TaskLaunchResourcePlan {
        TaskLaunchResourcePlan(
            taskID: UUID(),
            runID: UUID(),
            runtime: AgentRuntimeID.cursorCLI.rawValue,
            phase: "resume",
            workspacePath: "/tmp/astra-launch-resource-contract",
            executionEnvironmentID: ExecutionEnvironmentKind.host.rawValue,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            workspaceCommandPlacement: "host",
            controlPlaneToolPlacement: "host",
            shellRoute: "native_host",
            hostPathGrants: hostPathGrants,
            containerMounts: containerMounts,
            environmentGrants: environmentGrants,
            credentialGrants: credentialGrants,
            providerRequirements: providerRequirements,
            controlPlaneResources: controlPlaneResources
        )
    }
}
