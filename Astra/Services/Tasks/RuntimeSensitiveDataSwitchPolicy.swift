import Foundation
import ASTRACore

/// When a runtime switch needs the user to acknowledge a PHI risk first.
///
/// Approval is the user's own per-runtime label (Settings > Runtime). The
/// risk worth interrupting for is a conversation that started on an approved
/// runtime moving to one that is not: whatever sensitive data the thread
/// already holds follows the next message there. Every runtime starts not
/// approved, so asking on every switch between two unapproved runtimes would
/// nag everyone who never set the label, and tell them nothing new.
enum RuntimeSensitiveDataSwitchPolicy {
    static func requiresAcknowledgement(
        from previous: AgentRuntimeID,
        to next: AgentRuntimeID,
        hasConversation: Bool,
        isApproved: (AgentRuntimeID) -> Bool
    ) -> Bool {
        guard hasConversation, previous != next else { return false }
        return isApproved(previous) && !isApproved(next)
    }

    static func alertTitle(to next: AgentRuntimeID) -> String {
        "Switch to \(next.displayName)?"
    }

    static func alertMessage(from previous: AgentRuntimeID, to next: AgentRuntimeID) -> String {
        "\(next.displayName) is not approved for PHI or sensitive data. This conversation is running on "
            + "\(previous.displayName), which is. Your next message, and the task context ASTRA sends "
            + "with it, will go to \(next.displayName)."
    }

    static let confirmTitle = "Switch Anyway"

    static func cancelTitle(keeping previous: AgentRuntimeID) -> String {
        "Keep \(previous.displayName)"
    }

    static func timelineText(_ payload: RuntimeSensitiveDataRiskAcknowledgement) -> String {
        // The thread snapshot builds off the main actor, so no registry lookup.
        let previous = AgentRuntimeID(rawValue: payload.previousRuntimeID)?.displayName ?? payload.previousRuntimeID
        let next = AgentRuntimeID(rawValue: payload.runtimeID)?.displayName ?? payload.runtimeID
        return "Switched from \(previous) to \(next), which is not approved for PHI or sensitive data. Risk acknowledged."
    }
}

/// Durable record that the user accepted the risk, stored as the payload of
/// `TaskEventTypes.System.sensitiveDataRiskAcknowledged`. Raw runtime ids, so
/// it still decodes if a runtime is later removed.
struct RuntimeSensitiveDataRiskAcknowledgement: Codable, Equatable, Sendable {
    var version = 1
    var previousRuntimeID: String
    var runtimeID: String
    var model: String

    static func decode(from payload: String) -> RuntimeSensitiveDataRiskAcknowledgement? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// What a composer needs to guard runtime switches in an existing task. Both
/// closures run only when the user switches, never while the composer
/// renders: its body runs on every keystroke, and `hasConversation` faults
/// the task's runs.
struct RuntimeSensitiveDataSwitchGuard {
    let hasConversation: () -> Bool
    let recordAcknowledgement: (_ previous: AgentRuntimeID, _ next: AgentRuntimeID, _ model: String) -> Void
}

/// A switch held back until the user answers the alert.
struct RuntimeSensitiveDataSwitchRequest: Equatable {
    let previous: AgentRuntimeID
    let next: AgentRuntimeID
    let model: String
}
