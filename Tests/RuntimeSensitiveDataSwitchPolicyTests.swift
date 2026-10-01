import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime Sensitive Data Switch Policy")
struct RuntimeSensitiveDataSwitchPolicyTests {
    private func requires(
        from previous: AgentRuntimeID,
        to next: AgentRuntimeID,
        hasConversation: Bool = true,
        approved: Set<AgentRuntimeID>
    ) -> Bool {
        RuntimeSensitiveDataSwitchPolicy.requiresAcknowledgement(
            from: previous,
            to: next,
            hasConversation: hasConversation,
            isApproved: { approved.contains($0) }
        )
    }

    @Test("leaving an approved runtime for an unapproved one mid-conversation asks first")
    func approvedToUnapprovedAsks() {
        #expect(requires(from: .claudeCode, to: .codexCLI, approved: [.claudeCode]))
    }

    @Test("no conversation, no approved origin, or an approved target never asks")
    func otherSwitchesDoNotAsk() {
        // A new task has sent nothing anywhere.
        #expect(!requires(from: .claudeCode, to: .codexCLI, hasConversation: false, approved: [.claudeCode]))
        // Everything defaults to unapproved: asking here would nag everyone.
        #expect(!requires(from: .claudeCode, to: .codexCLI, approved: []))
        #expect(!requires(from: .codexCLI, to: .claudeCode, approved: [.claudeCode]))
        #expect(!requires(from: .claudeCode, to: .codexCLI, approved: [.claudeCode, .codexCLI]))
        #expect(!requires(from: .claudeCode, to: .claudeCode, approved: [.claudeCode]))
    }

    @Test("the alert names both runtimes and what happens next")
    func alertCopyNamesBothRuntimes() {
        let message = RuntimeSensitiveDataSwitchPolicy.alertMessage(from: .claudeCode, to: .codexCLI)

        #expect(RuntimeSensitiveDataSwitchPolicy.alertTitle(to: .codexCLI) == "Switch to \(AgentRuntimeID.codexCLI.displayName)?")
        // "Running on", not "started on": the approved runtime may itself have
        // been switched to mid-conversation.
        #expect(message.contains("is running on \(AgentRuntimeID.claudeCode.displayName), which is."))
        #expect(message.contains("not approved for PHI"))
        #expect(RuntimeSensitiveDataSwitchPolicy.cancelTitle(keeping: .claudeCode) == "Keep \(AgentRuntimeID.claudeCode.displayName)")
    }

