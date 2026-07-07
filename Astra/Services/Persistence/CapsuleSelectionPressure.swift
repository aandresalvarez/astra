import Foundation
import ASTRACore

/// Objective selection-pressure metrics for a Context Capsule: how many items each prompt
/// section drops past its render cap. No relevance judgment — just whether the
/// recency/cap-based selection actually evicts content, so Phase 2 (query-conditioned
/// selection) can be gated on a measured rate instead of a guess.
public struct CapsuleSelectionPressure: Equatable {
    public init(sections: [Section]) {
        self.sections = sections
    }

    public struct Section: Equatable {
        public init(name: String, rawCount: Int, cap: Int) {
            self.name = name
            self.rawCount = rawCount
            self.cap = cap
        }

        public let name: String
        public let rawCount: Int
        public let cap: Int
        public var evicted: Int { max(0, rawCount - cap) }
    }

    public let sections: [Section]
    public var totalEvicted: Int { sections.reduce(0) { $0 + $1.evicted } }
    public var evictingSections: [Section] { sections.filter { $0.evicted > 0 } }
    public var anyEviction: Bool { totalEvicted > 0 }

    /// Caps mirror the per-section limits in `TaskContextStateManager.promptContext`
    /// (and `maxPromptTurns` / `maxStandingInstructions`). If those render limits change,
    /// update these to match — the snapshot suite flags a render change but not this drift.
    public static func measure(_ state: TaskContextState) -> CapsuleSelectionPressure {
        CapsuleSelectionPressure(sections: [
            Section(name: "constraints", rawCount: state.constraints.count, cap: 6),
            Section(name: "acceptanceCriteria", rawCount: state.acceptanceCriteria.count, cap: 6),
            Section(name: "standingInstructions", rawCount: state.standingInstructions?.count ?? 0, cap: 8),
            Section(name: "validationAssertions", rawCount: state.validationContract?.assertions.count ?? 0, cap: 8),
            Section(name: "decisionFacts", rawCount: state.decisionFacts.count, cap: 6),
            Section(name: "openQuestions", rawCount: state.openQuestions.count, cap: 5),
            Section(name: "blockerFacts", rawCount: state.blockerFacts.count, cap: 5),
            Section(name: "changedFiles", rawCount: state.changedFiles.count, cap: 8),
            Section(name: "artifacts", rawCount: state.artifacts.count, cap: 6),
            Section(name: "correctiveWork", rawCount: state.correctiveWork?.count ?? 0, cap: 5),
            Section(name: "turns", rawCount: state.turns.count, cap: 4)
        ])
    }

    /// One-line prompt notice when cap-based selection dropped capsule items, so the
    /// agent knows compacted context exists instead of assuming it saw everything.
    public static func promptNotice(forTaskFolder folder: String) -> String? {
        guard !folder.isEmpty, let state = TaskContextStateManager.load(taskFolder: folder) else { return nil }
        return promptNotice(for: state)
    }

    public static func promptNotice(for state: TaskContextState) -> String? {
        let pressure = measure(state)
        guard pressure.anyEviction else { return nil }
        let sections = pressure.evictingSections
            .map { "\($0.name) (\($0.evicted) dropped)" }
            .sorted()
            .joined(separator: ", ")
        return "- Capsule eviction notice: \(pressure.totalEvicted) older item(s) fell out of this capsule: \(sections). Read the canonical state files or session history before treating absent details as nonexistent."
    }

    /// Render-time diagnostics merged into `promptDiagnosticsFields`. `prompt` is the
    /// assembled prompt; the capsule budget is "bound" when its block truncated.
    public static func fields(forTaskFolder folder: String, prompt: String) -> [String: String] {
        guard !folder.isEmpty, let state = TaskContextStateManager.load(taskFolder: folder) else { return [:] }
        let pressure = measure(state)
        return [
            "capsule_budget_bound": String(prompt.contains("... (thread intent truncated)")),
            "capsule_items_evicted": String(pressure.totalEvicted),
            "capsule_sections_evicting": pressure.evictingSections.map(\.name).sorted().joined(separator: ",")
        ]
    }
}
