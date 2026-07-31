import Foundation

/// Immutable, redacted intent facts captured when a turn is submitted.
///
/// The source `TaskEvent` remains authoritative for the user's full text. This
/// bounded snapshot exists so capability admission never has to reconstruct
/// current intent from mutable task fields or an expanded provider prompt.
public struct TaskTurnIntentSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let taskID: UUID
    public let sourceEventID: UUID?
    public let acceptedTurn: String
    public let inheritedTurn: String?
    public let activeObjective: String?
    public let attachmentPaths: [String]
    public let pinnedSkillIDs: [UUID]
    public let isReferential: Bool

    public init(
        version: Int = TaskTurnIntentSnapshot.currentVersion,
        taskID: UUID,
        sourceEventID: UUID?,
        acceptedTurn: String,
        inheritedTurn: String? = nil,
        activeObjective: String? = nil,
        attachmentPaths: [String] = [],
        pinnedSkillIDs: [UUID] = [],
        isReferential: Bool = false
    ) {
        self.version = version
        self.taskID = taskID
        self.sourceEventID = sourceEventID
        self.acceptedTurn = acceptedTurn
        self.inheritedTurn = inheritedTurn
        self.activeObjective = activeObjective
        self.attachmentPaths = attachmentPaths
        self.pinnedSkillIDs = pinnedSkillIDs
        self.isReferential = isReferential
    }

    /// The only prose used for capability activation.
    ///
    /// A substantive turn stands alone. Referential turns inherit one bounded
    /// prior user turn, never the full transcript or original task fields.
    public var activationText: String {
        if isReferential, let inheritedContext = inheritedTurn ?? activeObjective {
            return [acceptedTurn, inheritedContext]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return acceptedTurn
    }
}
