import Foundation

struct WorkspaceAppManifestValidationReport: Sendable, Equatable {
    struct Issue: Sendable, Equatable {
        enum Severity: String, Sendable, Equatable {
            case blocker
            case warning
        }

        var severity: Severity
        var path: String
        var message: String
    }

    var issues: [Issue]

    var blockers: [Issue] {
        issues.filter { $0.severity == .blocker }
    }

    var warnings: [Issue] {
        issues.filter { $0.severity == .warning }
    }

    var isValid: Bool {
        blockers.isEmpty
    }
}

enum WorkspaceAppManifestValidator {
    static func validate(_ manifest: WorkspaceAppManifest) -> WorkspaceAppManifestValidationReport {
        var issues: [WorkspaceAppManifestValidationReport.Issue] = []

        if manifest.schemaVersion < 1 {
            issues.append(blocker("/schemaVersion", "Schema version must be at least 1."))
        }
        validateIdentifier(manifest.app.id, path: "/app/id", label: "App ID", issues: &issues)
        if manifest.app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(blocker("/app/name", "App name is required."))
        }

        let requirementIDs = validateRequirements(
            manifest.requirements,
            registry: WorkspaceAppContractRegistry(),
            issues: &issues
        )
        let storageTables = validateStorage(manifest.storage, issues: &issues)
        let sourceIDs = validateSources(manifest.sources, requirementIDs: requirementIDs, issues: &issues)
        let actionIDs = validateActions(
            manifest.actions,
            requirementIDs: requirementIDs,
            sourceIDs: sourceIDs,
            storageTables: storageTables,
            issues: &issues
        )
        validateViews(manifest.views, storageTables: storageTables, actionIDs: actionIDs, issues: &issues)
        validateAutomations(
            manifest.automations,
            actionIDs: actionIDs,
            actionsByID: Dictionary(manifest.actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            issues: &issues
        )
        validatePermissions(manifest.permissions, issues: &issues)
        validatePermissionCoverage(manifest, issues: &issues)
        validatePermissionConsistency(manifest, issues: &issues)
        validateSubmitBlock(manifest, issues: &issues)
        validateUsability(manifest, issues: &issues)
        validateHTMLApp(manifest, issues: &issues)

        return WorkspaceAppManifestValidationReport(issues: issues)
    }