    @Test("the acknowledgement payload round-trips and reads as a thread line")
    func acknowledgementRoundTrips() throws {
        let payload = RuntimeSensitiveDataRiskAcknowledgement(
            previousRuntimeID: AgentRuntimeID.claudeCode.rawValue,
            runtimeID: AgentRuntimeID.codexCLI.rawValue,
            model: "gpt-6-astra"
        )
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let decoded = try #require(RuntimeSensitiveDataRiskAcknowledgement.decode(from: json))

        #expect(decoded == payload)
        #expect(RuntimeSensitiveDataSwitchPolicy.timelineText(decoded)
            == "Switched from \(AgentRuntimeID.claudeCode.displayName) to \(AgentRuntimeID.codexCLI.displayName), which is not approved for PHI or sensitive data. Risk acknowledged.")
        #expect(TaskEventTypes.System.sensitiveDataRiskAcknowledged.category == .system)
    }

    @Test("an acknowledged switch shows in the conversation, in the user's words")
    @MainActor
    func acknowledgedSwitchShowsInTheThread() {
        let task = AgentTask(title: "PHI switch", goal: "test", runtime: .claudeCode)
        let event = TaskComposerCoordinator.sensitiveDataRiskAcknowledgementEvent(
            task: task,
            previous: .claudeCode,
            next: .codexCLI,
            model: "gpt-6-astra"
        )
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: [event], runs: [])

        #expect(event.type == TaskEventTypes.System.sensitiveDataRiskAcknowledged.rawValue)
        let notices = snapshot.conversationItems.compactMap { item -> String? in
            guard case .systemInfo(let text, _, _) = item else { return nil }
            return text
        }
        #expect(notices == [
            "Switched from \(AgentRuntimeID.claudeCode.displayName) to \(AgentRuntimeID.codexCLI.displayName), which is not approved for PHI or sensitive data. Risk acknowledged."
        ])
    }

    // MARK: - Shared prompt

    @MainActor
    private func guardRecording(into log: SwitchLog, hasConversation: Bool = true) -> RuntimeSensitiveDataSwitchGuard {
        RuntimeSensitiveDataSwitchGuard(
            hasConversation: { hasConversation },
            recordAcknowledgement: { previous, next, model in
                log.entries.append("ack \(previous.rawValue)->\(next.rawValue) \(model)")
            }
        )
    }

    private var claudeToCodex: RuntimeSensitiveDataSwitchRequest {
        RuntimeSensitiveDataSwitchRequest(previous: .claudeCode, next: .codexCLI, model: "gpt-6-astra")
    }

    @Test("a risky switch waits for the alert; confirming records the acknowledgement, then applies")
    @MainActor
    func promptHoldsRiskySwitchUntilConfirmed() {
        let log = SwitchLog()
        let prompt = RuntimeSensitiveDataSwitchPrompt()

        let isWaiting = prompt.request(
            claudeToCodex,
            guard: guardRecording(into: log),
            isApproved: { $0 == .claudeCode }
        ) { log.entries.append("applied") }

        #expect(isWaiting)
        #expect(log.entries.isEmpty)
        #expect(prompt.pending?.request == claudeToCodex)

        prompt.confirm()
        #expect(log.entries == ["ack claude_code->codex_cli gpt-6-astra", "applied"])
        #expect(prompt.pending == nil)
    }

    @Test("cancelling a held switch applies nothing and records nothing")
    @MainActor
    func promptCancelDropsTheSwitch() {
        let log = SwitchLog()
        let prompt = RuntimeSensitiveDataSwitchPrompt()
        prompt.request(claudeToCodex, guard: guardRecording(into: log), isApproved: { $0 == .claudeCode }) {
            log.entries.append("applied")
        }

        prompt.cancel()
        prompt.confirm()
        #expect(log.entries.isEmpty)
    }

    @Test("a safe or unguarded switch applies at once")
    @MainActor
    func promptAppliesSafeSwitchesImmediately() {
        let log = SwitchLog()
        let prompt = RuntimeSensitiveDataSwitchPrompt()

        #expect(!prompt.request(claudeToCodex, guard: nil, isApproved: { $0 == .claudeCode }) {
            log.entries.append("unguarded")
        })
        #expect(!prompt.request(claudeToCodex, guard: guardRecording(into: log), isApproved: { _ in false }) {
            log.entries.append("neither approved")
        })
        #expect(log.entries == ["unguarded", "neither approved"])
        #expect(prompt.pending == nil)
    }

    @Test("every runtime switch on an existing task goes through the shared prompt")
    func everyTaskRuntimeSwitchIsGated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let taskMainView = try String(contentsOf: root.appendingPathComponent("Astra/Views/TaskMainView.swift"), encoding: .utf8)
        let toolbar = try String(contentsOf: root.appendingPathComponent("Astra/Views/Components/ComposerToolbar.swift"), encoding: .utf8)

        // The decision dock's "Switch to …" once bypassed the gate by calling
        // applyRuntimeSwitch directly; it now goes through the prompt.
        #expect(taskMainView.contains("TaskComposerCoordinator.requestDockRuntimeSwitch("))
        #expect(!taskMainView.contains("TaskComposerCoordinator.applyRuntimeSwitch(to: runtime, task: task"))
        #expect(taskMainView.contains(".runtimeSensitiveDataSwitchAlert(sensitiveDataSwitchPrompt)"))
        #expect(toolbar.contains(".runtimeSensitiveDataSwitchAlert(sensitiveDataSwitchPrompt)"))
    }
}

@MainActor
private final class SwitchLog {
    var entries: [String] = []
}
