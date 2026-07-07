import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeLaunchResourcePolicyContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func policyRenderContext(
    runtime: AgentRuntimeID,
    features: ProviderPolicyFeatures,
    environmentKeyNames: [String] = [],
    credentialLabels: [String] = [],
    launchResourceExposure: LaunchResourcePolicyExposure
) -> PolicyRenderContext {
    PolicyRenderContext(
        runtimeID: runtime,
        model: AgentRuntimeAdapterRegistry.defaultModel(for: runtime),
        workspacePath: "/tmp/astra-policy-tests",
        additionalPaths: [],
        requestedAllowedTools: ["Read", "Grep"],
        localToolCommands: [],
        environmentKeyNames: environmentKeyNames,
        credentialLabels: credentialLabels,
        providerFeatures: features,
        launchResourceContractAvailable: launchResourceExposure.launchResourceContractAvailable,
        providerEnvironmentSecretResourceLabels: launchResourceExposure.providerEnvironmentSecretResourceLabels,
        providerFileCredentialResourceLabels: launchResourceExposure.providerFileCredentialResourceLabels,
        providerUnenforcedFileCredentialResourceLabels: launchResourceExposure.providerUnenforcedFileCredentialResourceLabels
    )
}

private func launchResourceContractFixturePlan(
    runtime: AgentRuntimeID = .cursorCLI,
    credentialGrants: [RuntimeCredentialGrant]
) -> TaskLaunchResourcePlan {
    TaskLaunchResourcePlan(
        taskID: UUID(),
        runID: UUID(),
        runtime: runtime.rawValue,
        phase: "resume",
        workspacePath: "/tmp/astra-policy-tests",
        executionEnvironmentID: ExecutionEnvironmentKind.host.rawValue,
        executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
        providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
        workspaceCommandPlacement: "host",
        controlPlaneToolPlacement: "host",
        shellRoute: "native_host",
        credentialGrants: credentialGrants
    )
}

