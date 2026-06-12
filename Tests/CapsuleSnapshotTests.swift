import Foundation
import Testing
@testable import ASTRA

/// Phase 0 of the Context Capsule robustness plan: a deterministic golden-snapshot and
/// render-invariant suite. The golden guards every render branch against accidental
/// change; the invariants guard the documented prompt-assembly contract (determinism,
/// budget conformance, recovery-pointer survival) so Phase 2 selection changes can be
/// reviewed as a snapshot diff instead of by eye.
@Suite("Capsule snapshot")
struct CapsuleSnapshotTests {
    /// A content-rich, fully deterministic capsule that exercises every render section.
    /// Fixed ids/timestamps keep `renderMarkdown` byte-stable across runs.
    static func richState() -> TaskContextState {
        func pointer(_ kind: String, _ id: String, _ summary: String) -> TaskContextState.SourcePointer {
            TaskContextState.SourcePointer(kind: kind, id: id, path: nil, summary: summary)
        }
        func fact(_ text: String, _ id: String) -> TaskContextState.ContextFact {
            TaskContextState.ContextFact(text: text, sourcePointers: [pointer("event", id, "Origin")], confidence: "derived")
        }
        return TaskContextState(
            schemaVersion: 2,
            mode: .execution,
            startingRequest: "Build the CSV export feature",
            currentObjective: "Add a streaming CSV exporter behind a feature flag",
            objective: TaskContextState.Objective(
                startingRequest: "Build the CSV export feature",
                currentObjective: "Add a streaming CSV exporter behind a feature flag",
                approvedGoal: "Ship streaming CSV export",
                sourcePointers: [pointer("task", "task0001", "Task goal")]
            ),
            constraints: [fact("Must not load the whole dataset into memory", "evt00001")],
            acceptanceCriteria: [fact("Exports 1M rows under 5s", "evt00002")],
            testCommand: "swift test --filter Export",
            decisions: ["Approved goal: Ship streaming CSV export"],
            decisionFacts: [fact("Use a chunked writer instead of buffering", "evt00003")],
            rejectedOptions: ["Buffer entire file in memory"],
            openQuestions: ["Should the flag default on for beta?"],
            candidateGoals: ["Streaming CSV export"],
            approvedGoal: "Ship streaming CSV export",
            blockers: ["Blocked step: CSV schema - awaiting product sign-off"],
            blockerFacts: [fact("Awaiting product sign-off on column order", "evt00004")],
            filesChanged: ["Sources/Export/CSVExporter.swift"],
            changedFiles: [TaskContextState.ChangedFile(
                path: "Sources/Export/CSVExporter.swift",
                changeType: "edit",
                sourcePointers: [pointer("file_change", "fc000001", "edit file change")]
            )],
            artifacts: [TaskContextState.ArtifactReference(
                type: "report",
                path: "outputs/export-benchmark.md",
                version: 2,
                isStale: false,
                sourcePointers: [pointer("artifact", "art00001", "Generated artifact")]
            )],
            verification: TaskContextState.Verification(
                status: "passed",
                strategy: "validation_contract",
                command: "swift test --filter Export",
                summary: "All required assertions passed",
                evidence: [pointer("event", "evt00005", "Validation event")],
                updatedAt: "2026-06-05T12:00:00Z",
                completionVerified: true,
                artifactStatus: "1 current",
                deliverableLevel: "syntax_verified",
                deliverableSummary: "Benchmark report generated and checked",
                deliverableChecks: [TaskContextState.Verification.DeliverableCheckSummary(
                    id: "chk1", title: "Report exists", status: "passed", summary: "Found at outputs/export-benchmark.md", path: "outputs/export-benchmark.md"
                )]
            ),
            validationContract: TaskContextState.ValidationContractSummary(
                status: "passed",
                assertionCount: 1,
                requiredPassed: 1,
                requiredTotal: 1,
                assertions: [TaskContextState.ValidationAssertionSummary(
                    id: "a1", scope: "task", stepID: "export", method: "command", required: true,
                    description: "Export benchmark passes", status: "passed", summary: "ran in 4.2s",
                    sourcePointers: [pointer("plan", "plan0001", "Validation contract assertion")]
                )],
                sourcePointers: [pointer("plan", "plan0001", "Validation contract")]
            ),
            latestHandoff: TaskContextState.HandoffSummary(
                runID: "run00001-aaaa-bbbb-cccc-000000000001",
                taskStatus: "completed",
                runStatus: "completed",
                completedWork: ["Implemented chunked writer"],
                unfinishedWork: ["Wire the feature flag default"],
                blockers: [],
                suggestedNextAction: "Enable the flag for beta",
                sourcePointers: [pointer("event", "evt00006", "Structured worker handoff")]
            ),
            correctiveWork: [TaskContextState.CorrectiveWorkSummary(
                correctiveStepID: "cw1", failedAssertionID: "a0", status: "open",
                failureSummary: "Earlier run leaked memory", suggestedRepair: "Flush the buffer per chunk",
                correctiveTaskID: nil, dismissedReason: nil,
                sourcePointers: [pointer("event", "evt00007", "Corrective work open")]
            )],
            sourcePointers: [pointer("task", "task0001", "Task source")],
            nextLikelyAction: "Enable the flag for beta and re-run the benchmark",
            objectiveDivergenceNote: nil,
            standingInstructions: [fact("Keep the exporter dependency-free", "evt00008")],
            turns: [TaskContextState.Turn(
                turn: 1, ask: "Implement the exporter", summary: "Added CSVExporter with a chunked writer",
                filesChanged: ["Sources/Export/CSVExporter.swift"], blockers: [],
                outputFile: "outputs/turn_001.md", runStatus: "completed", completedAt: "2026-06-05T12:00:00Z"
            )],
            updatedAt: "2026-06-05T12:00:00Z"
        )
    }

