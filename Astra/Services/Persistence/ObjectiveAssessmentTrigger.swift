import Foundation
import CryptoKit

/// Deterministic, pure-function gate for whether a Tier 2 (model-backed) objective
/// re-assessment should fire. This intentionally takes only primitives -- no
/// TaskContextState or AgentTask dependency -- so it can be evaluated cheaply and
/// tested in isolation. It never calls a model itself; callers are responsible for
/// running the actual Tier 2 assessment asynchronously if this returns true.
enum ObjectiveAssessmentTrigger {
    /// Returns true only when every deterministic gate agrees a Tier 2 assessment
    /// is warranted:
    ///   1. Enough turns have elapsed (`turnCount >= turnThreshold`).
    ///   2. A substantive later user message exists (signal the conversation has
    ///      moved beyond simple acknowledgements).
    ///   3. No explicit objective marker was already found (the deterministic
    ///      resolver in TaskActiveObjectiveResolver.swift already handles that
    ///      case; Tier 2 is only for the ambiguous remainder).
    ///   4. The input has changed since the last assessment, OR no assessment has
    ///      ever run, OR the last assessment is stale (debounce window elapsed).
    static func shouldAssess(
        turnCount: Int,
        hasSubstantiveLaterUserMessage: Bool,
        hasExplicitObjectiveMarker: Bool,
        currentInputHash: String,
        lastInputHash: String?,
        lastAssessedAtTurn: Int?,
        currentTurn: Int,
        turnThreshold: Int = 6,
        staleAfterTurns: Int = 8
    ) -> Bool {
        guard turnCount >= turnThreshold else { return false }
        guard hasSubstantiveLaterUserMessage else { return false }
        guard !hasExplicitObjectiveMarker else { return false }

        let inputChanged = currentInputHash != lastInputHash
        let neverAssessed = lastAssessedAtTurn == nil
        let isStale = lastAssessedAtTurn.map { currentTurn - $0 >= staleAfterTurns } ?? false

        return inputChanged || neverAssessed || isStale
    }

    /// Produces a stable, deterministic hash of the inputs that matter for
    /// deciding whether the objective assessment's conclusion could have changed.
    /// Must never incorporate Date()/random/UUID -- identical inputs must always
    /// yield an identical hash, across process runs.
    static func objectiveInputHash(
        originalGoal: String,
        recentUserMessages: [String],
        verificationStatus: String
    ) -> String {
        let normalizedGoal = originalGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessages = recentUserMessages.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalizedStatus = verificationStatus.trimmingCharacters(in: .whitespacesAndNewlines)

        let joined = ([normalizedGoal] + normalizedMessages + [normalizedStatus])
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
