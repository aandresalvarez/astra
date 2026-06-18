import Foundation

/// A builder-facing way to answer "does my app actually work?" — runs the app in the sandbox
/// (WorkspaceAppPreviewRunner, executor-parity semantics, nothing external/persisted) and reports
/// pass/warn/fail per check. Three tiers share this result model:
///   Tier 1 — auto-exercise: run every action once and classify the outcome (this file).
///   Tier 2 — authored expectations: run declared check steps and assert an expected outcome
///            (WorkspaceAppCheck + runChecks).
///   Tier 3 — AI-authored: a plain-English scenario is turned into a Tier-2 check and run for real
///            (WorkspaceAppScenarioCheckGenerator).
enum WorkspaceAppCheckStatus: String, Codable, Sendable, Equatable {
    case pass, warn, fail
}

struct WorkspaceAppCheckResult: Identifiable, Sendable, Equatable {
    var id: String
    var label: String
    var status: WorkspaceAppCheckStatus
    var detail: String
}

struct WorkspaceAppSelfCheckReport: Sendable, Equatable {
    var results: [WorkspaceAppCheckResult]

    var passCount: Int { results.filter { $0.status == .pass }.count }
    var warnCount: Int { results.filter { $0.status == .warn }.count }
    var failCount: Int { results.filter { $0.status == .fail }.count }
    var isClean: Bool { failCount == 0 }
    var headline: String {
        "\(passCount) passed · \(warnCount) warning\(warnCount == 1 ? "" : "s") · \(failCount) failed"
    }
}

enum WorkspaceAppSelfCheck {
    // MARK: - Tier 1: auto-exercise

    /// Run every action once in the sandbox and classify: pass = real local effect, warn = simulated
    /// (task/external/side effect), a gate that held on sample data, or a write-labelled read; fail =
    /// the action threw a structural error.
    static func autoExercise(manifest: WorkspaceAppManifest, sampleRowsPerTable: Int = 3) -> WorkspaceAppSelfCheckReport {
        let runner = WorkspaceAppPreviewRunner(manifest: manifest, sampleRowsPerTable: sampleRowsPerTable)
        let results = manifest.actions.map { exercise($0, runner: runner, manifest: manifest) }
        return WorkspaceAppSelfCheckReport(results: results)
    }