@Suite("Launch resource policy exposure")
struct LaunchResourcePolicyExposureTests {
    @Test("Cursor file-only Git credential contract does not use env-secret diagnostic")
    func cursorFileOnlyGitCredentialContractDoesNotUseEnvSecretDiagnostic() {
        let plan = launchResourceContractFixturePlan(credentialGrants: [
            RuntimeCredentialGrant(
                label: "git:credential-context:read-only",
                source: .gitCredential,
                reason: "Git operation may need host SSH, HTTPS, or cloud credential helpers.",
                projectedAsEnvironment: false,
                projectedAsFile: true
            )
        ])
        let exposure = LaunchResourcePolicyExposure(contract: LaunchResourceContract(plan: plan))
        let adapter = CursorPolicyAdapter()

        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .cursorCLI,
                features: adapter.supportedFeatures,
                credentialLabels: ["git:credential-context:read-only"],
                launchResourceExposure: exposure
            )
        )

        #expect(exposure.providerEnvironmentSecretResourceLabels.isEmpty)
        #expect(exposure.providerFileCredentialResourceLabels.contains("git:credential-context:read-only"))
        #expect(!render.diagnostics.contains { $0.id == "cursor_cli.secret-redaction-unsupported" })
        #expect(!render.diagnostics.contains { $0.severity == .blocked })
    }

    @Test("Cursor env-secret credential contract blocks without provider redaction")
    func cursorEnvironmentSecretCredentialContractBlocksWithoutProviderRedaction() {
        let plan = launchResourceContractFixturePlan(credentialGrants: [
            RuntimeCredentialGrant(
                label: "API_TOKEN",
                source: .provider,
                reason: "Provider process needs an API token.",
                projectedAsEnvironment: true,
                projectedAsFile: false
            )
        ])
        let exposure = LaunchResourcePolicyExposure(contract: LaunchResourceContract(plan: plan))
        let adapter = CursorPolicyAdapter()

        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .cursorCLI,
                features: adapter.supportedFeatures,
                environmentKeyNames: ["API_TOKEN"],
                credentialLabels: ["API_TOKEN"],
                launchResourceExposure: exposure
            )
        )

        #expect(exposure.providerEnvironmentSecretResourceLabels.contains("API_TOKEN"))
        #expect(render.diagnostics.contains {
            $0.severity == .blocked && $0.id == "cursor_cli.secret-redaction-unsupported"
        })
    }

    @Test("Provider-visible credential files without launch-resource enforcement are blocked")
    func providerVisibleCredentialFileWithoutLaunchResourceEnforcementBlocks() {
        let exposure = LaunchResourcePolicyExposure(
            launchResourceContractAvailable: true,
            providerEnvironmentSecretResourceLabels: [],
            providerFileCredentialResourceLabels: ["unscoped-credential-file"],
            providerUnenforcedFileCredentialResourceLabels: ["unscoped-credential-file"]
        )
        let adapter = CursorPolicyAdapter()

        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .cursorCLI,
                features: adapter.supportedFeatures,
                credentialLabels: ["unscoped-credential-file"],
                launchResourceExposure: exposure
            )
        )

        #expect(render.diagnostics.contains {
            $0.severity == .blocked && $0.id == "cursor_cli.credential-file-enforcement-unsupported"
        })
        #expect(!render.diagnostics.contains { $0.id == "cursor_cli.secret-redaction-unsupported" })
    }

    @Test("Credential labels without a launch-resource contract fail closed precisely")
    func credentialLabelsWithoutLaunchResourceContractFailClosedPrecisely() {
        let adapter = CursorPolicyAdapter()

        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .cursorCLI,
                features: adapter.supportedFeatures,
                credentialLabels: ["legacy-credential-label"],
                launchResourceExposure: .absent
            )
        )

        #expect(render.diagnostics.contains {
            $0.severity == .blocked && $0.id == "cursor_cli.credential-contract-unavailable"
        })
        #expect(!render.diagnostics.contains { $0.id == "cursor_cli.secret-redaction-unsupported" })
    }

    @Test("Copilot secret-env support still gates actual env-secret contracts")
    func copilotSecretEnvSupportStillGatesActualEnvSecretContracts() {
        let plan = launchResourceContractFixturePlan(runtime: .copilotCLI, credentialGrants: [
            RuntimeCredentialGrant(
                label: "API_TOKEN",
                source: .provider,
                reason: "Provider process needs an API token.",
                projectedAsEnvironment: true,
                projectedAsFile: false
            )
        ])
        let exposure = LaunchResourcePolicyExposure(contract: LaunchResourceContract(plan: plan))
        let adapter = CopilotPolicyAdapter(capabilities: .conservative)
        let unsupportedRender = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: adapter.supportedFeatures,
                environmentKeyNames: ["API_TOKEN"],
                credentialLabels: ["API_TOKEN"],
                launchResourceExposure: exposure
            )
        )

        #expect(unsupportedRender.diagnostics.contains {
            $0.severity == .blocked && $0.id == "copilot_cli.secret-redaction-unsupported"
        })

        let supportedAdapter = CopilotPolicyAdapter(capabilities: AgentRuntimePolicyCapabilities(
            copilotCLI: CopilotCLICapabilities(helpText: "--secret-env-vars=VAR")
        ))
        let supportedRender = supportedAdapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: supportedAdapter.supportedFeatures,
                environmentKeyNames: ["API_TOKEN"],
                credentialLabels: ["API_TOKEN"],
                launchResourceExposure: exposure
            )
        )

        #expect(!supportedRender.diagnostics.contains {
            $0.id == "copilot_cli.secret-redaction-unsupported"
        })
    }

    @MainActor
    @Test("Cursor preflight uses launch resource contract for file-only Git credentials")
    func cursorPreflightUsesLaunchResourceContractForFileOnlyGitCredentials() throws {
        let container = try makeLaunchResourcePolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Cursor Git Projection", primaryPath: "/tmp/astra-cursor-git-projection")
        let task = AgentTask(title: "Git Projection", goal: "Pull latest from GitHub", workspace: workspace, runtime: .cursorCLI)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let launchResourcePlan = TaskLaunchResourcePlan(
            taskID: task.id,
            runID: run.id,
            runtime: AgentRuntimeID.cursorCLI.rawValue,
            phase: "resume",
            workspacePath: workspace.primaryPath,
            executionEnvironmentID: ExecutionEnvironmentKind.host.rawValue,
            executionEnvironmentKind: ExecutionEnvironmentKind.host.rawValue,
            providerPlacement: ExecutionEnvironmentProviderPlacement.host.rawValue,
            workspaceCommandPlacement: "host",
            controlPlaneToolPlacement: "host",
            shellRoute: "native_host",
            credentialGrants: [
                RuntimeCredentialGrant(
                    label: "git:credential-context:read-only",
                    source: .gitCredential,
                    reason: "Git operation may need host SSH, HTTPS, or cloud credential helpers.",
                    projectedAsEnvironment: false,
                    projectedAsFile: true
                )
            ]
        )

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .cursorCLI,
            model: "composer-2.5-fast",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            contextText: "git pull origin main",
            launchResourcePlan: launchResourcePlan,
            modelContext: context
        )

        #expect(manifest.credentialLabels.contains("git:credential-context:read-only"))
        #expect(!manifest.providerRender.diagnostics.contains {
            $0.id == "cursor_cli.secret-redaction-unsupported"
        })
        #expect(!manifest.providerRender.diagnostics.contains { $0.severity == .blocked })
    }
}
