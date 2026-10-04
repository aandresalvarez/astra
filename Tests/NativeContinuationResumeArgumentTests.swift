import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// Pins the provider-native resume flag for the runtimes beyond Claude Code and
/// Codex. Both flags were verified against the real CLIs (a follow-up turn
/// recalled a value from the first), so a regression here silently costs a
/// follow-up its history.
@Suite("Native continuation resume arguments")
struct NativeContinuationResumeArgumentTests {
    private static func antigravityPlan(resumeSessionID: String?) -> AntigravityCLICommandPlan {
        AntigravityCLIRuntime.buildCommand(
            executablePath: "/opt/agy",
            prompt: "Follow up",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: [:],
            resumeSessionID: resumeSessionID,
            permissionArguments: [],
            structuredOutputAllowed: false
        )
    }

    private static func copilotPlan(resumeSessionID: String?) -> CopilotCLICommandPlan {
        let capabilities = CopilotCLICapabilities(
            helpText: "--output-format=FORMAT --stream=MODE --no-ask-user"
        )
        return CopilotCLIRuntime.buildCommand(
            executablePath: "/bin/copilot",
            prompt: "Follow up",
            model: "gpt-5",
            workspacePath: "/tmp/ws",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            allowedTools: [],
            timeoutSeconds: 60,
            capabilities: capabilities,
            taskEnvironment: [:],
            copilotHome: "/tmp/copilot-home",
            resumeSessionID: resumeSessionID,
            permissionArguments: []
        )
    }

    @Test("Copilot passes --resume=<id> in its single-token form")
    func copilotResumes() {
        let plan = Self.copilotPlan(resumeSessionID: " session-abc ")
        #expect(plan.arguments.contains("--resume=session-abc"))
        #expect(plan.arguments.contains("--resume") == false)
    }

    @Test("Copilot omits --resume without a session id")
    func copilotFreshTurn() {
        #expect(Self.copilotPlan(resumeSessionID: nil).arguments.contains { $0.hasPrefix("--resume") } == false)
        #expect(Self.copilotPlan(resumeSessionID: "").arguments.contains { $0.hasPrefix("--resume") } == false)
    }

    @Test("Antigravity passes --conversation with the captured conversation id")
    func antigravityResumes() throws {
        let plan = Self.antigravityPlan(resumeSessionID: " conv-1 ")
        let index = try #require(plan.arguments.firstIndex(of: "--conversation"))
        #expect(plan.arguments[index + 1] == "conv-1")
    }

    @Test("Antigravity omits --conversation without a session id")
    func antigravityFreshTurn() {
        #expect(Self.antigravityPlan(resumeSessionID: nil).arguments.contains("--conversation") == false)
        #expect(Self.antigravityPlan(resumeSessionID: " ").arguments.contains("--conversation") == false)
    }

    @Test("Cursor and OpenCode stay off: empty resumed turns, and an unverified flag")
    func runtimesWithoutNativeResumeStayOff() {
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .copilotCLI))
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .antigravityCLI))
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .cursorCLI) == false)
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .openCodeCLI) == false)
    }
}