    private static func exercise(
        _ action: WorkspaceAppActionSpec,
        runner: WorkspaceAppPreviewRunner,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppCheckResult {
        let label = action.label ?? action.id
        do {
            let result = try runner.run(action, manifest: manifest, input: defaultInput(for: action, runner: runner, manifest: manifest))
            let summary = result.outputSummary
            if summary.contains("(preview") {
                return WorkspaceAppCheckResult(id: action.id, label: label, status: .warn, detail: summary)
            }
            if isWriteLabeled(label), WorkspaceAppActionEffect.effect(for: action.type) == .read {
                return WorkspaceAppCheckResult(id: action.id, label: label, status: .warn,
                                               detail: "Labelled as a write but only reads — \(summary)")
            }
            return WorkspaceAppCheckResult(id: action.id, label: label, status: .pass, detail: summary)
        } catch {
            let description = String(describing: error)
            // A gate that holds / awaits approval on sample data is working, not broken.
            if ["approvalRequired", "gateBlocked", "agentRecommendation"].contains(where: description.contains) {
                return WorkspaceAppCheckResult(id: action.id, label: label, status: .warn,
                                               detail: "Gate held with sample data (runs inside its workflow).")
            }
            return WorkspaceAppCheckResult(id: action.id, label: label, status: .fail, detail: description)
        }
    }

    /// A permissive input that lets each action proceed: a sample record for inserts, an existing
    /// seeded row for update/delete, and confirmed approval/decision so gates don't block on setup.
    static func defaultInput(
        for action: WorkspaceAppActionSpec,
        runner: WorkspaceAppPreviewRunner,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppActionInput {
        let tableName = action.table
        let table = manifest.storage?.tables.first { $0.name == tableName }
        let decisions = action.approvalDecisions + action.agentDecisions
        switch action.type {
        case "appStorage.insert":
            let record = table.flatMap { WorkspaceAppDraftPreviewBuilder.defaultSampleRows(for: $0, count: 1, seed: 7).first } ?? [:]
            return WorkspaceAppActionInput(table: tableName, record: record, confirmedApproval: true)
        case "appStorage.update", "appStorage.delete":
            let existing = tableName.flatMap { runner.tables[$0]?.first } ?? [:]
            return WorkspaceAppActionInput(table: tableName, record: existing, confirmedDestructive: true, confirmedApproval: true)
        default:
            let firstRow = tableName.flatMap { runner.tables[$0]?.first }
            return WorkspaceAppActionInput(
                table: tableName,
                confirmedDestructive: true,
                confirmedApproval: true,
                agentRecommendationDecision: decisions.first,
                boundRows: firstRow.map { [$0] } ?? []
            )
        }
    }

    private static func isWriteLabeled(_ label: String) -> Bool {
        let verbs: Set<String> = ["save", "add", "create", "insert", "record", "submit", "new", "log", "register", "store"]
        let words = Set(label.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: verbs)
    }

    // MARK: - Tier 2: authored expectations

    /// Run each authored check's steps in a fresh sandbox, then assert its expectation. Defaults to
    /// an EMPTY sandbox (sampleRowsPerTable 0) so row-count expectations are deterministic
    /// (e.g. "after one Add, the table has 1 row").
    static func runChecks(_ checks: [WorkspaceAppCheck], manifest: WorkspaceAppManifest, sampleRowsPerTable: Int = 0) -> WorkspaceAppSelfCheckReport {
        WorkspaceAppSelfCheckReport(results: checks.map { runCheck($0, manifest: manifest, sampleRowsPerTable: sampleRowsPerTable) })
    }

    static func runCheck(_ check: WorkspaceAppCheck, manifest: WorkspaceAppManifest, sampleRowsPerTable: Int = 0) -> WorkspaceAppCheckResult {
        let runner = WorkspaceAppPreviewRunner(manifest: manifest, sampleRowsPerTable: sampleRowsPerTable)
        var summaries: [String: String] = [:]
        var stepError: String?
        for step in check.steps {
            guard let action = manifest.actions.first(where: { $0.id == step.actionID }) else {
                return WorkspaceAppCheckResult(id: check.id, label: check.label, status: .fail, detail: "Unknown action '\(step.actionID)'.")
            }
            let input: WorkspaceAppActionInput
            if let record = step.record {
                input = WorkspaceAppActionInput(table: action.table, record: record, confirmedDestructive: true, confirmedApproval: true)
            } else {
                input = defaultInput(for: action, runner: runner, manifest: manifest)
            }
            do {
                summaries[step.actionID] = try runner.run(action, manifest: manifest, input: input).outputSummary
            } catch {
                stepError = String(describing: error)
                break
            }
        }
        return evaluate(check, runner: runner, summaries: summaries, stepError: stepError)
    }

    private static func evaluate(
        _ check: WorkspaceAppCheck,
        runner: WorkspaceAppPreviewRunner,
        summaries: [String: String],
        stepError: String?
    ) -> WorkspaceAppCheckResult {
        let expect = check.expect
        func pass(_ detail: String) -> WorkspaceAppCheckResult { WorkspaceAppCheckResult(id: check.id, label: check.label, status: .pass, detail: detail) }
        func fail(_ detail: String) -> WorkspaceAppCheckResult { WorkspaceAppCheckResult(id: check.id, label: check.label, status: .fail, detail: detail) }

        switch expect.kind {
        case "noErrors":
            return stepError == nil ? pass("All \(check.steps.count) step(s) ran without error.") : fail(stepError ?? "A step failed.")
        case "rowCount":
            guard let table = expect.table, let value = expect.value else { return fail("rowCount expectation needs a table and value.") }
            if let stepError { return fail("A step failed before the count could be checked: \(stepError)") }
            let count = runner.tables[table]?.count ?? 0
            let op = expect.op ?? "eq"
            return compare(count, op, value)
                ? pass("\(table) has \(count) row(s).")
                : fail("Expected \(table) count \(op) \(value), got \(count).")
        case "summaryContains":
            guard let actionID = expect.actionID, let text = expect.text else { return fail("summaryContains needs an actionID and text.") }
            if let stepError { return fail("A step failed: \(stepError)") }
            let summary = summaries[actionID] ?? ""
            return summary.contains(text) ? pass(summary) : fail("Expected '\(text)' in '\(actionID)' output, got '\(summary)'.")
        default:
            return fail("Unknown expectation kind '\(expect.kind)'.")
        }
    }

    private static func compare(_ actual: Int, _ op: String, _ expected: Int) -> Bool {
        switch op {
        case "gte": return actual >= expected
        case "lte": return actual <= expected
        case "gt": return actual > expected
        case "lt": return actual < expected
        default: return actual == expected
        }
    }
}