    /// Frozen render of `richState()`. Any unintended change to a render branch shows up
    /// here as a diff; an intentional change is re-frozen by updating this literal.
    static let goldenMarkdown =
"""
# Current State

- Mode: execution
- Updated: 2026-06-05T12:00:00Z
- Starting request: Build the CSV export feature
- Current objective: Add a streaming CSV exporter behind a feature flag
- Approved goal: Ship streaming CSV export

## Constraints
- Must not load the whole dataset into memory
  - Source: event evt00001 Origin

## Acceptance Criteria
- Exports 1M rows under 5s
  - Source: event evt00002 Origin

## Standing User Instructions
- Keep the exporter dependency-free
  - Source: event evt00008 Origin

## Validation Contract
- Status: passed
- Required passed: 1/1
- Assertion count: 1
- [passed] `a1` required command step `export`: Export benchmark passes
  - Summary: ran in 4.2s
  - Source: plan plan0001 Validation contract assertion

## Test Command
`swift test --filter Export`

## Decisions
- Approved goal: Ship streaming CSV export

## Decision Facts
- Use a chunked writer instead of buffering
  - Source: event evt00003 Origin

## Rejected options
- Buffer entire file in memory

## Open questions
- Should the flag default on for beta?

## Candidate goals
- Streaming CSV export

## Blockers
- Blocked step: CSV schema - awaiting product sign-off

## Blocker Facts
- Awaiting product sign-off on column order
  - Source: event evt00004 Origin

## Files changed
- Sources/Export/CSVExporter.swift

## Changed File Facts
- edit: `Sources/Export/CSVExporter.swift`
  - Source: file_change fc000001 edit file change

## Verification
- Status: passed
- Strategy: validation_contract
- Command: `swift test --filter Export`
- Completion verified: yes
- Artifact status: 1 current
- Deliverable quality: syntax_verified
- Deliverable summary: Benchmark report generated and checked
- Deliverable checks:
  - [passed] Report exists `outputs/export-benchmark.md`: Found at outputs/export-benchmark.md
- Summary: All required assertions passed
- Updated: 2026-06-05T12:00:00Z
  - Source: event evt00005 Validation event

## Artifacts
- report v2: `outputs/export-benchmark.md`
  - Source: artifact art00001 Generated artifact

## Latest Handoff
- Run: run00001-aaaa-bbbb-cccc-000000000001
- Task status: completed
- Run status: completed
- Completed work:
  - Implemented chunked writer
- Unfinished work:
  - Wire the feature flag default
- Next action: Enable the flag for beta
  - Source: event evt00006 Structured worker handoff

## Corrective Work
- [open] `cw1` for assertion `a0`
  - Failure: Earlier run leaked memory
  - Repair: Flush the buffer per chunk
  - Source: event evt00007 Corrective work open

## Next Likely Action
Enable the flag for beta and re-run the benchmark

## Recent Turns

### Turn 1
- Ask: Implement the exporter
- Summary: Added CSVExporter with a chunked writer
- Status: completed
- Completed: 2026-06-05T12:00:00Z
- Output: outputs/turn_001.md
- Files:
  - Sources/Export/CSVExporter.swift

> Generated from `current_state.json`. Edit the JSON source of truth if ASTRA later supports manual state edits.
"""

    @Test("markdown render matches the frozen golden snapshot")
    func markdownRenderMatchesGolden() {
        #expect(TaskContextStateManager.renderMarkdown(Self.richState()) == Self.goldenMarkdown)
    }

    @Test("capsule state round-trips losslessly through encode/decode and render is stable")
    func capsuleStateRoundTripsLosslessly() throws {
        let state = Self.richState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(state)
        // Encoding is deterministic for a stable state (sorted keys, no timestamps).
        #expect(try encoder.encode(state) == first)
        // Decoding then re-rendering reproduces the golden — persistence is lossless for
        // every field the render surfaces.
        let decoded = try JSONDecoder().decode(TaskContextState.self, from: first)
        #expect(TaskContextStateManager.renderMarkdown(decoded) == Self.goldenMarkdown)
    }
}
