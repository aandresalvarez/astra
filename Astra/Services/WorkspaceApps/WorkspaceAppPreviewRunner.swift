import Foundation

/// In-memory sandbox runner for App Studio's full Preview ("test before publish").
///
/// It mirrors `WorkspaceAppActionExecutor`'s per-action semantics WITHOUT any real side effect:
/// - `appStorage.insert/update/delete/query`, the gates, `rows.reduce`, and `gate.branch` run
///   FOR REAL against an in-memory table store seeded from `WorkspaceAppDraftPreviewBuilder`
///   sample rows, so a builder can actually add/edit/delete/list and watch metrics/charts update.
/// - Everything that would touch the outside world — `capability.read/write`, `task.*`,
///   `url.open`, `clipboard.copy`, `notification.show`, `artifact.export` — is SIMULATED with a
///   clear "(preview — would …)" summary and changes nothing.
/// - The permission gate is replayed exactly from the manifest's `defaultMode` + the `confirmed*`
///   input flags, so preview faithfully shows `draftOnly`/`approvalRequired`/`readOnly` blocks.
/// - `pipeline.run`/`loop.run` recurse through the same dispatch; a `task.*` sub-step is
///   short-circuited to simulation so the flow runs to completion instead of suspending.
///
/// Pure of SwiftData/FileManager/NSWorkspace: it holds a dictionary table store and builds a
/// `WorkspaceAppDetailDataSnapshot` on demand for the surface view to render. The transient
/// `WorkspaceAppRun` it returns is never inserted into any `ModelContext`.
final class WorkspaceAppPreviewRunner {
    /// Hard cap on loop iterations in preview, regardless of the manifest's `maxIterations`.
    static let previewLoopIterationCap = 5

    private(set) var manifest: WorkspaceAppManifest
    /// table name -> rows. The single source of truth the preview surface renders.
    private(set) var tables: [String: [[String: WorkspaceAppStorageValue]]]

    private let sandboxAppID = UUID()
    private let sandboxWorkspaceID = UUID()
    private let sampleRowsPerTable: Int

    init(
        manifest: WorkspaceAppManifest,
        sampleRowsPerTable: Int = 3,
        seededTables: [String: [[String: WorkspaceAppStorageValue]]]? = nil
    ) {
        self.manifest = manifest
        self.sampleRowsPerTable = sampleRowsPerTable
        self.tables = seededTables ?? Self.seedTables(manifest: manifest, count: sampleRowsPerTable)
    }

    /// Reset every table back to fresh deterministic sample data.
    func reset() {
        tables = Self.seedTables(manifest: manifest, count: sampleRowsPerTable)
    }

    private static func seedTables(
        manifest: WorkspaceAppManifest,
        count: Int
    ) -> [String: [[String: WorkspaceAppStorageValue]]] {
        var seeded: [String: [[String: WorkspaceAppStorageValue]]] = [:]
        for table in manifest.storage?.tables ?? [] {
            seeded[table.name] = WorkspaceAppDraftPreviewBuilder.defaultSampleRows(
                for: table, count: count, seed: 0
            )
        }
        return seeded
    }

    /// A snapshot reflecting the CURRENT in-memory store — the surface view re-reads this after
    /// every mutation so the table, metrics, and charts reflect the edit.
    func snapshot() -> WorkspaceAppDetailDataSnapshot {
        let storageTables = (manifest.storage?.tables ?? []).map { table in
            WorkspaceAppStorageTableSnapshot(
                name: table.name,
                columns: table.columns.map(\.name),
                rows: tables[table.name] ?? [],
                errorMessage: nil
            )
        }
        return WorkspaceAppDetailDataSnapshot(
            manifest: manifest,
            storageTables: storageTables,
            dependencyBindings: [],
            automationStates: [],
            runs: [],
            errorMessage: nil
        )
    }

