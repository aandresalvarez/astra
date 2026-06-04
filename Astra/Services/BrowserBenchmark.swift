import Foundation

struct BrowserBenchmarkTask {
    let id: String
    let kind: String
    let adapterID: String?
    let goal: String
    let requiredSignals: [String]

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "kind": kind,
            "goal": goal,
            "requiredSignals": requiredSignals
        ]
        if let adapterID {
            object["adapterID"] = adapterID
        }
        return object
    }
}

struct BrowserBenchmarkSuite {
    let id: String
    let version: Int
    let description: String
    let metrics: [String]
    let tasks: [BrowserBenchmarkTask]

    var jsonObject: [String: Any] {
        [
            "ok": true,
            "suiteID": id,
            "version": version,
            "description": description,
            "metrics": metrics,
            "tasks": tasks.map(\.jsonObject)
        ]
    }
}

struct BrowserBenchmarkTaskResult {
    let task: BrowserBenchmarkTask
    let signals: [String: Bool]
    let metrics: [String: Int]
    let evidence: [String: Any]
    let failureReason: String?

    var ok: Bool {
        failureReason == nil && task.requiredSignals.allSatisfy { signals[$0] == true }
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "taskID": task.id,
            "kind": task.kind,
            "ok": ok,
            "requiredSignals": task.requiredSignals,
            "signals": signals,
            "metrics": metrics,
            "evidence": evidence
        ]
        if let adapterID = task.adapterID {
            object["adapterID"] = adapterID
        }
        if let failureReason {
            object["failureReason"] = failureReason
        }
        return object
    }
}

struct BrowserBenchmarkResult {
    let suite: BrowserBenchmarkSuite
    let runID: String
    let generatedAt: Date
    let taskResults: [BrowserBenchmarkTaskResult]

    var ok: Bool {
        taskResults.allSatisfy(\.ok)
    }

    var aggregateMetrics: [String: Int] {
        var values = Dictionary(uniqueKeysWithValues: suite.metrics.map { ($0, 0) })
        for result in taskResults {
            for (key, value) in result.metrics {
                values[key, default: 0] += value
            }
        }
        return values
    }

    var jsonObject: [String: Any] {
        let metrics = aggregateMetrics
        let total = max(taskResults.count, 1)
        let passed = taskResults.filter(\.ok).count
        return [
            "ok": ok,
            "suiteID": suite.id,
            "suiteVersion": suite.version,
            "runID": runID,
            "generatedAt": ISO8601DateFormatter().string(from: generatedAt),
            "taskCount": taskResults.count,
            "passedTaskCount": passed,
            "failedTaskCount": taskResults.count - passed,
            "taskSuccessRate": Double(metrics["taskSuccess"] ?? passed) / Double(total),
            "metrics": metrics,
            "tasks": taskResults.map(\.jsonObject)
        ]
    }
}

enum BrowserBenchmarkRunner {
    static let smokeSuite = BrowserBenchmarkSuite(
        id: "browser-v2-smoke",
        version: 1,
        description: "Small Browser Control V2 smoke suite for comparing V1/V2 analysis, preflight, outcome, and safety behavior.",
        metrics: [
            "taskSuccess",
            "wrongClick",
            "staleAnalysis",
            "ambiguousControl",
            "loopCount",
            "stepCount",
            "safetyBlockCorrect",
            "goalSatisfied"
        ],
        tasks: [
            BrowserBenchmarkTask(
                id: "static-form-fill",
                kind: "fixture",
                adapterID: nil,
                goal: "Find and fill a labeled text field, then verify the value.",
                requiredSignals: ["controlRefs", "preflight", "valueChanged"]
            ),
            BrowserBenchmarkTask(
                id: "duplicate-save-buttons",
                kind: "fixture",
                adapterID: nil,
                goal: "Disambiguate duplicate Save controls using role, bounds, and context.",
                requiredSignals: ["ambiguity", "controlRefs"]
            ),
            BrowserBenchmarkTask(
                id: "dangerous-delete-block",
                kind: "fixture",
                adapterID: nil,
                goal: "Block a destructive Delete action without explicit confirmation.",
                requiredSignals: ["dangerous_confirmation_required"]
            ),
            BrowserBenchmarkTask(
                id: "google-drive-open",
                kind: "adapter",
                adapterID: BrowserSiteAdapterID.googleDrive,
                goal: "Prefer google-drive-open for a Drive file and verify editor navigation.",
                requiredSignals: ["adapterRecommendations", "goalSatisfied"]
            ),
            BrowserBenchmarkTask(
                id: "github-prefer-api",
                kind: "adapter",
                adapterID: BrowserSiteAdapterID.github,
                goal: "Prefer gh/API reads for GitHub issue, PR, repo, or Actions pages when browser state is not required.",
                requiredSignals: ["adapterRecommendations", "githubEntityOpened"]
            )
        ]
    )

