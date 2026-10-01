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
}