    /// Matches `WorkspaceAppDetailView.onRunAction`'s closure shape so the surface view can route
    /// through the sandbox unchanged.
    func run(
        _ action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput
    ) throws -> WorkspaceAppActionExecutionResult {
        try enforcePermission(action: action, mode: manifest.permissions.defaultMode, input: input)
        let outcome = try dispatch(action: action, manifest: manifest, input: input, depth: 0)
        let run = WorkspaceAppRun(
            workspaceID: sandboxWorkspaceID,
            appID: sandboxAppID,
            appLogicalID: manifest.app.id,
            actionID: action.id,
            trigger: .test,
            status: .completed,
            outputSummary: outcome.summary
        )
        return WorkspaceAppActionExecutionResult(run: run, rows: outcome.rows, outputSummary: outcome.summary)
    }

    // MARK: - Permission (faithful replay of WorkspaceAppActionExecutor.enforcePermission)

    private func enforcePermission(
        action: WorkspaceAppActionSpec,
        mode: WorkspaceAppPermissionMode,
        input: WorkspaceAppActionInput
    ) throws {
        switch Self.effect(for: action.type) {
        case .read:
            return
        case .localWrite:
            guard mode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform local write action '\(action.id)'."
                )
            }
        case .externalWrite:
            switch mode {
            case .preApproved:
                return
            case .approvalRequired:
                guard input.confirmedApproval else {
                    throw WorkspaceAppActionExecutionError.permissionDenied(
                        "External write action '\(action.id)' requires explicit approval before execution."
                    )
                }
            case .draftOnly:
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Draft-only workspace apps cannot submit external write action '\(action.id)'."
                )
            case .readOnly:
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot submit external write action '\(action.id)'."
                )
            }
        case .destructive:
            guard mode != .readOnly else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Read-only workspace apps cannot perform destructive action '\(action.id)'."
                )
            }
            guard input.confirmedDestructive else {
                throw WorkspaceAppActionExecutionError.permissionDenied(
                    "Destructive action '\(action.id)' requires explicit confirmation before execution."
                )
            }
        }
    }

    /// Delegates to the shared `WorkspaceAppActionEffect` map (same source as the real executor).
    static func effect(for actionType: String) -> WorkspaceAppContractEffect {
        WorkspaceAppActionEffect.effect(for: actionType)
    }

    // MARK: - Dispatch

    private struct Outcome {
        var rows: [[String: WorkspaceAppStorageValue]]
        var summary: String
    }

    private func dispatch(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        depth: Int
    ) throws -> Outcome {
        switch action.type {
        case "appStorage.insert":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            let record = input.effectiveRecord
            guard !record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            tables[table, default: []].append(record)
            return Outcome(rows: [], summary: "Inserted 1 record into \(table).")

        case "appStorage.update":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            let record = input.effectiveRecord
            guard !record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let primaryKey = try primaryKeyColumn(in: table, manifest: manifest)
            // storageService.updateRecord rejects a record that carries only the primary key (no
            // columns to SET) — mirror that so preview reports the same failure, not a silent no-op.
            guard record.keys.contains(where: { $0 != primaryKey }) else {
                throw WorkspaceAppActionExecutionError.storageFailed(
                    String(describing: WorkspaceAppStorageError.missingRecordValues)
                )
            }
            guard let keyValue = record[primaryKey],
                  let index = tables[table]?.firstIndex(where: { $0[primaryKey] == keyValue }) else {
                throw WorkspaceAppActionExecutionError.storageFailed("No record matched the primary key in \(table).")
            }
            for (column, value) in record { tables[table]?[index][column] = value }
            return Outcome(rows: [], summary: "Updated 1 record in \(table).")

        case "appStorage.delete":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            guard !input.record.isEmpty else { throw WorkspaceAppActionExecutionError.missingRecord }
            let primaryKey = try primaryKeyColumn(in: table, manifest: manifest)
            guard let keyValue = input.record[primaryKey] else {
                throw WorkspaceAppActionExecutionError.storageFailed("Delete requires the primary key '\(primaryKey)'.")
            }
            let before = tables[table]?.count ?? 0
            tables[table]?.removeAll { $0[primaryKey] == keyValue }
            let removed = before - (tables[table]?.count ?? 0)
            return Outcome(rows: [], summary: "Deleted \(removed) record from \(table).")

        case "appStorage.query":
            guard let table = input.table ?? action.table else { throw WorkspaceAppActionExecutionError.missingTable }
            let rows = Array((tables[table] ?? []).prefix(max(0, input.limit)))
            return Outcome(rows: rows, summary: "Read \(rows.count) records from \(table).")

        case "gate.humanApproval":
            guard input.confirmedApproval else {
                throw WorkspaceAppActionExecutionError.approvalRequired(action.id)
            }
            return Outcome(rows: [], summary: "Approval recorded for '\(action.id)'.")

        case "gate.expression":
            return try runExpressionGate(action: action, input: input)

        case "gate.agentRecommendation":
            let prompt = action.agentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let policyMode = action.agentPolicyMode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let decisions = Set(action.agentDecisions)
            guard !prompt.isEmpty, !decisions.isEmpty, !policyMode.isEmpty else {
                throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
            }
            let decision = input.agentRecommendationDecision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !decision.isEmpty else {
                throw WorkspaceAppActionExecutionError.agentRecommendationRequired(action.id)
            }
            guard decisions.contains(decision) else {
                throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
            }
            if (action.agentRequiresApproval || policyMode == "approvalRequired"), !input.confirmedApproval {
                throw WorkspaceAppActionExecutionError.approvalRequired(action.id)
            }
            return Outcome(rows: [], summary: "(preview — recommendation '\(decision)' accepted; live agent reasoning is not run)")

        case "rows.reduce":
            return runReduce(action: action, input: input)

        case "gate.branch":
            return try runBranch(action: action, manifest: manifest, input: input, depth: depth)

        case "pipeline.run":
            return try runPipeline(action: action, manifest: manifest, input: input, depth: depth)

        case "loop.run":
            return try runLoop(action: action, manifest: manifest, input: input, depth: depth)

        // Simulated — no real side effect.
        case "capability.read":
            return Outcome(rows: [], summary: "(preview — external read simulated; connect a live source after publishing)")
        case "capability.write":
            let target = action.requirementRef ?? "the connected system"
            let fields = input.effectiveRecord.count
            return Outcome(rows: [], summary: "(preview — would write \(fields) field(s) to \(target); nothing was sent)")
        case "task.createDraft":
            return Outcome(rows: [], summary: "(preview — would create draft task '\(taskGoalLabel(action: action, input: input))')")
        case "task.createAndRun", "task.fanOut":
            return Outcome(rows: [], summary: "(preview — would queue task '\(taskGoalLabel(action: action, input: input))'; no agent runs in preview)")
        case "url.open":
            return Outcome(rows: [], summary: "(preview — would open \(action.targetURL ?? "a URL"))")
        case "clipboard.copy":
            let count = (action.clipboardText ?? "").count
            return Outcome(rows: [], summary: "(preview — would copy \(count) character(s) to the clipboard)")
        case "notification.show":
            return Outcome(rows: [], summary: "(preview — would notify: \(action.notificationTitle ?? action.notificationBody ?? "notification"))")
        case "artifact.export":
            let table = action.table ?? input.table ?? "data"
            return Outcome(rows: [], summary: "(preview — would export \(table) as \(action.exportFormat ?? input.exportFormat ?? "csv"); no file written)")

        default:
            throw WorkspaceAppActionExecutionError.unsupportedActionType(action.type)
        }
    }

    // MARK: - Composite + gate helpers

    private func runExpressionGate(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput
    ) throws -> Outcome {
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !field.isEmpty,
              let gateOperator = WorkspaceAppExpressionGateOperator(
                rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              ) else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }
        // Read from `record` only — the real executeExpressionGate does NOT consult boundRows, and
        // bindingForward keeps `record` as the original top-level input across pipeline steps.
        let actual = input.record[field]
        guard Self.evaluate(gateOperator, actual: actual, expected: action.gateValue) else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }
        return Outcome(rows: [], summary: "Expression gate '\(action.id)' passed.")
    }

    private func runReduce(
        action: WorkspaceAppActionSpec,
        input: WorkspaceAppActionInput
    ) -> Outcome {
        let strategy = action.reduceStrategy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "count"
        let column = action.reduceColumn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rows = input.boundRows
        let outputKey: String
        let value: WorkspaceAppStorageValue
        switch strategy {
        case "sum":
            outputKey = column
            value = .real(rows.reduce(0.0) { $0 + (Self.numericValue($1[column]) ?? 0) })
        case "concat":
            outputKey = column
            let parts = rows.compactMap { row -> String? in
                switch row[column] {
                case .none, .some(.null): return nil
                case .some(let cell): return Self.describe(cell)
                }
            }
            value = .text(parts.joined(separator: ", "))
        case "first":
            outputKey = column
            value = rows.first?[column] ?? .null
        case "last":
            outputKey = column
            value = rows.last?[column] ?? .null
        default:
            outputKey = column.isEmpty ? "count" : column
            value = .integer(Int64(rows.count))
        }
        return Outcome(rows: [[outputKey: value]], summary: "Reduced \(rows.count) rows by \(strategy).")
    }

    private func runBranch(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        depth: Int
    ) throws -> Outcome {
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The executor REQUIRES a valid operator (else gateBlocked) and reads the field per-element
        // (boundRows.first?[field] ?? record[field]) rather than committing to one source dict.
        guard let gateOperator = WorkspaceAppExpressionGateOperator(
            rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) else {
            throw WorkspaceAppActionExecutionError.gateBlocked(action.id)
        }
        let actual = field.isEmpty ? nil : (input.boundRows.first?[field] ?? input.record[field])
        let passed = Self.evaluate(gateOperator, actual: actual, expected: action.gateValue)
        let targetID = passed ? action.thenStep : action.elseStep
        guard let targetID, let target = manifest.actions.first(where: { $0.id == targetID }) else {
            return Outcome(rows: [], summary: "Branch '\(action.id)' → \(passed ? "then" : "else") (no step).")
        }
        let result = try dispatchOrSimulateStep(target, manifest: manifest, input: input, depth: depth + 1)
        return Outcome(rows: result.rows, summary: "Branch '\(action.id)' → \(target.id): \(result.summary)")
    }

    private func runPipeline(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        depth: Int
    ) throws -> Outcome {
        var carried = input
        var ran = 0
        for stepID in action.steps {
            guard let step = manifest.actions.first(where: { $0.id == stepID }) else { continue }
            let result = try dispatchOrSimulateStep(step, manifest: manifest, input: carried, depth: depth + 1)
            carried = carried.bindingForward(rows: result.rows)
            ran += 1
        }
        return Outcome(rows: carried.boundRows, summary: "Ran \(ran) pipeline step(s) (preview).")
    }

    private func runLoop(
        action: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        depth: Int
    ) throws -> Outcome {
        // Mirror the executor's guard: a loop without steps / maxIterations / a stop field is
        // rejected (missingLoopBounds) rather than silently "running" in preview.
        guard !action.steps.isEmpty,
              let maxIterations = action.maxIterations,
              let stopField = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stopField.isEmpty else {
            throw WorkspaceAppActionExecutionError.missingLoopBounds(action.id)
        }
        let cap = min(maxIterations, Self.previewLoopIterationCap)
        let stopOperator = WorkspaceAppExpressionGateOperator(
            rawValue: action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        var iterations = 0
        var carried = input
        while iterations < cap {
            for stepID in action.steps {
                guard let step = manifest.actions.first(where: { $0.id == stepID }) else { continue }
                let result = try dispatchOrSimulateStep(step, manifest: manifest, input: carried, depth: depth + 1)
                carried = carried.bindingForward(rows: result.rows)
            }
            iterations += 1
            if let stopOperator,
               Self.evaluate(stopOperator, actual: carried.record[stopField], expected: action.gateValue) {
                break
            }
        }
        return Outcome(rows: carried.boundRows, summary: "Loop ran \(iterations) iteration(s) (preview, capped at \(cap)).")
    }

    /// Inside a composite, a `task.*` step is short-circuited to simulation so the flow completes
    /// rather than suspending; everything else is dispatched normally. The per-step permission gate
    /// is enforced FIRST — exactly as the real executor does for every pipeline/loop/branch sub-step
    /// — so a draftOnly/approvalRequired/readOnly block on a nested action shows up in Preview
    /// instead of the workflow appearing to succeed and then failing at real run time.
    private func dispatchOrSimulateStep(
        _ step: WorkspaceAppActionSpec,
        manifest: WorkspaceAppManifest,
        input: WorkspaceAppActionInput,
        depth: Int
    ) throws -> Outcome {
        try enforcePermission(action: step, mode: manifest.permissions.defaultMode, input: input)
        if step.type.hasPrefix("task.") {
            return Outcome(rows: [], summary: "(preview — step '\(step.id)' simulated: would run task)")
        }
        return try dispatch(action: step, manifest: manifest, input: input, depth: depth)
    }

    // MARK: - Small value helpers (mirror the executor's private predicate math)

    private func primaryKeyColumn(in tableName: String, manifest: WorkspaceAppManifest) throws -> String {
        guard let table = manifest.storage?.tables.first(where: { $0.name == tableName }),
              let primaryKey = table.columns.first(where: \.primaryKey)?.name else {
            throw WorkspaceAppActionExecutionError.missingPrimaryKey(tableName)
        }
        return primaryKey
    }

    private func taskGoalLabel(action: WorkspaceAppActionSpec, input: WorkspaceAppActionInput) -> String {
        let goal = (input.taskGoal ?? action.taskGoal ?? action.taskTitle ?? action.label ?? action.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? action.id : goal
    }

    static func evaluate(
        _ gateOperator: WorkspaceAppExpressionGateOperator,
        actual: WorkspaceAppStorageValue?,
        expected: WorkspaceAppStorageValue?
    ) -> Bool {
        switch gateOperator {
        case .exists: return actual != nil && actual != .null
        case .notExists: return actual == nil || actual == .null
        case .equals: return actual == expected
        case .notEquals: return actual != expected
        case .greaterThan: return numericComparison(actual, expected).map { $0 > 0 } ?? false
        case .greaterThanOrEquals: return numericComparison(actual, expected).map { $0 >= 0 } ?? false
        case .lessThan: return numericComparison(actual, expected).map { $0 < 0 } ?? false
        case .lessThanOrEquals: return numericComparison(actual, expected).map { $0 <= 0 } ?? false
        }
    }

    private static func numericComparison(
        _ actual: WorkspaceAppStorageValue?,
        _ expected: WorkspaceAppStorageValue?
    ) -> Int? {
        guard let a = numericValue(actual), let b = numericValue(expected) else { return nil }
        if a < b { return -1 }
        if a > b { return 1 }
        return 0
    }

    static func numericValue(_ value: WorkspaceAppStorageValue?) -> Double? {
        switch value {
        case .integer(let v): return Double(v)
        case .real(let v): return v
        case .text(let v): return Double(v)
        case .bool, .null, .none: return nil
        }
    }

    private static func describe(_ value: WorkspaceAppStorageValue) -> String {
        switch value {
        case .null: return ""
        case .text(let v): return v
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        }
    }
}