    /// Phase 1 dynamic HTML apps: the model authors the UI, but Swift owns the CSP-locked,
    /// no-network, no-bridge document shell (`WorkspaceAppWebReportHTML.appDocument`), so the
    /// security guarantee is structural — it holds regardless of what the HTML contains. These
    /// checks are therefore defense-in-depth + clear authoring errors, not the security boundary.
    private static let maxHTMLAppBytes = 256 * 1024
    private static func validateHTMLApp(
        _ manifest: WorkspaceAppManifest,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let html = manifest.html else { return }
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(blocker("/html", "HTML app body is empty."))
            return
        }
        // Phase 2/5/connector-read invariant: an HTML app's UI is the HTML itself, and its capabilities
        // reach native ONLY through the vetted `astra.*` bridge. So it MAY declare its own `storage` +
        // `appStorage.*` actions (the data allowlist), governed WORKFLOW actions — `task.*`, `gate.*`
        // (pipeline steps; a human still resolves them in the native approval queue), `pipeline.run`/
        // `loop.run`, `artifact.export`, `notification.show`, `rows.reduce` — AND READ-ONLY connectors:
        // `requirements` + read-mode `sources` + `capability.read` actions (the page reads live connector
        // data via `astra.read`, getting back scalar rows only, credentials never crossing back). It must
        // NOT declare `capability.WRITE` (an external write must go through a gated native path, never
        // JS), native `views`/widgets (the HTML renders the UI), `automations` (time-triggered, not a UI
        // action), or `url.open` (arbitrary navigation).
        var forbidden: [String] = []
        if !manifest.views.isEmpty { forbidden.append("views") }
        if !manifest.automations.isEmpty { forbidden.append("automations") }
        let badActions = manifest.actions.filter { !isHTMLAppActionAllowed($0.type) }
        if !badActions.isEmpty {
            let types = Set(badActions.map(\.type)).sorted().joined(separator: ", ")
            forbidden.append("disallowed actions (\(types))")
        }
        if !forbidden.isEmpty {
            issues.append(blocker(
                "/html",
                "An HTML app may declare its own storage + appStorage actions, governed workflow actions (task/gate/pipeline/loop/export/notification/rows.reduce), and READ-ONLY connectors (requirements + read sources + capability.read) reached via the astra bridge; it must not declare \(forbidden.joined(separator: ", ")). Connector WRITES must use a declarative app."
            ))
        }
        // Connector reads must be READ-ONLY and well-formed. (a) An HTML app may declare a source only
        // in read mode — a write-mode source has no place in a read-only HTML app (capability.write is
        // blocked, so no action could use it). (b) Every `capability.read` action must name a DECLARED
        // source via a non-empty `sourceRef`: the `astra.read` bridge resolves a source ONLY through a
        // matching sourceRef (so the page can't fabricate one), and the executor's dependency binding
        // then supplies credentials.
        for (index, source) in manifest.sources.enumerated() where source.mode != "read" {
            issues.append(blocker(
                "/sources/\(index)/mode",
                "An HTML app may declare connector sources only in read mode (source '\(source.id)' is '\(source.mode)'). HTML apps cannot write to connectors."
            ))
        }
        let requirementsByID = Dictionary(manifest.requirements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, action) in manifest.actions.enumerated() where action.type == "capability.read" {
            let ref = action.sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !ref.isEmpty,
                  let sourceIndex = manifest.sources.firstIndex(where: { $0.id == ref }) else {
                issues.append(blocker(
                    "/actions/\(index)/sourceRef",
                    "An HTML app's capability.read action '\(action.id)' must name a declared source via sourceRef so the astra.read bridge can resolve it."
                ))
                continue
            }
            let source = manifest.sources[sourceIndex]
            // The read must go through a CONNECTOR (a requirement-bound source), never an app-storage
            // table: `astra.read` is for connectors; storage is reached through `appStorage.query`. A
            // source whose id/tableRef shadows a storage table would otherwise resolve from storage with
            // no dependency binding, bypassing the connector-read contract.
            let reqRef = source.requirementRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let requirement = requirementsByID[reqRef] else {
                issues.append(blocker(
                    "/sources/\(sourceIndex)/requirementRef",
                    "An HTML app's capability.read source '\(source.id)' must reference a connector requirement via requirementRef (astra.read reads connectors, not app storage)."
                ))
                continue
            }
            // The source operation must be one the REQUIREMENT declares — a manifest can't declare a
            // narrow op for review/mapping but run a broader op at read time.
            if let op = source.operation?.trimmingCharacters(in: .whitespacesAndNewlines), !op.isEmpty,
               !requirement.operations.contains(op) {
                issues.append(blocker(
                    "/sources/\(sourceIndex)/operation",
                    "An HTML app's capability.read source '\(source.id)' uses operation '\(op)' that its requirement '\(requirement.id)' does not declare."
                ))
            }
            // A capability.read source must NOT shadow an app-storage table. The source resolver matches
            // a source to storage by [tableRef, sourceRef, id] (storage-FIRST), so a connector source
            // whose id/tableRef/sourceRef equals a storage table name would read app storage with NO
            // dependency binding — reachable from JS via a capability.read pipeline/loop STEP run through
            // `astra.runAction` (the sync executor path), bypassing the connector binding. Rejecting it
            // here (enforced at render via fail-closed re-validation) closes that path; the connector-only
            // async resolver closes the direct `astra.read` path.
            let storageTableNames = Set((manifest.storage?.tables ?? []).map(\.name))
            let shadowRefs = [source.id, source.tableRef, source.sourceRef].compactMap { $0 }
            if let shadow = shadowRefs.first(where: { storageTableNames.contains($0) }) {
                issues.append(blocker(
                    "/sources/\(sourceIndex)/id",
                    "An HTML app's capability.read source '\(source.id)' must not share an id/tableRef/sourceRef ('\(shadow)') with a storage table — that would shadow app storage. Rename the connector source."
                ))
            }
        }
        // Each appStorage action an HTML app declares is a data-bridge allowlist entry, so it must
        // name a specific declared table — a table-less grant would expose the op on EVERY table.
        for (index, action) in manifest.actions.enumerated() where action.type.hasPrefix("appStorage.") {
            if action.table?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker(
                    "/actions/\(index)/table",
                    "An HTML app's appStorage action '\(action.id)' must name one of its declared tables (a table-less grant would expose the operation on every table)."
                ))
            }
        }
        // Workflow gating (Phase 5): the `astra.runAction` bridge can TRIGGER a declared
        // pipeline/loop, so the MANIFEST must guarantee external effects in those runs are
        // human-gated — the bridge relies on this admission check, not just on the deterministic
        // builders, so a hand/model-authored HTML app can't ship an ungated write.
        //  - A `pipeline.run` may include an external-effect step only if a `gate.humanApproval`
        //    step PRECEDES it. The JS bridge can trigger the parent pipeline without minting
        //    `confirmedApproval`, and `.preApproved` app mode is intentionally not a workflow-level
        //    human gate for agent launches, connector writes, fan-out, or exports.
        //  - A `loop.run` may not include ANY external-effect step (export / agent task / connector
        //    write): loops execute steps inline with no suspend/approval, so a write would be
        //    re-triggerable without limit.
        let stepType: (String) -> String = { id in manifest.actions.first { $0.id == id }?.type ?? "" }
        let externalEffectSteps: Set<String> = ["artifact.export", "task.createAndRun", "task.fanOut", "capability.write"]
        for (index, action) in manifest.actions.enumerated() where action.type == "pipeline.run" || action.type == "loop.run" {
            let stepTypes = action.steps.map(stepType)
            // Steps must be LEAF actions — never another pipeline/loop — so the flat gate/export
            // analysis below is complete (a nested composite, or a branch step, could otherwise route
            // to an ungated `artifact.export` indirectly). `gate.branch`/`task.fanOut` can't be
            // declared at all (see `isHTMLAppActionAllowed`); this also rejects a nested run.
            if let nested = stepTypes.first(where: { $0 == "pipeline.run" || $0 == "loop.run" }) {
                issues.append(blocker(
                    "/actions/\(index)/steps",
                    "An HTML app's '\(action.id)' may not nest another '\(nested)' as a step; keep workflow steps flat so external effects stay gated."
                ))
            }
            if action.type == "loop.run" {
                if let bad = stepTypes.first(where: { externalEffectSteps.contains($0) }) {
                    issues.append(blocker(
                        "/actions/\(index)/steps",
                        "An HTML app's loop '\(action.id)' must not run an external-effect step ('\(bad)') — loops execute inline with no approval gate. Use a pipeline with a human-approval gate."
                    ))
                }
            } else if let ungatedStep = firstUngatedExternalEffectStep(in: stepTypes, externalEffectSteps: externalEffectSteps) {
                issues.append(blocker(
                    "/actions/\(index)/steps",
                    "An HTML app's pipeline '\(action.id)' reaches external-effect step '\(ungatedStep)' without a preceding gate.humanApproval step; a JS trigger could write ungated. Add a human-approval gate before the external effect."
                ))
            }
        }
        if html.utf8.count > maxHTMLAppBytes {
            issues.append(blocker("/html", "HTML app body exceeds the \(maxHTMLAppBytes / 1024) KB limit."))
        }
        let lowered = html.lowercased()
        if lowered.contains("<iframe") {
            issues.append(blocker("/html", "HTML apps may not embed <iframe> elements."))
        }
        // The sandbox CSP has NO 'unsafe-eval', so eval()/new Function would silently no-op at
        // runtime (a calculator that doesn't compute). Reject it as a clear blocker so the repair
        // loop rewrites it to compute directly instead of shipping a dead UI.
        if containsUnsafeEval(lowered) {
            issues.append(blocker(
                "/html",
                "HTML apps run under a strict CSP with no 'unsafe-eval' — remove eval()/new Function(...) and compute directly, or the app will silently fail to run."
            ))
        }
        // External resource loads are blocked by the CSP at render time; flagging them here turns a
        // silently-blocked (broken) resource into a clear authoring error. A self-contained app
        // needs none — all markup, CSS, and JS run locally with no network. (Best-effort string
        // check; the CSP, not this, is the security boundary.)
        for marker in ["src=\"http", "src='http", "src=http"] where lowered.contains(marker) {
            issues.append(blocker(
                "/html",
                "HTML apps must be self-contained — no external resources (found '\(marker)'). Inline all markup, CSS, and JS; there is no network."
            ))
            break
        }
        // Network / external-resource APIs. The CSP (default-src 'none') already blocks the actual
        // egress at runtime, so these would silently no-op — but letting them through ships a
        // broken app AND lets a non-self-contained app pass review (defeating the repair loop). A
        // data-backed app reaches its OWN storage through the astra.* bridge (postMessage), never
        // the network, so none of these have a legitimate use.
        for marker in ["xmlhttprequest", "websocket", "eventsource", "sendbeacon",
                       "@import", "importscripts", "navigator.serviceworker"] where lowered.contains(marker) {
            issues.append(blocker(
                "/html",
                "HTML apps run with no network (CSP default-src 'none') — remove '\(marker)'. Use the astra.* data bridge for storage."
            ))
            break
        }
        for call in ["fetch(", "import("] where containsStandaloneCall(lowered, call) {
            issues.append(blocker(
                "/html",
                "HTML apps run with no network (CSP default-src 'none') — remove '\(call)'. Use the astra.* data bridge for storage."
            ))
            break
        }
        if containsExternalScript(lowered) {
            issues.append(blocker(
                "/html",
                "HTML apps must be self-contained — a <script src> or <link> pulls an external resource. Inline all CSS and JS; there is no network."
            ))
        } else if lowered.contains("<link") {
            issues.append(blocker(
                "/html",
                "HTML apps must be self-contained — no <link> elements. Inline all CSS; there is no network."
            ))
        }
    }

    /// Action types an HTML app may DECLARE. Storage (`appStorage.*`) is the data allowlist; the rest
    /// are workflow primitives. Deliberately an EXPLICIT set, NOT a `task.`/`gate.` prefix: it EXCLUDES
    /// the branching/fan-out primitives `gate.branch` and `task.fanOut` (and `task.open`), because
    /// those introduce graph edges (branch targets, fan-out children) that would let an external
    /// effect like `artifact.export` be reached indirectly — past the flat gate-before-export check in
    /// `validateHTMLApp`. Keeping the HTML workflow vocabulary FLAT + branch-free makes that admission
    /// analysis complete. `capability.read` IS allowed (a READ-ONLY connector fetch via `astra.read`,
    /// scalar rows only); `capability.WRITE` stays EXCLUDED (an external write must go through a gated
    /// native path, never JS). Also excludes `url.open` (navigation).
    static func isHTMLAppActionAllowed(_ type: String) -> Bool {
        if type.hasPrefix("appStorage.") { return true }
        // NOTE: `clipboard.copy` is intentionally excluded — it writes the system pasteboard with no
        // gesture/approval gate; HTML apps use the browser's gesture-gated `navigator.clipboard`.
        return ["task.createDraft", "task.createAndRun",
                "gate.humanApproval", "gate.agentRecommendation", "gate.expression",
                "pipeline.run", "loop.run", "artifact.export", "notification.show",
                "rows.reduce", "capability.read"].contains(type)
    }

    private static func firstUngatedExternalEffectStep(
        in stepTypes: [String],
        externalEffectSteps: Set<String>
    ) -> String? {
        var hasHumanApprovalGate = false
        for type in stepTypes {
            if type == "gate.humanApproval" {
                hasHumanApprovalGate = true
            } else if externalEffectSteps.contains(type), !hasHumanApprovalGate {
                return type
            }
        }
        return nil
    }

    /// True if `lowered` contains an `eval(` call or `new Function`. `eval(` is matched only as a
    /// standalone call (preceding char is not an identifier char), so "retrieval(" is not flagged.
    private static func containsUnsafeEval(_ lowered: String) -> Bool {
        lowered.contains("new function") || containsStandaloneCall(lowered, "eval(")
    }

    /// True if `lowered` contains `needle` as a standalone call — the char immediately before it is
    /// not an identifier char — so "fetch(" does not match inside "prefetch(" and "import(" does not
    /// match inside "reimport(".
    private static func containsStandaloneCall(_ lowered: String, _ needle: String) -> Bool {
        var search = lowered.startIndex..<lowered.endIndex
        while let range = lowered.range(of: needle, range: search) {
            if range.lowerBound == lowered.startIndex { return true }
            let before = lowered[lowered.index(before: range.lowerBound)]
            if !(before.isLetter || before.isNumber || before == "_") { return true }
            search = range.upperBound..<lowered.endIndex
        }
        return false
    }

    /// True if any `<script …>` open tag carries a `src` attribute — an external or `data:` script
    /// that bypasses the inline-only contract (and the CSP would block it anyway).
    private static func containsExternalScript(_ lowered: String) -> Bool {
        var search = lowered.startIndex..<lowered.endIndex
        while let open = lowered.range(of: "<script", range: search) {
            let tagEnd = lowered.range(of: ">", range: open.upperBound..<lowered.endIndex)?.lowerBound ?? lowered.endIndex
            if lowered[open.upperBound..<tagEnd].contains("src") { return true }
            search = tagEnd..<lowered.endIndex
        }
        return false
    }

    /// Usability invariants — the safety net that stops generation (model OR deterministic) from
    /// shipping a "looks valid but can't be used" app, regardless of which path produced it.
    ///
    /// (a) Storage-populatable: if the app SHOWS a storage table (a non-form data view or a
    ///     metric/chart widget reads it) it must also have a way to ADD rows — an
    ///     `appStorage.insert` action, a form view, or a workflow/connector write. A dashboard over
    ///     a table nothing can fill is the read-only-shell defect.
    /// (b) Label/effect consistency: an action LABELED as a write (save/add/create/…) must not be a
    ///     read-only action type (e.g. a "Save" button wired to `appStorage.query`).
    private static func validateUsability(
        _ manifest: WorkspaceAppManifest,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        // A dynamic HTML app renders the WebView full-surface — its native storage/views/actions
        // are never shown, so the "shows a table it can't fill" net doesn't apply. (See
        // WorkspaceAppSurfaceView, which branches on `manifest.html`.)
        guard manifest.html == nil else { return }
        let tableNames = Set((manifest.storage?.tables ?? []).map(\.name))
        if !tableNames.isEmpty {
            var shown = Set<String>()
            for view in manifest.views where view.type != "form" {
                if let table = view.table, tableNames.contains(table) { shown.insert(table) }
                for widget in view.widgets {
                    if let table = widget.table, tableNames.contains(table) { shown.insert(table) }
                }
            }
            let hasPopulatingPath = manifest.actions.contains { $0.type == "appStorage.insert" }
                || manifest.views.contains { $0.type == "form" && !$0.formFields.isEmpty }
                || manifest.actions.contains {
                    ["pipeline.run", "loop.run", "task.fanOut", "capability.write"].contains($0.type)
                }
            if !shown.isEmpty && !hasPopulatingPath {
                issues.append(blocker(
                    "/storage",
                    "App shows stored data (\(shown.sorted().joined(separator: ", "))) but has no way to add records — add an Add action (appStorage.insert), a form, or a workflow that populates it. A dashboard over a table nothing can fill is not usable."
                ))
            }
        }

        let writeVerbs: Set<String> = [
            "save", "add", "create", "insert", "record", "submit", "new", "log", "register", "store"
        ]
        for (index, action) in manifest.actions.enumerated() {
            guard let label = action.label?.lowercased(), !label.isEmpty else { continue }
            let words = Set(label.split(whereSeparator: { !$0.isLetter }).map(String.init))
            guard !words.isDisjoint(with: writeVerbs) else { continue }
            if WorkspaceAppActionEffect.effect(for: action.type) == .read {
                issues.append(blocker(
                    "/actions/\(index)/type",
                    "Action '\(action.label ?? action.id)' is labeled as a write but its type '\(action.type)' only reads — wire it to a write action (e.g. appStorage.insert) or rename it."
                ))
            }
        }
    }

    /// Slice 5b: a form flagged with `submitBlockedReasons` (e.g. branching ASTRA can't honor)
    /// must NOT be publishable with a live external submit — it stays read-only / draft-only until
    /// the reasons are resolved, so a blocked form can never silently write to the system of record.
    private static func validateSubmitBlock(
        _ manifest: WorkspaceAppManifest,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let reasons = manifest.submitBlockedReasons, !reasons.isEmpty else { return }
        let mode = manifest.permissions.defaultMode
        if mode != .readOnly && mode != .draftOnly {
            issues.append(blocker(
                "/submitBlockedReasons",
                "Submit is blocked pending review (\(reasons.count) issue(s)); the form must be read-only or draft-only until resolved: \(reasons.joined(separator: "; "))"
            ))
        }
    }

    /// An HTML app's UI is the HTML itself: its buttons call write actions directly through the
    /// `astra.*` bridge, with NO governance UI around them. So a read-only HTML app that declares a
    /// write/destructive action — e.g. an `appStorage.insert` "Add" button — has DEAD buttons: the
    /// write is permission-denied at runtime (`WorkspaceAppActionExecutor`/`WorkspaceAppPreviewRunner`
    /// gate local writes on mode) and the user just sees nothing happen. This is exactly the model
    /// emitting `defaultMode: readOnly` for a data app that needs to save. Blocking it lets the repair
    /// loop self-correct to a writable mode (grounded verification also catches it post-build, but
    /// blocking is cheaper + upstream).
    ///
    /// Scoped to HTML apps on purpose: for a DECLARATIVE governed app, read-only + write actions is a
    /// SUPPORTED posture — the runtime blocks the write and records a blocked run for audit (a view
    /// with gated, deliberately-inert write actions). That pattern is tested and must stay valid.
    private static func validatePermissionConsistency(
        _ manifest: WorkspaceAppManifest,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard manifest.html != nil, manifest.permissions.defaultMode == .readOnly else { return }
        for (index, action) in manifest.actions.enumerated()
        where WorkspaceAppActionEffect.effect(for: action.type) != .read {
            issues.append(blocker(
                "/actions/\(index)",
                "Action '\(action.id)' (\(action.type)) writes data, but permissions.defaultMode is "
                    + "\"readOnly\" — its button would be denied at runtime and do nothing. An HTML app "
                    + "that adds, edits, or deletes its own records must set permissions.defaultMode to "
                    + "\"draftOnly\"."
            ))
        }
    }

    private static func validateRequirements(
        _ requirements: [WorkspaceAppRequirement],
        registry: WorkspaceAppContractRegistry,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        for (index, requirement) in requirements.enumerated() {
            let path = "/requirements/\(index)"
            validateUniqueIdentifier(
                requirement.id,
                path: "\(path)/id",
                label: "Requirement ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(requirement.contract, path: "\(path)/contract", label: "Contract", issues: &issues)
            if requirement.operations.isEmpty {
                issues.append(blocker("\(path)/operations", "Requirement must declare at least one operation."))
            }
            let contractOperations = registry.family(id: requirement.contract).map {
                Set($0.operations.map(\.name))
            }
            for (operationIndex, operation) in requirement.operations.enumerated() {
                validateIdentifier(
                    operation,
                    path: "\(path)/operations/\(operationIndex)",
                    label: "Operation",
                    issues: &issues
                )
                if let contractOperations, !contractOperations.contains(operation) {
                    issues.append(blocker(
                        "\(path)/operations/\(operationIndex)",
                        "Operation '\(operation)' is not supported by contract '\(requirement.contract)'. Use one of: \(contractOperations.sorted().joined(separator: ", "))."
                    ))
                }
            }
        }
        return seen
    }

    private static func validateStorage(
        _ storage: WorkspaceAppStorageSchema?,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> [String: Set<String>] {
        guard let storage else { return [:] }
        var tableNames = Set<String>()
        var tables: [String: Set<String>] = [:]
        for (tableIndex, table) in storage.tables.enumerated() {
            let tablePath = "/storage/tables/\(tableIndex)"
            validateUniqueIdentifier(
                table.name,
                path: "\(tablePath)/name",
                label: "Table name",
                seen: &tableNames,
                issues: &issues
            )
            if table.columns.isEmpty {
                issues.append(blocker("\(tablePath)/columns", "Storage table must declare at least one column."))
            }
            var columnNames = Set<String>()
            for (columnIndex, column) in table.columns.enumerated() {
                let columnPath = "\(tablePath)/columns/\(columnIndex)"
                validateUniqueIdentifier(
                    column.name,
                    path: "\(columnPath)/name",
                    label: "Column name",
                    seen: &columnNames,
                    issues: &issues
                )
                validateIdentifier(column.type, path: "\(columnPath)/type", label: "Column type", issues: &issues)
                // The type must be one the storage engine can map to SQLite — otherwise the manifest
                // validates but `applySchema` throws `unsupportedColumnType` at PUBLISH (the button
                // looks enabled, then silently fails). Block it here so the repair loop corrects it.
                if !column.type.isEmpty,
                   !WorkspaceAppStorageService.supportedColumnTypes.contains(column.type.lowercased()) {
                    issues.append(blocker(
                        "\(columnPath)/type",
                        "Unsupported column type '\(column.type)'. Use one of: text, integer, double, "
                            + "bool, date, datetime, uuid, json."
                    ))
                }
            }
            tables[table.name] = columnNames
        }
        return tables
    }

    private static func validateSources(
        _ sources: [WorkspaceAppSource],
        requirementIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        for (index, source) in sources.enumerated() {
            let path = "/sources/\(index)"
            validateUniqueIdentifier(
                source.id,
                path: "\(path)/id",
                label: "Source ID",
                seen: &seen,
                issues: &issues
            )
            if let requirementRef = source.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Source references unknown requirement '\(requirementRef)'."))
            }
        }
        return seen
    }

    private static func validateViews(
        _ views: [WorkspaceAppViewSpec],
        storageTables: [String: Set<String>],
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (viewIndex, view) in views.enumerated() {
            let path = "/views/\(viewIndex)"
            validateUniqueIdentifier(
                view.id,
                path: "\(path)/id",
                label: "View ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(view.type, path: "\(path)/type", label: "View type", issues: &issues)
            if let table = view.table {
                validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            }

            var widgetIDs = Set<String>()
            for (widgetIndex, widget) in view.widgets.enumerated() {
                let widgetPath = "\(path)/widgets/\(widgetIndex)"
                validateUniqueIdentifier(
                    widget.id,
                    path: "\(widgetPath)/id",
                    label: "Widget ID",
                    seen: &widgetIDs,
                    issues: &issues
                )
                validateIdentifier(widget.type, path: "\(widgetPath)/type", label: "Widget type", issues: &issues)
                if widget.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(blocker("\(widgetPath)/label", "Widget label is required."))
                }
                validateWidgetBinding(
                    widget,
                    path: widgetPath,
                    viewTable: view.table,
                    storageTables: storageTables,
                    actionIDs: actionIDs,
                    issues: &issues
                )
            }

            validateFormFields(view, path: path, storageTables: storageTables, issues: &issues)
        }
    }

    private static let allowedFormFieldTypes: Set<String> = [
        "text", "textarea", "number", "date", "choice", "multichoice", "yesno"
    ]

    private static func validateFormFields(
        _ view: WorkspaceAppViewSpec,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard !view.formFields.isEmpty else { return }
        let columns = view.table.flatMap { storageTables[$0] }
        var seenNames = Set<String>()
        for (index, field) in view.formFields.enumerated() {
            let fieldPath = "\(path)/formFields/\(index)"
            validateUniqueIdentifier(field.name, path: "\(fieldPath)/name", label: "Form field name", seen: &seenNames, issues: &issues)
            if field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(blocker("\(fieldPath)/label", "Form field label is required."))
            }
            if !allowedFormFieldTypes.contains(field.fieldType) {
                issues.append(blocker("\(fieldPath)/fieldType", "Form field type '\(field.fieldType)' is not supported."))
            }
            // Choice fields must declare a non-empty choice list.
            if field.fieldType == "choice" || field.fieldType == "multichoice" {
                if (field.choices ?? []).isEmpty {
                    issues.append(blocker("\(fieldPath)/choices", "Choice field '\(field.name)' must declare at least one choice."))
                }
            }
            // The field must back onto a real draft-table column (when the form declares a table).
            if let columns, !columns.contains(field.name) {
                issues.append(blocker("\(fieldPath)/name", "Form field '\(field.name)' has no matching column in table '\(view.table ?? "")'."))
            }
            // Branching the app cannot honor EXACTLY must never reach a published form.
            if let logic = field.visibleWhen, !logic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if case .unsupported(let reason) = WorkspaceAppREDCapBranchingAnalyzer.classify(logic) {
                    issues.append(blocker("\(fieldPath)/visibleWhen", "Unsupported branching logic for field '\(field.name)': \(reason)"))
                }
            }
        }
    }

    private static func validateWidgetBinding(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        viewTable: String?,
        storageTables: [String: Set<String>],
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let table = widget.table ?? viewTable
        switch widget.type {
        case "metric", "chart":
            guard let table else {
                issues.append(blocker("\(path)/table", "Storage-backed widget must reference a table."))
                return
            }
            validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            if let field = widget.field {
                validateStorageFieldReference(field, table: table, path: "\(path)/field", storageTables: storageTables, issues: &issues)
            }
            if let groupBy = widget.groupBy {
                validateStorageFieldReference(groupBy, table: table, path: "\(path)/groupBy", storageTables: storageTables, issues: &issues)
            }
            if widget.type == "chart", let chartKind = widget.chartKind,
               !["bar", "line", "pie"].contains(chartKind) {
                issues.append(blocker("\(path)/chartKind", "Chart kind '\(chartKind)' is not supported (use bar, line, or pie)."))
            }
        case "markdown":
            if widget.markdownContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/markdownContent", "Markdown widget content is required."))
            }
        case "diagram":
            validateDiagramWidget(widget, path: path, issues: &issues)
        case "webView":
            validateWebViewWidget(widget, path: path, actionIDs: actionIDs, issues: &issues)
        default:
            break
        }
    }

    private static func validateDiagramWidget(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if widget.diagramContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(blocker("\(path)/diagramContent", "Diagram widget content is required."))
        }
        let kind = widget.diagramKind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "flow"
        if !["flow", "pipeline", "entityRelationship"].contains(kind) {
            issues.append(blocker("\(path)/diagramKind", "Diagram kind '\(kind)' is not supported."))
        }
    }

    private static func validateWebViewWidget(
        _ widget: WorkspaceAppWidgetSpec,
        path: String,
        actionIDs: Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let renderer = widget.webRenderer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if renderer.isEmpty {
            issues.append(blocker("\(path)/webRenderer", "WebView widget must declare an ASTRA-known renderer."))
        } else if !WorkspaceAppWebViewBridge.allowedRenderers.contains(renderer) {
            issues.append(blocker("\(path)/webRenderer", "WebView renderer '\(renderer)' is not allowed for Workspace Apps."))
        }

        for (actionIndex, actionID) in widget.allowedActions.enumerated() {
            validateIdentifier(
                actionID,
                path: "\(path)/allowedActions/\(actionIndex)",
                label: "WebView allowed action",
                issues: &issues
            )
            if !actionIDs.contains(actionID) {
                issues.append(blocker("\(path)/allowedActions/\(actionIndex)", "WebView widget references unknown action '\(actionID)'."))
            }
        }

        for (assetIndex, asset) in widget.requiredAssets.enumerated() {
            if !isPortableAssetPath(asset) {
                issues.append(blocker("\(path)/requiredAssets/\(assetIndex)", "WebView asset path must be portable and relative."))
            }
        }
    }

    private static func validateStorageTableReference(
        _ table: String,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if storageTables[table] == nil {
            issues.append(blocker(path, "References unknown storage table '\(table)'."))
        }
    }

    private static func validateStorageFieldReference(
        _ field: String,
        table: String,
        path: String,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let columns = storageTables[table] else { return }
        if !columns.contains(field) {
            issues.append(blocker(path, "References unknown field '\(field)' on storage table '\(table)'."))
        }
    }

    private static func validateActions(
        _ actions: [WorkspaceAppActionSpec],
        requirementIDs: Set<String>,
        sourceIDs: Set<String>,
        storageTables: [String: Set<String>],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) -> Set<String> {
        var seen = Set<String>()
        var actionIDs = Set<String>()
        let actionsByID = Dictionary(actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, action) in actions.enumerated() {
            let path = "/actions/\(index)"
            validateUniqueIdentifier(
                action.id,
                path: "\(path)/id",
                label: "Action ID",
                seen: &seen,
                issues: &issues
            )
            if !action.id.isEmpty {
                actionIDs.insert(action.id)
            }
            validateIdentifier(action.type, path: "\(path)/type", label: "Action type", issues: &issues)
            if let requirementRef = action.requirementRef,
               !requirementIDs.contains(requirementRef) {
                issues.append(blocker("\(path)/requirementRef", "Action references unknown requirement '\(requirementRef)'."))
            }
            if let table = action.table {
                validateStorageTableReference(table, path: "\(path)/table", storageTables: storageTables, issues: &issues)
            }
            if action.type == "capability.read" {
                if action.sourceRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/sourceRef", "Capability read action must declare a source reference."))
                } else if let sourceRef = action.sourceRef,
                          !sourceIDs.contains(sourceRef) {
                    issues.append(blocker("\(path)/sourceRef", "Capability read action references unknown source '\(sourceRef)'."))
                }
            }
            if action.type == "capability.write" {
                if action.requirementRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/requirementRef", "Capability write action must declare a requirement reference."))
                } else if let requirementRef = action.requirementRef,
                          !requirementIDs.contains(requirementRef) {
                    issues.append(blocker("\(path)/requirementRef", "Capability write action references unknown requirement '\(requirementRef)'."))
                }
                if action.operation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/operation", "Capability write action must declare an operation."))
                }
            }
            if action.type == "artifact.export",
               let format = action.exportFormat?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !format.isEmpty,
               !["csv", "json"].contains(format) {
                issues.append(blocker("\(path)/exportFormat", "Artifact export format must be csv or json."))
            }
            if action.type == "url.open" {
                let targetURL = action.targetURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if targetURL.isEmpty {
                    issues.append(blocker("\(path)/targetURL", "URL open action must declare a target URL."))
                } else if let url = URL(string: targetURL),
                          let scheme = url.scheme?.lowercased(),
                          ["https", "http"].contains(scheme),
                          url.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    // URL is supported.
                } else {
                    issues.append(blocker("\(path)/targetURL", "URL open action must use an http or https URL."))
                }
            }
            if action.type == "clipboard.copy",
               action.clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/clipboardText", "Clipboard copy action must declare text to copy."))
            }
            if action.type == "notification.show" {
                let title = action.notificationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let body = action.notificationBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if title.isEmpty && body.isEmpty {
                    issues.append(blocker("\(path)/notificationTitle", "Notification action must declare a title or body."))
                }
            }
            if ["task.createDraft", "task.createAndRun"].contains(action.type),
               action.taskGoal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                issues.append(blocker("\(path)/taskGoal", "Task action must declare a task goal."))
            }
            if action.type == "gate.humanApproval" {
                if action.approvalPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/approvalPrompt", "Human approval gate must declare an approval prompt."))
                }
                if action.approvalDecisions.isEmpty {
                    issues.append(blocker("\(path)/approvalDecisions", "Human approval gate must declare available decisions."))
                }
                for (decisionIndex, decision) in action.approvalDecisions.enumerated() {
                    validateIdentifier(
                        decision,
                        path: "\(path)/approvalDecisions/\(decisionIndex)",
                        label: "Approval decision",
                        issues: &issues
                    )
                }
            }
            if action.type == "gate.expression" {
                if action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    issues.append(blocker("\(path)/gateField", "Expression gate must declare a field to evaluate."))
                }
                let normalizedOperator = action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if normalizedOperator.isEmpty {
                    issues.append(blocker("\(path)/gateOperator", "Expression gate must declare an operator."))
                } else if !WorkspaceAppExpressionGateOperator.allRawValues.contains(normalizedOperator) {
                    issues.append(blocker("\(path)/gateOperator", "Expression gate operator '\(normalizedOperator)' is not supported."))
                }
                if WorkspaceAppExpressionGateOperator.requiresExpectedValue(normalizedOperator),
                   action.gateValue == nil {
                    issues.append(blocker("\(path)/gateValue", "Expression gate operator '\(normalizedOperator)' must declare a comparison value."))
                }
            }
            if action.type == "gate.agentRecommendation" {
                validateAgentRecommendationGate(action, path: path, issues: &issues)
            }
            if action.type == "rows.reduce" {
                validateReduceAction(action, path: path, issues: &issues)
            }
            if action.type == "gate.branch" {
                validateBranchAction(action, actionsByID: actionsByID, path: path, issues: &issues)
            }
            if action.type == "task.fanOut" {
                validateFanOutAction(action, actionsByID: actionsByID, path: path, issues: &issues)
            }
            validateActionBindings(action, storageTables: storageTables, path: path, issues: &issues)
        }

        for (index, action) in actions.enumerated() where action.type == "pipeline.run" || action.type == "loop.run" || action.type == "gate.branch" {
            let path = "/actions/\(index)"
            if action.steps.isEmpty {
                issues.append(blocker("\(path)/steps", "\(action.type == "loop.run" ? "Loop" : "Pipeline") action must declare at least one step."))
            }
            for (stepIndex, stepID) in action.steps.enumerated() {
                let stepPath = "\(path)/steps/\(stepIndex)"
                validateIdentifier(stepID, path: stepPath, label: "Pipeline step action ID", issues: &issues)
                if stepID == action.id {
                    issues.append(blocker(stepPath, "\(action.type == "loop.run" ? "Loop" : "Pipeline") action cannot include itself as a step."))
                } else if !actionIDs.contains(stepID) {
                    issues.append(blocker(stepPath, "\(action.type == "loop.run" ? "Loop" : "Pipeline") step references unknown action '\(stepID)'."))
                }
                // task.fanOut suspends on a barrier and is only resumable as a direct
                // pipeline.run step; a loop cannot suspend/resume mid-iteration.
                if action.type == "loop.run", actionsByID[stepID]?.type == "task.fanOut" {
                    issues.append(blocker(stepPath, "Loop step '\(stepID)' is a task.fanOut, which is only supported as a direct pipeline step."))
                }
            }
            if action.type == "loop.run" {
                validateLoopAction(action, path: path, issues: &issues)
            }
        }
        validateCompositeActionCycles(actions, issues: &issues)
        return actionIDs
    }

    /// Slice 10: validate workflow I/O bindings — input must read app-owned data (boundRows or a real
    /// local table), and a captured output that persists must target a real column. Keeps the
    /// app⇄agent dataflow honest before it can publish.
    private static func validateActionBindings(
        _ action: WorkspaceAppActionSpec,
        storageTables: [String: Set<String>],
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if let inputBinding = action.inputBinding {
            if !["boundRows", "table"].contains(inputBinding.source) {
                issues.append(blocker("\(path)/inputBinding/source", "Input binding source must be 'boundRows' or 'table'."))
            }
            if inputBinding.source == "table" {
                let table = inputBinding.table?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if table.isEmpty {
                    issues.append(blocker("\(path)/inputBinding/table", "Input binding with source 'table' must name a storage table."))
                } else if storageTables[table] == nil {
                    issues.append(blocker("\(path)/inputBinding/table", "Input binding references unknown storage table '\(table)'."))
                }
            }
        }

        if let outputBinding = action.outputBinding {
            let field = outputBinding.field.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.isEmpty {
                issues.append(blocker("\(path)/outputBinding/field", "Output binding must declare a field to capture the result into."))
            }
            if let capture = outputBinding.capture, !["text", "json"].contains(capture) {
                issues.append(blocker("\(path)/outputBinding/capture", "Output binding capture must be 'text' or 'json'."))
            }
            if let table = outputBinding.table?.trimmingCharacters(in: .whitespacesAndNewlines), !table.isEmpty {
                if let columns = storageTables[table] {
                    if !field.isEmpty && !columns.contains(field) {
                        issues.append(blocker("\(path)/outputBinding/field", "Output binding field '\(field)' is not a column of storage table '\(table)'."))
                    }
                } else {
                    issues.append(blocker("\(path)/outputBinding/table", "Output binding references unknown storage table '\(table)'."))
                }
            }
        }
    }

    private static func validateCompositeActionCycles(
        _ actions: [WorkspaceAppActionSpec],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        let actionIndexes = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($0.element.id, $0.offset) })

        for action in actions where isCompositeAction(action) {
            guard let actionIndex = actionIndexes[action.id] else { continue }
            for (stepIndex, stepID) in action.steps.enumerated() where stepID != action.id {
                if compositeAction(stepID, reaches: action.id, actionsByID: actionsByID, visited: []) {
                    issues.append(blocker(
                        "/actions/\(actionIndex)/steps/\(stepIndex)",
                        "Workflow step introduces a cycle back to action '\(action.id)'."
                    ))
                }
            }
        }
    }

    private static func compositeAction(
        _ actionID: String,
        reaches targetID: String,
        actionsByID: [String: WorkspaceAppActionSpec],
        visited: Set<String>
    ) -> Bool {
        guard !visited.contains(actionID),
              let action = actionsByID[actionID],
              isCompositeAction(action) else {
            return false
        }
        let edges = compositeEdges(action)
        if edges.contains(targetID) {
            return true
        }
        var visited = visited
        visited.insert(actionID)
        return edges.contains {
            compositeAction($0, reaches: targetID, actionsByID: actionsByID, visited: visited)
        }
    }

    private static func isCompositeAction(_ action: WorkspaceAppActionSpec) -> Bool {
        action.type == "pipeline.run" || action.type == "loop.run"
            || action.type == "gate.branch" || action.type == "task.fanOut"
    }

    // The child action ids a composite action can reach: its steps plus a fan-out's
    // single child template.
    private static func compositeEdges(_ action: WorkspaceAppActionSpec) -> [String] {
        action.steps + (action.fanOutStep.map { [$0] } ?? [])
    }

    // True if `actionID` is, or can transitively reach, an async task action
    // (task.createAndRun / task.fanOut). A gate.branch target runs inline and must
    // never be able to suspend, so its whole reachable subtree must be async-free.
    private static func reachesAsyncTask(
        _ actionID: String,
        actionsByID: [String: WorkspaceAppActionSpec],
        visited: Set<String>
    ) -> Bool {
        guard !visited.contains(actionID), let action = actionsByID[actionID] else { return false }
        if action.type == "task.createAndRun" || action.type == "task.fanOut" { return true }
        guard isCompositeAction(action) else { return false }
        var visited = visited
        visited.insert(actionID)
        return compositeEdges(action).contains {
            reachesAsyncTask($0, actionsByID: actionsByID, visited: visited)
        }
    }

    private static func validateFanOutAction(
        _ action: WorkspaceAppActionSpec,
        actionsByID: [String: WorkspaceAppActionSpec],
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let child = action.fanOutStep?.trimmingCharacters(in: .whitespacesAndNewlines), !child.isEmpty else {
            issues.append(blocker("\(path)/fanOutStep", "Fan-out action must declare a child task step."))
            return
        }
        validateIdentifier(child, path: "\(path)/fanOutStep", label: "Fan-out child action ID", issues: &issues)
        if child == action.id {
            issues.append(blocker("\(path)/fanOutStep", "Fan-out action cannot reference itself."))
        } else if let childAction = actionsByID[child] {
            if childAction.type != "task.createAndRun" {
                issues.append(blocker("\(path)/fanOutStep", "Fan-out child '\(child)' must be a task.createAndRun action."))
            }
        } else {
            issues.append(blocker("\(path)/fanOutStep", "Fan-out child references unknown action '\(child)'."))
        }
    }

    private static func validateBranchAction(
        _ action: WorkspaceAppActionSpec,
        actionsByID: [String: WorkspaceAppActionSpec],
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        // Predicate reuses the expression-gate operator vocabulary.
        let field = action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if field.isEmpty {
            issues.append(blocker("\(path)/gateField", "Branch action must declare a field to evaluate."))
        }
        let op = action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if op.isEmpty {
            issues.append(blocker("\(path)/gateOperator", "Branch action must declare an operator."))
        } else if !WorkspaceAppExpressionGateOperator.allRawValues.contains(op) {
            issues.append(blocker("\(path)/gateOperator", "Branch operator '\(op)' is not supported."))
        } else if WorkspaceAppExpressionGateOperator.requiresExpectedValue(op), action.gateValue == nil {
            issues.append(blocker("\(path)/gateValue", "Branch operator '\(op)' must declare a comparison value."))
        }
        // Targets: at least one of then/else, each a known non-async action listed in steps.
        if action.thenStep == nil && action.elseStep == nil {
            issues.append(blocker("\(path)/thenStep", "Branch action must declare a thenStep or elseStep."))
        }
        for (key, target) in [("thenStep", action.thenStep), ("elseStep", action.elseStep)] {
            guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else { continue }
            if target == action.id {
                issues.append(blocker("\(path)/\(key)", "Branch action cannot target itself."))
            } else if !action.steps.contains(target) {
                issues.append(blocker("\(path)/\(key)", "Branch target '\(target)' must also be listed in steps."))
            }
            if reachesAsyncTask(target, actionsByID: actionsByID, visited: []) {
                issues.append(blocker("\(path)/\(key)", "Branch cannot target an action that can launch an async task ('\(target)') in this version."))
            }
        }
    }

    private static func validateReduceAction(
        _ action: WorkspaceAppActionSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let strategy = action.reduceStrategy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let supported = ["count", "sum", "concat", "first", "last"]
        if strategy.isEmpty {
            issues.append(blocker("\(path)/reduceStrategy", "Reduce action must declare a strategy."))
        } else if !supported.contains(strategy) {
            issues.append(blocker("\(path)/reduceStrategy", "Reduce strategy '\(strategy)' is not supported."))
        }
        // `count` can fold without a column; every other strategy folds a specific column.
        if strategy != "count" {
            let column = action.reduceColumn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if column.isEmpty {
                issues.append(blocker("\(path)/reduceColumn", "Reduce strategy '\(strategy)' must declare a column to fold over."))
            } else {
                validateIdentifier(column, path: "\(path)/reduceColumn", label: "Reduce column", issues: &issues)
            }
        }
    }

    private static func validateLoopAction(
        _ action: WorkspaceAppActionSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if (action.maxIterations ?? 0) <= 0 {
            issues.append(blocker("\(path)/maxIterations", "Loop action must declare a positive maximum iteration count."))
        }
        if (action.timeoutSeconds ?? 0) <= 0 {
            issues.append(blocker("\(path)/timeoutSeconds", "Loop action must declare a positive timeout."))
        }
        if let delaySeconds = action.delaySeconds, delaySeconds < 0 {
            issues.append(blocker("\(path)/delaySeconds", "Loop action delay cannot be negative."))
        }
        if action.gateField?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(blocker("\(path)/gateField", "Loop action must declare a stop-condition field."))
        }
        let normalizedOperator = action.gateOperator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedOperator.isEmpty {
            issues.append(blocker("\(path)/gateOperator", "Loop action must declare a stop-condition operator."))
        } else if !WorkspaceAppExpressionGateOperator.allRawValues.contains(normalizedOperator) {
            issues.append(blocker("\(path)/gateOperator", "Loop stop-condition operator '\(normalizedOperator)' is not supported."))
        }
        if WorkspaceAppExpressionGateOperator.requiresExpectedValue(normalizedOperator),
           action.gateValue == nil {
            issues.append(blocker("\(path)/gateValue", "Loop stop-condition operator '\(normalizedOperator)' must declare a comparison value."))
        }
    }

    private static func validateAgentRecommendationGate(
        _ action: WorkspaceAppActionSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if action.agentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(blocker("\(path)/agentPrompt", "Agent recommendation gate must declare an agent prompt."))
        }
        if action.agentDecisions.isEmpty {
            issues.append(blocker("\(path)/agentDecisions", "Agent recommendation gate must declare available decisions."))
        }
        for (decisionIndex, decision) in action.agentDecisions.enumerated() {
            validateIdentifier(
                decision,
                path: "\(path)/agentDecisions/\(decisionIndex)",
                label: "Agent recommendation decision",
                issues: &issues
            )
        }
        for (bindingIndex, binding) in action.agentInputBindings.enumerated() {
            validateIdentifier(
                binding,
                path: "\(path)/agentInputBindings/\(bindingIndex)",
                label: "Agent recommendation input binding",
                issues: &issues
            )
        }
        let policyMode = action.agentPolicyMode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if policyMode.isEmpty {
            issues.append(blocker("\(path)/agentPolicyMode", "Agent recommendation gate must declare a policy mode."))
        } else if !["advisory", "blocking", "approvalRequired"].contains(policyMode) {
            issues.append(blocker("\(path)/agentPolicyMode", "Agent recommendation policy mode '\(policyMode)' is not supported."))
        }
        if let tokenBudget = action.agentTokenBudget {
            if tokenBudget <= 0 {
                issues.append(blocker("\(path)/agentTokenBudget", "Agent recommendation token budget must be positive."))
            }
        } else {
            issues.append(blocker("\(path)/agentTokenBudget", "Agent recommendation gate must declare a token budget."))
        }
    }

    private static func validateAutomations(
        _ automations: [WorkspaceAppAutomationSpec],
        actionIDs: Set<String>,
        actionsByID: [String: WorkspaceAppActionSpec],
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        var seen = Set<String>()
        for (index, automation) in automations.enumerated() {
            let path = "/automations/\(index)"
            validateUniqueIdentifier(
                automation.id,
                path: "\(path)/id",
                label: "Automation ID",
                seen: &seen,
                issues: &issues
            )
            validateIdentifier(automation.type, path: "\(path)/type", label: "Automation type", issues: &issues)
            if automation.enabledByDefault {
                issues.append(blocker("\(path)/enabledByDefault", "Imported or generated automations must default disabled."))
            }
            if let action = automation.action {
                if !actionIDs.contains(action) {
                    issues.append(blocker("\(path)/action", "Automation references unknown action '\(action)'."))
                } else if actionsByID[action]?.type == "task.fanOut" {
                    issues.append(blocker("\(path)/action", "Automation cannot run a task.fanOut directly; it is only supported as a pipeline step."))
                }
            }
            validateAutomationSchedule(automation, path: path, issues: &issues)
        }
    }

    private static func validateAutomationSchedule(
        _ automation: WorkspaceAppAutomationSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard automation.type == "schedule" || automation.type == "monitor" else { return }
        guard let scheduleType = automation.scheduleType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scheduleType.isEmpty else {
            return
        }
        switch scheduleType {
        case "interval":
            if (automation.intervalSeconds ?? 0) <= 0 {
                issues.append(blocker("\(path)/intervalSeconds", "Interval automation must declare positive interval seconds."))
            }
        case "daily":
            validateHourMinute(automation, path: path, issues: &issues)
        case "weekly":
            validateHourMinute(automation, path: path, issues: &issues)
            guard let weekday = automation.weeklyDayOfWeek, (1...7).contains(weekday) else {
                issues.append(blocker("\(path)/weeklyDayOfWeek", "Weekly automation day must be 1 through 7."))
                return
            }
        default:
            issues.append(blocker("\(path)/scheduleType", "Automation schedule type '\(scheduleType)' is not supported."))
        }
    }

    private static func validateHourMinute(
        _ automation: WorkspaceAppAutomationSpec,
        path: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        guard let hour = automation.dailyHour, (0...23).contains(hour) else {
            issues.append(blocker("\(path)/dailyHour", "Scheduled automation hour must be 0 through 23."))
            return
        }
        guard let minute = automation.dailyMinute, (0...59).contains(minute) else {
            issues.append(blocker("\(path)/dailyMinute", "Scheduled automation minute must be 0 through 59."))
            return
        }
    }

    private static func validatePermissions(
        _ permissions: WorkspaceAppPermissions,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        if !permissions.externalWrites.isEmpty,
           permissions.defaultMode == .readOnly || permissions.defaultMode == .draftOnly {
            issues.append(warning(
                "/permissions/defaultMode",
                "External writes are declared but the default mode prevents submitting them."
            ))
        }
    }

    /// Cross-check the DECLARED permission surface against what the app's capability actions and
    /// sources ACTUALLY touch, so the two can't drift apart: a capability-bound source's contract
    /// should appear in `permissions.reads`, and a `capability.write` action's contract should
    /// appear in `permissions.writes` — or in `permissions.externalWrites` for an external-write
    /// operation, classified via the contract registry's per-operation effects.
    ///
    /// Emitted as WARNINGS, not blockers: the runtime enforces capability access by
    /// `app.permissionMode` + the action's effect (see `WorkspaceAppActionExecutor.enforcePermission`),
    /// NOT by these declarative lists, so a missing entry is a surface-mismatch the author/reviewer
    /// should see — not a runtime hole. It keeps the up-front "what can this app reach" declaration
    /// honest about the actual action surface.
    private static func validatePermissionCoverage(
        _ manifest: WorkspaceAppManifest,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let contractByRequirement = Dictionary(
            manifest.requirements.map { ($0.id, $0.contract) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !contractByRequirement.isEmpty else { return }

        let reads = Set(manifest.permissions.reads)
        let writes = Set(manifest.permissions.writes)
        let externalWrites = Set(manifest.permissions.externalWrites)
        let registry = WorkspaceAppContractRegistry()

        // A capability-bound source reads its requirement's contract.
        for (index, source) in manifest.sources.enumerated() {
            guard let requirementRef = source.requirementRef,
                  let contract = contractByRequirement[requirementRef] else { continue }
            if !reads.contains(contract) {
                issues.append(warning(
                    "/sources/\(index)/requirementRef",
                    "Source '\(source.id)' reads capability '\(contract)' but it is not declared in permissions.reads — declare it so the permission surface matches what the app reads."
                ))
            }
        }

        // A capability.write action writes its requirement's contract; the operation's effect
        // (from the registry) decides whether it belongs in writes or externalWrites.
        for (index, action) in manifest.actions.enumerated() where action.type == "capability.write" {
            guard let requirementRef = action.requirementRef,
                  let contract = contractByRequirement[requirementRef] else { continue }
            let effect = action.operation.flatMap { operation in
                registry.family(id: contract)?.operations.first { $0.name == operation }?.effect
            }
            if effect == .externalWrite {
                if !externalWrites.contains(contract) {
                    issues.append(warning(
                        "/actions/\(index)/requirementRef",
                        "Action '\(action.label ?? action.id)' performs an external write to '\(contract)' but it is not declared in permissions.externalWrites — declare it so governed external writes are visible before publishing."
                    ))
                }
            } else if !writes.contains(contract) && !externalWrites.contains(contract) {
                issues.append(warning(
                    "/actions/\(index)/requirementRef",
                    "Action '\(action.label ?? action.id)' writes capability '\(contract)' but it is not declared in permissions.writes — declare it so the permission surface matches what the app writes."
                ))
            }
        }
    }

    private static func validateUniqueIdentifier(
        _ value: String,
        path: String,
        label: String,
        seen: inout Set<String>,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        validateIdentifier(value, path: path, label: label, issues: &issues)
        guard !value.isEmpty else { return }
        if !seen.insert(value).inserted {
            issues.append(blocker(path, "\(label) '\(value)' is duplicated."))
        }
    }

    private static func validateIdentifier(
        _ value: String,
        path: String,
        label: String,
        issues: inout [WorkspaceAppManifestValidationReport.Issue]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            issues.append(blocker(path, "\(label) is required."))
            return
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if trimmed.rangeOfCharacter(from: allowed.inverted) != nil {
            issues.append(blocker(path, "\(label) may contain only letters, numbers, dot, underscore, or hyphen."))
        }
    }

    private static func isPortableAssetPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.contains("..")
            && !path.contains("\\")
    }

    private static func blocker(_ path: String, _ message: String) -> WorkspaceAppManifestValidationReport.Issue {
        WorkspaceAppManifestValidationReport.Issue(severity: .blocker, path: path, message: message)
    }

    private static func warning(_ path: String, _ message: String) -> WorkspaceAppManifestValidationReport.Issue {
        WorkspaceAppManifestValidationReport.Issue(severity: .warning, path: path, message: message)
    }
}