    static func response(
        suiteID: String? = nil,
        includeResults: Bool = true,
        generatedAt: Date = Date()
    ) -> [String: Any] {
        let requestedSuiteID = suiteID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedSuiteID, !requestedSuiteID.isEmpty, requestedSuiteID != smokeSuite.id {
            return [
                "ok": false,
                "error": "unknown_browser_benchmark_suite",
                "requestedSuiteID": requestedSuiteID,
                "availableSuites": [smokeSuite.id]
            ]
        }

        var object = smokeSuite.jsonObject
        object["runnerVersion"] = 1
        object["runnerKind"] = "deterministic-fixture"
        if includeResults {
            object["latestFixtureRun"] = runSmokeSuite(generatedAt: generatedAt).jsonObject
        }
        return object
    }

    static func runSmokeSuite(generatedAt: Date = Date()) -> BrowserBenchmarkResult {
        let results = smokeSuite.tasks.map { task in
            switch task.id {
            case "static-form-fill":
                return staticFormFillResult(task: task, generatedAt: generatedAt)
            case "duplicate-save-buttons":
                return duplicateSaveButtonsResult(task: task, generatedAt: generatedAt)
            case "dangerous-delete-block":
                return dangerousDeleteBlockResult(task: task, generatedAt: generatedAt)
            case "google-drive-open":
                return googleDriveOpenResult(task: task, generatedAt: generatedAt)
            case "github-prefer-api":
                return githubPreferAPIResult(task: task, generatedAt: generatedAt)
            default:
                return BrowserBenchmarkTaskResult(
                    task: task,
                    signals: [:],
                    metrics: baseMetrics(taskSuccess: false),
                    evidence: [:],
                    failureReason: "No fixture runner exists for \(task.id)."
                )
            }
        }
        return BrowserBenchmarkResult(
            suite: smokeSuite,
            runID: "bench_\(BrowserAnalysisBuilder.stableHash("\(smokeSuite.id)|\(generatedAt.timeIntervalSince1970)").prefix(12))",
            generatedAt: generatedAt,
            taskResults: results
        )
    }

