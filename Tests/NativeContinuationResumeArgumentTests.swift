import Foundation
import Testing
@testable import ASTRA
import ASTRACore

/// Pins the provider-native resume flag for every runtime beyond Claude Code and
/// Codex. Each flag was verified against the real CLI (a follow-up turn
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

    private static func cursorPlan(resumeSessionID: String?) -> CursorCLICommandPlan {
        CursorCLIRuntime.buildCommand(
            executablePath: "/opt/cursor-agent",
            prompt: "Follow up",
            model: "composer-2.5-fast",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: [:],
            resumeSessionID: resumeSessionID,
            permissionArguments: ProviderPolicyRender.cursorLaunchPermissionArguments(policy: .restricted)
        )
    }

    private static func openCodePlan(resumeSessionID: String?) -> OpenCodeCLICommandPlan {
        OpenCodeCLIRuntime.buildCommand(
            executablePath: "/opt/opencode",
            prompt: "Follow up",
            model: "opencode/big-pickle",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            timeoutSeconds: 60,
            taskEnvironment: [:],
            resumeSessionID: resumeSessionID,
            permissionArguments: ProviderPolicyRender.openCodeLaunchPermissionArguments(policy: .autonomous)
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

    @Test("Cursor passes --resume with the chat id, ahead of the positional prompt")
    func cursorResumes() throws {
        let plan = Self.cursorPlan(resumeSessionID: " chat-123 ")
        let index = try #require(plan.arguments.firstIndex(of: "--resume"))
        #expect(plan.arguments[index + 1] == "chat-123")
        #expect(plan.arguments.last == "Follow up")
        #expect(index + 2 == plan.arguments.count - 1)
    }

    @Test("Cursor omits --resume without a session id")
    func cursorFreshTurn() {
        #expect(Self.cursorPlan(resumeSessionID: nil).arguments.contains("--resume") == false)
        #expect(Self.cursorPlan(resumeSessionID: "  ").arguments.contains("--resume") == false)
    }

    @Test("OpenCode passes --session with the session id, ahead of the prompt")
    func openCodeResumes() throws {
        let plan = Self.openCodePlan(resumeSessionID: " ses_abc ")
        let index = try #require(plan.arguments.firstIndex(of: "--session"))
        #expect(plan.arguments[index + 1] == "ses_abc")
        #expect(plan.arguments.last == "Follow up")
    }

    @Test("OpenCode omits --session without a session id")
    func openCodeFreshTurn() {
        #expect(Self.openCodePlan(resumeSessionID: nil).arguments.contains("--session") == false)
        #expect(Self.openCodePlan(resumeSessionID: "").arguments.contains("--session") == false)
    }

    @Test("OpenCode's real stream names its session on step_start, which is what a resume needs")
    func openCodeStepStartNamesTheSession() {
        // Captured from OpenCode 1.18.30 `run --format json`; there is no `session` event.
        let line = #"{"type":"step_start","timestamp":1791091725824,"sessionID":"ses_efa9d660affe38MdVd4L0soudQ","part":{"id":"prt_1","messageID":"msg_1","sessionID":"ses_efa9d660affe38MdVd4L0soudQ","type":"step-start"}}"#
        let events = OpenCodeCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)
        let sessionIDs = events.compactMap { event -> String? in
            if case .started(let id, _) = event { return id }
            return nil
        }
        #expect(sessionIDs == ["ses_efa9d660affe38MdVd4L0soudQ"])
    }

    @Test("Every built-in runtime resumes natively, and only Cursor re-runs an empty resumed turn")
    func everyRuntimeResumes() {
        for runtime in [AgentRuntimeID.claudeCode, .codexCLI, .copilotCLI, .antigravityCLI, .cursorCLI, .openCodeCLI] {
            let descriptor = AgentRuntimeAdapterRegistry.adapter(for: runtime).descriptor
            #expect(descriptor.supportsNativeContinuation, "\(runtime.rawValue)")
            #expect(descriptor.retriesEmptyResumedTurnWithoutResume == (runtime == .cursorCLI), "\(runtime.rawValue)")
        }
    }
}
