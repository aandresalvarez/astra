import Foundation
import Testing
@testable import ASTRA

@Suite("Objective assessment trigger")
struct ObjectiveAssessmentTriggerTests {
    private static func fire(
        turnCount: Int = 6,
        hasSubstantiveLaterUserMessage: Bool = true,
        hasExplicitObjectiveMarker: Bool = false,
        currentInputHash: String = "hash-a",
        lastInputHash: String? = "hash-b",
        lastAssessedAtTurn: Int? = 0,
        currentTurn: Int = 6,
        turnThreshold: Int = 6,
        staleAfterTurns: Int = 8
    ) -> Bool {
        ObjectiveAssessmentTrigger.shouldAssess(
            turnCount: turnCount,
            hasSubstantiveLaterUserMessage: hasSubstantiveLaterUserMessage,
            hasExplicitObjectiveMarker: hasExplicitObjectiveMarker,
            currentInputHash: currentInputHash,
            lastInputHash: lastInputHash,
            lastAssessedAtTurn: lastAssessedAtTurn,
            currentTurn: currentTurn,
            turnThreshold: turnThreshold,
            staleAfterTurns: staleAfterTurns
        )
    }

    // MARK: - Gate 1: turnCount >= turnThreshold

    @Test("fires when the baseline satisfies every gate")
    func baselineFires() {
        #expect(Self.fire())
    }

    @Test("skips when turnCount is below turnThreshold")
    func turnCountBelowThresholdSkips() {
        #expect(!Self.fire(turnCount: 5, turnThreshold: 6))
    }

    @Test("fires when turnCount equals turnThreshold exactly")
    func turnCountAtThresholdFires() {
        #expect(Self.fire(turnCount: 6, turnThreshold: 6))
    }

    @Test("fires when turnCount exceeds turnThreshold")
    func turnCountAboveThresholdFires() {
        #expect(Self.fire(turnCount: 10, turnThreshold: 6))
    }

    // MARK: - Gate 2: hasSubstantiveLaterUserMessage

    @Test("skips when there is no substantive later user message")
    func noSubstantiveMessageSkips() {
        #expect(!Self.fire(hasSubstantiveLaterUserMessage: false))
    }

    @Test("fires when there is a substantive later user message")
    func substantiveMessageFires() {
        #expect(Self.fire(hasSubstantiveLaterUserMessage: true))
    }

    // MARK: - Gate 3: hasExplicitObjectiveMarker

    @Test("skips when an explicit objective marker is already present")
    func explicitMarkerSkips() {
        #expect(!Self.fire(hasExplicitObjectiveMarker: true))
    }

    @Test("fires when no explicit objective marker is present")
    func noExplicitMarkerFires() {
        #expect(Self.fire(hasExplicitObjectiveMarker: false))
    }

    // MARK: - Gate 4: hash changed, never assessed, or stale

    @Test("skips when hash is unchanged, previously assessed, and not stale")
    func unchangedHashRecentlyAssessedSkips() {
        #expect(!Self.fire(
            currentInputHash: "same",
            lastInputHash: "same",
            lastAssessedAtTurn: 5,
            currentTurn: 6,
            staleAfterTurns: 8
        ))
    }

    @Test("fires when the input hash changed even if recently assessed")
    func changedHashFires() {
        #expect(Self.fire(
            currentInputHash: "new",
            lastInputHash: "old",
            lastAssessedAtTurn: 5,
            currentTurn: 6,
            staleAfterTurns: 8
        ))
    }

    @Test("fires when no assessment has ever run, regardless of hash")
    func neverAssessedFires() {
        #expect(Self.fire(
            currentInputHash: "same",
            lastInputHash: "same",
            lastAssessedAtTurn: nil,
            currentTurn: 6
        ))
    }

    @Test("fires once staleAfterTurns have elapsed even with an unchanged hash")
    func staleAssessmentFiresWithUnchangedHash() {
        #expect(Self.fire(
            currentInputHash: "same",
            lastInputHash: "same",
            lastAssessedAtTurn: 0,
            currentTurn: 8,
            staleAfterTurns: 8
        ))
    }

    @Test("skips just before staleAfterTurns have elapsed with an unchanged hash")
    func justBeforeStaleSkipsWithUnchangedHash() {
        #expect(!Self.fire(
            currentInputHash: "same",
            lastInputHash: "same",
            lastAssessedAtTurn: 0,
            currentTurn: 7,
            staleAfterTurns: 8
        ))
    }

    // MARK: - Hash stability & sensitivity

    @Test("hash is stable across repeated calls with identical inputs")
    func hashIsStableAcrossCalls() {
        let first = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Also add a changelog entry", "And update the version"],
            verificationStatus: "in_progress"
        )
        let second = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Also add a changelog entry", "And update the version"],
            verificationStatus: "in_progress"
        )
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("hash changes when recentUserMessages change")
    func hashChangesWithDifferentMessages() {
        let base = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Also add a changelog entry"],
            verificationStatus: "in_progress"
        )
        let changed = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Actually, scrap that and redo the schema"],
            verificationStatus: "in_progress"
        )
        #expect(base != changed)
    }

    @Test("hash changes when verificationStatus changes")
    func hashChangesWithDifferentVerificationStatus() {
        let base = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Also add a changelog entry"],
            verificationStatus: "in_progress"
        )
        let changed = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Also add a changelog entry"],
            verificationStatus: "verified"
        )
        #expect(base != changed)
    }

    @Test("hash changes when originalGoal changes")
    func hashChangesWithDifferentGoal() {
        let base = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the release notes",
            recentUserMessages: ["Also add a changelog entry"],
            verificationStatus: "in_progress"
        )
        let changed = ObjectiveAssessmentTrigger.objectiveInputHash(
            originalGoal: "Ship the onboarding flow",
            recentUserMessages: ["Also add a changelog entry"],
            verificationStatus: "in_progress"
        )
        #expect(base != changed)
    }
}