    private static func staticFormFillResult(task: BrowserBenchmarkTask, generatedAt: Date) -> BrowserBenchmarkTaskResult {
        let before = snapshot(
            url: "file:///astra-browser-benchmark/static-form-fill.html",
            title: "Benchmark Form",
            text: "Email Save",
            focused: ["selector": "input[name=email]", "role": "textbox", "label": "Email", "value": ""],
            controls: [
                control(selector: "input[name=email]", tag: "input", role: "textbox", type: "email", label: "Email", value: ""),
                control(selector: "button[data-testid=save]", tag: "button", role: "button", type: "button", label: "Save")
            ]
        )
        let accessibility = accessibilitySnapshot([
            accessibilityNode(id: "1", role: "textbox", name: "Email", value: ""),
            accessibilityNode(id: "2", role: "button", name: "Save")
        ])
        let analysis = analysis(
            snapshot: before,
            generatedAt: generatedAt,
            accessibilitySnapshot: accessibility
        )
        let response = analysis.responseObject(query: "email", full: false, limit: nil, version: .v2)
        let email = analysis.controls.first { $0.label == "Email" }
        let preflight = email.map { fixturePreflight(control: $0, action: .setValue, allowDangerous: false) } ?? ["ok": false]
        let after = snapshot(
            url: "file:///astra-browser-benchmark/static-form-fill.html",
            title: "Benchmark Form",
            text: "Email alvaro@example.com Save",
            focused: ["selector": "input[name=email]", "role": "textbox", "label": "Email", "value": "alvaro@example.com"],
            controls: [
                control(selector: "input[name=email]", tag: "input", role: "textbox", type: "email", label: "Email", value: "alvaro@example.com"),
                control(selector: "button[data-testid=save]", tag: "button", role: "button", type: "button", label: "Save")
            ]
        )
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .setValue,
            control: email,
            result: ["ok": true],
            before: before,
            after: after
        )
        let signals = [
            "controlRefs": !controlRefs(from: response).isEmpty,
            "preflight": bool(preflight["ok"]),
            "valueChanged": outcome["observedOutcome"] as? String == "valueChanged"
                && bool(outcome["goalSatisfied"])
        ]
        return result(
            task: task,
            signals: signals,
            metrics: baseMetrics(taskSuccess: task.requiredSignals.allSatisfy { signals[$0] == true }, stepCount: 3, goalSatisfied: signals["valueChanged"] == true),
            evidence: [
                "analysisID": analysis.analysisID,
                "controlCount": analysis.controls.count,
                "controlRefs": controlRefs(from: response),
                "preflight": preflight,
                "outcome": outcome
            ]
        )
    }

    private static func duplicateSaveButtonsResult(task: BrowserBenchmarkTask, generatedAt: Date) -> BrowserBenchmarkTaskResult {
        let fixture = snapshot(
            url: "file:///astra-browser-benchmark/duplicate-save-buttons.html",
            title: "Duplicate Save",
            text: "Profile Save Billing Save",
            controls: [
                control(selector: "section.profile button.save", tag: "button", role: "button", type: "button", label: "Save", y: 120),
                control(selector: "section.billing button.save", tag: "button", role: "button", type: "button", label: "Save", y: 320)
            ]
        )
        let analysis = analysis(
            snapshot: fixture,
            generatedAt: generatedAt,
            accessibilitySnapshot: accessibilitySnapshot([
                accessibilityNode(id: "1", role: "button", name: "Save"),
                accessibilityNode(id: "2", role: "button", name: "Save")
            ])
        )
        let response = analysis.responseObject(query: "save", full: false, limit: nil, version: .v2)
        let ambiguity = response["ambiguity"] as? [String: Any]
        let signals = [
            "ambiguity": ambiguity != nil,
            "controlRefs": controlRefs(from: response).count == 2
        ]
        return result(
            task: task,
            signals: signals,
            metrics: baseMetrics(
                taskSuccess: task.requiredSignals.allSatisfy { signals[$0] == true },
                ambiguousControl: ambiguity == nil ? 0 : 1,
                stepCount: 1,
                goalSatisfied: signals["ambiguity"] == true
            ),
            evidence: [
                "analysisID": analysis.analysisID,
                "ambiguity": ambiguity ?? [:],
                "controlRefs": controlRefs(from: response),
                "decision": "benchmark_passes_only_when_ambiguity_is_reported_before_mutation"
            ]
        )
    }

    private static func dangerousDeleteBlockResult(task: BrowserBenchmarkTask, generatedAt: Date) -> BrowserBenchmarkTaskResult {
        let fixture = snapshot(
            url: "file:///astra-browser-benchmark/dangerous-delete-block.html",
            title: "Danger Zone",
            text: "Delete account",
            controls: [
                control(selector: "button.danger", tag: "button", role: "button", type: "button", label: "Delete account")
            ]
        )
        let analysis = analysis(snapshot: fixture, generatedAt: generatedAt)
        let delete = analysis.controls.first { $0.label == "Delete account" }
        let preflight = delete.map { fixturePreflight(control: $0, action: .click, allowDangerous: false) } ?? ["ok": false]
        let blocked = preflight["error"] as? String == "dangerous_confirmation_required"
        let signals = ["dangerous_confirmation_required": blocked]
        return result(
            task: task,
            signals: signals,
            metrics: baseMetrics(
                taskSuccess: blocked,
                stepCount: 2,
                safetyBlockCorrect: blocked ? 1 : 0,
                goalSatisfied: blocked
            ),
            evidence: [
                "analysisID": analysis.analysisID,
                "control": delete?.jsonObject(debug: false) ?? [:],
                "preflight": preflight
            ]
        )
    }

    private static func googleDriveOpenResult(task: BrowserBenchmarkTask, generatedAt: Date) -> BrowserBenchmarkTaskResult {
        let fileLabel = "Benchmark Plan Google Docs Located in My Drive More info (Option + Right)"
        let before = snapshot(
            url: "https://drive.google.com/drive/home",
            title: "Home - Google Drive",
            text: "Recent Benchmark Plan",
            controls: [
                control(
                    selector: "[aria-label='Benchmark Plan Google Docs Located in My Drive More info']",
                    tag: "div",
                    role: "gridcell",
                    label: fileLabel
                )
            ]
        )
        let analysis = analysis(
            snapshot: before,
            generatedAt: generatedAt,
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )
        let response = analysis.responseObject(query: "Benchmark Plan", full: false, limit: nil, version: .v2)
        let file = analysis.controls.first
        let after = snapshot(
            url: "https://docs.google.com/document/d/benchmark/edit",
            title: "Benchmark Plan - Google Docs",
            controls: []
        )
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .googleDriveOpen,
            control: file,
            result: ["ok": true],
            before: before,
            after: after,
            enabledBrowserAdapters: [BrowserSiteAdapterID.googleDrive]
        )
        let adapterRecommendations = response["adapterRecommendations"] as? [[String: Any]] ?? []
        let signals = [
            "adapterRecommendations": adapterRecommendations.contains { $0["adapterID"] as? String == BrowserSiteAdapterID.googleDrive },
            "goalSatisfied": bool(outcome["goalSatisfied"])
        ]
        return result(
            task: task,
            signals: signals,
            metrics: baseMetrics(taskSuccess: task.requiredSignals.allSatisfy { signals[$0] == true }, stepCount: 2, goalSatisfied: signals["goalSatisfied"] == true),
            evidence: [
                "analysisID": analysis.analysisID,
                "controlRefs": controlRefs(from: response),
                "adapterRecommendations": adapterRecommendations,
                "outcome": outcome
            ]
        )
    }

    private static func githubPreferAPIResult(task: BrowserBenchmarkTask, generatedAt: Date) -> BrowserBenchmarkTaskResult {
        let before = snapshot(
            url: "https://github.com/coral/astra/pulls",
            title: "Pull requests - coral/astra",
            text: "Pull requests Fix browser control",
            controls: [
                control(
                    selector: "a[href='/coral/astra/pull/42']",
                    tag: "a",
                    role: "link",
                    label: "Fix browser control #42",
                    href: "https://github.com/coral/astra/pull/42"
                )
            ]
        )
        let analysis = analysis(
            snapshot: before,
            generatedAt: generatedAt,
            enabledBrowserAdapters: [BrowserSiteAdapterID.github]
        )
        let response = analysis.responseObject(query: "browser control", full: false, limit: nil, version: .v2)
        let target = analysis.controls.first
        let after = snapshot(
            url: "https://github.com/coral/astra/pull/42",
            title: "Fix browser control by alvaro",
            controls: []
        )
        let outcome = BrowserActionOutcomeVerifier.outcome(
            action: .open,
            control: target,
            result: ["ok": true],
            before: before,
            after: after,
            enabledBrowserAdapters: [BrowserSiteAdapterID.github]
        )
        let adapterRecommendations = response["adapterRecommendations"] as? [[String: Any]] ?? []
        let signals = [
            "adapterRecommendations": adapterRecommendations.contains { $0["adapterID"] as? String == BrowserSiteAdapterID.github },
            "githubEntityOpened": outcome["observedOutcome"] as? String == "githubEntityOpened"
                && bool(outcome["goalSatisfied"])
        ]
        return result(
            task: task,
            signals: signals,
            metrics: baseMetrics(taskSuccess: task.requiredSignals.allSatisfy { signals[$0] == true }, stepCount: 2, goalSatisfied: signals["githubEntityOpened"] == true),
            evidence: [
                "analysisID": analysis.analysisID,
                "controlRefs": controlRefs(from: response),
                "adapterRecommendations": adapterRecommendations,
                "outcome": outcome
            ]
        )
    }

    private static func analysis(
        snapshot: [String: Any],
        generatedAt: Date,
        enabledBrowserAdapters: [String] = [],
        accessibilitySnapshot: [String: Any]? = nil
    ) -> BrowserAnalysis {
        BrowserAnalysisBuilder.build(
            snapshot: snapshot,
            backend: "benchmark fixture",
            engine: "fixture",
            createdAt: generatedAt,
            enabledBrowserAdapters: enabledBrowserAdapters,
            accessibilitySnapshotObject: accessibilitySnapshot
        )
    }

    private static func result(
        task: BrowserBenchmarkTask,
        signals: [String: Bool],
        metrics: [String: Int],
        evidence: [String: Any]
    ) -> BrowserBenchmarkTaskResult {
        let missingSignals = task.requiredSignals.filter { signals[$0] != true }
        return BrowserBenchmarkTaskResult(
            task: task,
            signals: signals,
            metrics: metrics,
            evidence: evidence,
            failureReason: missingSignals.isEmpty ? nil : "Missing required signals: \(missingSignals.joined(separator: ", "))"
        )
    }

    private static func fixturePreflight(
        control: BrowserControl,
        action: BrowserActionKind,
        allowDangerous: Bool
    ) -> [String: Any] {
        if !control.supports(action) {
            return [
                "ok": false,
                "error": "unsupported_action",
                "controlID": control.controlID,
                "action": action.rawValue,
                "validActions": control.validActions.map(\.rawValue)
            ]
        }
        if control.requiresUserConfirmation && !allowDangerous {
            return [
                "ok": false,
                "error": "dangerous_confirmation_required",
                "controlID": control.controlID,
                "action": action.rawValue,
                "risk": control.risk.rawValue
            ]
        }
        return [
            "ok": true,
            "controlID": control.controlID,
            "action": action.rawValue,
            "risk": control.risk.rawValue
        ]
    }

    private static func baseMetrics(
        taskSuccess: Bool,
        ambiguousControl: Int = 0,
        stepCount: Int = 1,
        safetyBlockCorrect: Int = 0,
        goalSatisfied: Bool = false
    ) -> [String: Int] {
        [
            "taskSuccess": taskSuccess ? 1 : 0,
            "wrongClick": 0,
            "staleAnalysis": 0,
            "ambiguousControl": ambiguousControl,
            "loopCount": 0,
            "stepCount": max(0, stepCount),
            "safetyBlockCorrect": safetyBlockCorrect,
            "goalSatisfied": goalSatisfied ? 1 : 0
        ]
    }

    private static func snapshot(
        url: String,
        title: String,
        text: String = "",
        focused: [String: Any]? = nil,
        controls: [[String: Any]]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "ok": true,
            "url": url,
            "title": title,
            "text": text,
            "viewport": ["width": 1280, "height": 800],
            "controls": controls
        ]
        if let focused {
            object["focusedElement"] = focused
        }
        return object
    }

    private static func control(
        selector: String,
        tag: String,
        role: String,
        type: String = "",
        label: String,
        name: String = "",
        value: String = "",
        placeholder: String = "",
        testID: String = "",
        href: String = "",
        y: Double = 100
    ) -> [String: Any] {
        [
            "selector": selector,
            "tag": tag,
            "role": role,
            "type": type,
            "label": label,
            "name": name.isEmpty ? label : name,
            "value": value,
            "placeholder": placeholder,
            "testID": testID,
            "href": href,
            "disabled": false,
            "actionable": true,
            "bounds": ["x": 120, "y": y, "width": 220, "height": 36, "centerX": 230, "centerY": y + 18]
        ]
    }

    private static func accessibilitySnapshot(_ nodes: [[String: Any]]) -> [String: Any] {
        [
            "ok": true,
            "nodeCount": nodes.count,
            "returnedNodeCount": nodes.count,
            "nodes": nodes
        ]
    }

    private static func accessibilityNode(
        id: String,
        role: String,
        name: String,
        value: String = ""
    ) -> [String: Any] {
        [
            "nodeId": id,
            "backendDOMNodeId": id,
            "ignored": false,
            "role": ["value": role],
            "name": ["value": name],
            "value": ["value": value]
        ]
    }

    private static func controlRefs(from response: [String: Any]) -> [[String: Any]] {
        response["controlRefs"] as? [[String: Any]] ?? []
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }
}
