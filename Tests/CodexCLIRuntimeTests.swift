import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Codex CLI Runtime")
struct CodexCLIRuntimeTests {
    @Test("Codex exec command uses JSON output, workspace root, model, and restricted policy")
    func codexExecCommandUsesJSONWorkspaceModelAndRestrictedPolicy() {
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: "/opt/codex",
            prompt: "Summarize the repo",
            model: "gpt-5.2-codex",
            workspacePath: "/tmp/workspace",
            additionalPaths: ["/tmp/workspace", "/tmp/extra", "/tmp/extra"],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: ["ASTRA_TASK_ID": "task-1"],
            providerHomeDirectory: "/tmp/codex-home",
            pathPrefix: ["/tmp/tools"],
            includeAstraToolsPath: true
        )

        #expect(plan.executablePath == "/opt/codex")
        #expect(plan.arguments.starts(with: [
            "exec",
            "--json",
            "--color", "never",
            "--model", "gpt-5.2-codex",
            "--cd", "/tmp/workspace"
        ]))
        #expect(plan.arguments.contains("--add-dir"))
        #expect(plan.arguments.contains("/tmp/extra"))
        #expect(plan.arguments.contains("--sandbox"))
        #expect(plan.arguments.contains("workspace-write"))
        #expect(plan.arguments.contains("--ask-for-approval"))
        #expect(plan.arguments.contains("never"))
        #expect(plan.arguments.contains("--skip-git-repo-check"))
        #expect(plan.arguments.last == "Summarize the repo")
        #expect(plan.environment["CODEX_HOME"] == "/tmp/codex-home")
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["ASTRA_TASK_ID"] == "task-1")
        #expect(plan.parsesJSONLines)
    }

    @Test("Codex autonomous policy grants full access without interactive approvals")
    func codexAutonomousPolicyGrantsFullAccessWithoutInteractiveApprovals() {
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: "/opt/codex",
            prompt: "Implement the plan",
            model: "gpt-5.2-codex",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            timeoutSeconds: 60,
            taskEnvironment: [:]
        )

        #expect(plan.arguments.contains("--sandbox"))
        #expect(plan.arguments.contains("danger-full-access"))
        #expect(plan.arguments.contains("--ask-for-approval"))
        #expect(plan.arguments.contains("never"))
    }

    @Test("Codex policy render records provider sandbox limitations")
    func codexPolicyRenderRecordsProviderSandboxLimitations() {
        let render = CodexPolicyAdapter().render(
            policy: .preset(.review),
            context: PolicyRenderContext(
                runtimeID: .codexCLI,
                model: "gpt-5.2-codex",
                workspacePath: "/tmp/workspace",
                additionalPaths: [],
                requestedAllowedTools: ["Read", "Bash"],
                localToolCommands: [],
                environmentKeyNames: [],
                credentialLabels: [],
                providerFeatures: CodexPolicyAdapter().supportedFeatures
            )
        )

        #expect(render.providerID == AgentRuntimeID.codexCLI)
        #expect(render.generatedConfigPreview.contains("--sandbox workspace-write"))
        #expect(render.generatedConfigPreview.contains("--ask-for-approval never"))
        #expect(render.diagnostics.contains { $0.id == "codex_cli.fine-grained-provider-native-gap" })
        #expect(render.usesBroadProviderPermissions == false)
    }
}
