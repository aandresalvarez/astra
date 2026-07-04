import AppKit
import Foundation

/// A per-site workflow adapter: a bundle of bridge-route handlers whose
/// orchestration (multi-step sequences of engine ops, session-lifecycle
/// hooks like controlled-browser promotion, and site-specific verification)
/// lives outside `ShelfBrowserSession` itself. `ShelfBrowserSession` still
/// owns dispatch (which route maps to which adapter call) and still owns
/// every primitive the adapter calls into — this protocol only names the
/// seam, matching the existing `BrowserSiteAdapterID`/`BrowserSiteAdapterDescriptor`
/// vocabulary in `BrowserSiteAdapters.swift`.
@MainActor
protocol BrowserSiteWorkflowAdapter {
    /// `BrowserSiteAdapterID`-style identifier for this adapter.
    var adapterID: String { get }
}

/// Everything `GoogleWorkspaceBrowserWorkflowAdapter` needs back from
/// `ShelfBrowserSession`, as a bundle of closures the session builds fresh
/// on every access (mirroring `ShelfBrowserSession.verificationCommandHandler`
/// and the bridge command handlers in `ShelfBrowserBridgeCommandHandlers.swift`).
///
/// This is intentionally a superset of the Gap-1 `BrowserAutomationEngineOperating`
/// surface, not just that protocol, because the Google Docs/Drive workflows
/// call session-level composite operations (`snapshot`, `waitSaved`,
/// `verifyText`, `findControl`, `clickControl`, `navigateForBridge`,
/// `readPage`) and session lifecycle/state (`ensureControlledBrowserForGoogleWorkspaceAction`,
/// `logBrowserAction`, `updateLastPageReadState`, `currentURL`/`pageTitle`/`engine`)
/// that sit a level above the raw per-op engine dispatch and were never part
/// of that protocol. Passing only the engine protocol here would have meant
/// either re-implementing those composite operations a second time inside
/// the adapter (duplicating logic, the opposite of this extraction's goal)
/// or reaching back into the session through some other backdoor. A context
/// struct keeps the seam explicit and the session as the single owner of
/// every primitive.
@MainActor
struct GoogleWorkspaceBrowserWorkflowContext {
    // MARK: State reads

    var currentURL: () -> String
    var pageTitle: () -> String
    var engine: () -> ShelfBrowserEngine
    var isUsingControlledBrowser: () -> Bool
    var isGoogleDocsEditor: () -> Bool
    var isGoogleWorkspaceEditor: () -> Bool
    var canUseGoogleDriveOpen: () -> Bool

    // MARK: State mutation

    var updateLastPageReadState: ([String: Any]) -> Void

    // MARK: Session lifecycle

    /// Promotes the session to the controlled-CDP engine when a Google
    /// Workspace action requires it (embedded WebKit cannot reliably drive
    /// Google's canvas-rendered editors for these workflows). Returns a
    /// failure response to short-circuit the caller when promotion isn't
    /// possible or isn't enabled; returns nil when the caller can proceed.
    var ensureControlledBrowserForGoogleWorkspaceAction: (String, Date) async -> [String: Any]?

    // MARK: Logging

    var logBrowserAction: (
        _ phase: String,
        _ action: String,
        _ fields: [String: String],
        _ resultJSON: String?,
        _ started: Date?,
        _ error: Error?
    ) -> Void

    // MARK: Composite browser operations (session-owned, not raw engine ops)

    var navigateForBridge: (URL, String) async -> [String: Any]
    var waitForNavigationSettle: (String?, TimeInterval) async -> [String: Any]
    var rawSnapshotObject: () async throws -> [String: Any]
    var snapshot: (BrowserSnapshotMode, String?, Int?) async throws -> String
    var readPage: (String?, Int?, Int?) async throws -> [String: Any]
    var waitSaved: (Double, Int) async throws -> [String: Any]
    var verifyText: (String, Bool) async throws -> [String: Any]
    var findControl: (String, String?, Int) async throws -> [String: Any]
    var clickControl: (String, String?, Bool) async throws -> [String: Any]
    var browserAdapterDisabledResponse: (String, String) -> [String: Any]

    // MARK: Raw engine-op passthroughs (session-wrapped: preflight/logging/settle stay in the session)

    var click: (String?, Double?, Double?, Bool, String?, String?, String?, String?, String?) async throws -> String
    var doubleClick: (String?, Double?, Double?, Bool, String?, String?, String?, String?, String?) async throws -> String
    var type: (String?, String, Bool, String?, String?, String?, String?) async throws -> String
    /// Third parameter is `skipTextEntryPreflight`, matching
    /// `ShelfBrowserSession.keypress(key:modifiers:skipTextEntryPreflight:)`.
    /// The Google Docs paste-via-clipboard flow explicitly skips the
    /// generic focused-text-entry preflight for its Cmd+V dispatch (it has
    /// already validated the target via its own focus/select-all sequence),
    /// so this needs to be threaded through rather than defaulted away.
    var keypress: (String, [String], Bool) async throws -> String
    var insertText: (String) async throws -> String
}

/// The first conformance of `BrowserSiteWorkflowAdapter`: Google Docs/Drive
/// browser workflows (open a Drive file by name, in-document find, insert
/// text, full-document read/replace with browser-copy backup and rollback,
/// and the compact Find-and-Replace dialog flow). Extracted verbatim from
/// `ShelfBrowserSession` — same JS scripts (via the session's own op
/// wrappers), same timeouts, same error codes and hints, same control flow.
/// Only the location changed, plus threading every session dependency
/// through `GoogleWorkspaceBrowserWorkflowContext` instead of calling
/// `self` directly.
@MainActor
struct GoogleWorkspaceBrowserWorkflowAdapter: BrowserSiteWorkflowAdapter {
    let adapterID: String = BrowserSiteAdapterID.googleDrive
    let context: GoogleWorkspaceBrowserWorkflowContext

    func googleDriveOpen(
        name: String,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let started = Date()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        context.logBrowserAction(
            "requested",
            "googleDriveOpen",
            [
                "name_length": String(trimmedName.count),
                "timeout_seconds": String(timeoutSeconds)
            ],
            nil,
            nil,
            nil
        )

        guard context.canUseGoogleDriveOpen() else {
            let result = context.browserAdapterDisabledResponse(BrowserSiteAdapterID.googleDrive, "googleDriveOpen")
            context.logBrowserAction(
                "completed",
                "googleDriveOpen",
                [:],
                try ShelfBrowserSession.jsonString(result),
                started,
                nil
            )
            return result
        }

        guard !trimmedName.isEmpty else {
            let result: [String: Any] = [
                "ok": false,
                "error": "missing_name"
            ]
            context.logBrowserAction(
                "completed",
                "googleDriveOpen",
                [:],
                try ShelfBrowserSession.jsonString(result),
                started,
                nil
            )
            return result
        }

        if let promotionError = await context.ensureControlledBrowserForGoogleWorkspaceAction(
            "googleDriveOpen",
            started
        ) {
            context.logBrowserAction(
                "completed",
                "googleDriveOpen",
                [:],
                try ShelfBrowserSession.jsonString(promotionError),
                started,
                nil
            )
            return promotionError
        }

        do {
            let currentURL = context.currentURL()
            let pageTitle = context.pageTitle()
            if GoogleWorkspaceBrowserService.isOpenedDriveTarget(urlString: currentURL, title: pageTitle, name: trimmedName, startURL: nil) {
                let result: [String: Any] = [
                    "ok": true,
                    "opened": true,
                    "alreadyOpen": true,
                    "name": trimmedName,
                    "url": currentURL,
                    "title": pageTitle,
                    "elapsedSeconds": Date().timeIntervalSince(started)
                ]
                context.logBrowserAction(
                    "completed",
                    "googleDriveOpen",
                    [:],
                    try ShelfBrowserSession.jsonString(result),
                    started,
                    nil
                )
                return result
            }

            let startURL = currentURL
            let searchURL = GoogleWorkspaceBrowserService.googleDriveSearchURL(for: trimmedName)
            let searchNavigation = await context.navigateForBridge(searchURL, "googleDriveOpenSearch")
            let searchStarted = Date()
            var result = try await waitForGoogleDriveOpen(
                name: trimmedName,
                startURL: startURL,
                started: started,
                waitStarted: searchStarted,
                timeoutSeconds: timeoutSeconds,
                intervalMilliseconds: intervalMilliseconds
            )
            result["searchMethod"] = "direct_url"
            result["searchNavigation"] = [
                "ok": ShelfBrowserSession.boolValue(searchNavigation["targetReached"]),
                "url": searchNavigation["url"] as? String ?? "",
                "title": searchNavigation["title"] as? String ?? ""
            ]
            context.logBrowserAction(
                "completed",
                "googleDriveOpen",
                [
                    "opened": String(ShelfBrowserSession.boolValue(result["opened"])),
                    "search_method": result["searchMethod"] as? String ?? "unknown",
                    "candidate_count": String(ShelfBrowserSession.intValue(result["candidateCount"]) ?? 0),
                    "last_open_method": (result["lastOpenAttempt"] as? [String: Any])?["method"] as? String ?? "",
                    "last_open_error": (result["lastOpenAttempt"] as? [String: Any])?["error"] as? String ?? ""
                ],
                try ShelfBrowserSession.jsonString(result),
                started,
                nil
            )
            return result
        } catch {
            context.logBrowserAction(
                "failed",
                "googleDriveOpen",
                [:],
                nil,
                started,
                error
            )
            throw error
        }
    }

    /// Dead code carried over verbatim from `ShelfBrowserSession` (it was
    /// never called there either — confirmed via a repo-wide search before
    /// this extraction). Kept as-is because this move is a relocation, not a
    /// cleanup; removing unreachable code is a separate, independently
    /// reviewable change.
    func fillGoogleDriveSearch(with name: String) async throws -> [String: Any] {
        struct SearchTarget {
            let method: String
            let selector: String?
            let label: String?
            let placeholder: String?
        }

        let targets = [
            SearchTarget(method: "label", selector: nil, label: "Search in Drive", placeholder: nil),
            SearchTarget(method: "placeholder", selector: nil, label: nil, placeholder: "Search in Drive"),
            SearchTarget(method: "selector", selector: #"input[aria-label="Search in Drive"], input[placeholder="Search in Drive"]"#, label: nil, placeholder: nil)
        ]

        var lastResult: [String: Any] = [
            "ok": false,
            "error": "not_attempted"
        ]

        for target in targets {
            let json = try await context.type(
                target.selector,
                name,
                true,
                target.label,
                nil,
                target.placeholder,
                nil
            )
            var result = try ShelfBrowserSession.jsonObject(from: json)
            result["method"] = target.method
            lastResult = result
            if ShelfBrowserSession.boolValue(result["ok"]) {
                return result
            }
        }

        return lastResult
    }

    private func waitForGoogleDriveOpen(
        name: String,
        startURL: String,
        started: Date,
        waitStarted: Date,
        timeoutSeconds: Double,
        intervalMilliseconds: Int
    ) async throws -> [String: Any] {
        let timeout = max(0.5, min(timeoutSeconds, GoogleWorkspaceBrowserService.googleDriveOpenMaximumTimeoutSeconds))
        let interval = UInt64(max(100, min(intervalMilliseconds, 2_000))) * 1_000_000
        var lastURL = context.currentURL()
        var lastTitle = context.pageTitle()
        var lastCandidateCount = 0
        var lastOpenAttempt: [String: Any]?
        var attemptedCandidateKeys = Set<String>()
        var retriedOpenKey = false
        var retriedDriveOpenShortcut = false

        while Date().timeIntervalSince(waitStarted) <= timeout {
            try await Task.sleep(nanoseconds: interval)

            let object = try await context.rawSnapshotObject()
            lastURL = object["url"] as? String ?? context.currentURL()
            lastTitle = object["title"] as? String ?? context.pageTitle()

            if GoogleWorkspaceBrowserService.isOpenedDriveTarget(urlString: lastURL, title: lastTitle, name: name, startURL: startURL) {
                return [
                    "ok": true,
                    "opened": true,
                    "name": name,
                    "url": lastURL,
                    "title": lastTitle,
                    "matchedName": GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name),
                    "elapsedSeconds": Date().timeIntervalSince(started)
                ]
            }
            if GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(lastURL),
               !GoogleWorkspaceBrowserService.isPendingGoogleWorkspaceTitle(lastTitle),
               !GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name) {
                return [
                    "ok": false,
                    "opened": false,
                    "error": "drive_file_name_mismatch",
                    "safeEditUnavailable": true,
                    "name": name,
                    "url": lastURL,
                    "title": lastTitle,
                    "matchedName": false,
                    "candidateCount": lastCandidateCount,
                    "lastOpenAttempt": lastOpenAttempt ?? [:],
                    "elapsedSeconds": Date().timeIntervalSince(started),
                    "hint": "Google Drive opened a different Google editor than the requested file. Stop before reading or editing the wrong file."
                ]
            }

            let controls = object["controls"] as? [[String: Any]] ?? []
            let candidates = GoogleWorkspaceBrowserService.googleDriveOpenCandidates(
                controls: controls,
                name: name,
                pageURL: lastURL
            )
            lastCandidateCount = candidates.count
            if let candidate = candidates.first {
                let candidateKey = GoogleWorkspaceBrowserService.googleDriveOpenCandidateKey(candidate)
                if !attemptedCandidateKeys.contains(candidateKey) {
                    attemptedCandidateKeys.insert(candidateKey)
                    lastOpenAttempt = try await openGoogleDriveCandidate(candidate)
                    let wait = await context.waitForNavigationSettle(nil, 3)
                    lastURL = wait["url"] as? String ?? context.currentURL()
                    lastTitle = wait["title"] as? String ?? context.pageTitle()

                    if GoogleWorkspaceBrowserService.isOpenedDriveTarget(urlString: lastURL, title: lastTitle, name: name, startURL: startURL) {
                        return [
                            "ok": true,
                            "opened": true,
                            "name": name,
                            "url": lastURL,
                            "title": lastTitle,
                            "matchedName": true,
                            "candidateCount": lastCandidateCount,
                            "openMethod": lastOpenAttempt?["method"] as? String ?? "drive_result",
                            "elapsedSeconds": Date().timeIntervalSince(started)
                        ]
                    }
                    if GoogleWorkspaceBrowserService.isGoogleWorkspaceEditorURL(lastURL),
                       !GoogleWorkspaceBrowserService.isPendingGoogleWorkspaceTitle(lastTitle),
                       !GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name) {
                        return [
                            "ok": false,
                            "opened": false,
                            "error": "drive_file_name_mismatch",
                            "safeEditUnavailable": true,
                            "name": name,
                            "url": lastURL,
                            "title": lastTitle,
                            "matchedName": false,
                            "candidateCount": lastCandidateCount,
                            "openMethod": lastOpenAttempt?["method"] as? String ?? "drive_result",
                            "lastOpenAttempt": lastOpenAttempt ?? [:],
                            "elapsedSeconds": Date().timeIntervalSince(started),
                            "hint": "Google Drive opened a different Google editor than the requested file. Stop before reading or editing the wrong file."
                        ]
                    }
                }
            }

            let waitElapsed = Date().timeIntervalSince(waitStarted)
            if !retriedOpenKey, !attemptedCandidateKeys.isEmpty, waitElapsed >= 2.0 {
                _ = try? await context.keypress("Enter", [], false)
                retriedOpenKey = true
            }
            if !retriedDriveOpenShortcut, !attemptedCandidateKeys.isEmpty, waitElapsed >= 4.0 {
                _ = try? await context.keypress("o", [], false)
                retriedDriveOpenShortcut = true
            }
        }

        return [
            "ok": false,
            "opened": false,
            "error": "drive_file_not_opened",
            "name": name,
            "url": lastURL,
            "title": lastTitle,
            "matchedName": GoogleWorkspaceBrowserService.googleDriveOpenedTitleMatches(lastTitle, name),
            "candidateCount": lastCandidateCount,
            "lastOpenAttempt": lastOpenAttempt ?? [:],
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func openGoogleDriveCandidate(_ control: [String: Any]) async throws -> [String: Any] {
        let selector = ShelfBrowserCommandNormalization.normalized(control["selector"] as? String)
        let bounds = control["bounds"] as? [String: Any]
        let x = ShelfBrowserSession.doubleValue(bounds?["centerX"])
        let y = ShelfBrowserSession.doubleValue(bounds?["centerY"])
        let canUseSelector = selector != nil
        let canUsePoint = x != nil && y != nil && (x ?? -1) >= 0 && (y ?? -1) >= 0

        let primaryJSON = try await context.doubleClick(
            canUseSelector ? selector : nil,
            canUseSelector ? nil : x,
            canUseSelector ? nil : y,
            false,
            nil,
            nil,
            nil,
            nil,
            nil
        )
        var primary = try ShelfBrowserSession.jsonObject(from: primaryJSON)
        primary["method"] = canUseSelector ? "candidate_double_click_selector" : "candidate_double_click_point"
        primary["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
        if ShelfBrowserSession.boolValue(primary["ok"]) {
            return primary
        }

        if canUseSelector && canUsePoint {
            let pointJSON = try await context.doubleClick(
                nil,
                x,
                y,
                false,
                nil,
                nil,
                nil,
                nil,
                nil
            )
            var point = try ShelfBrowserSession.jsonObject(from: pointJSON)
            point["method"] = "candidate_double_click_point"
            point["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
            if ShelfBrowserSession.boolValue(point["ok"]) {
                return point
            }
        }

        let fallbackJSON = try await context.click(
            canUseSelector ? selector : nil,
            canUseSelector ? nil : x,
            canUseSelector ? nil : y,
            false,
            nil,
            nil,
            nil,
            nil,
            nil
        )
        var fallback = try ShelfBrowserSession.jsonObject(from: fallbackJSON)
        fallback["method"] = canUseSelector ? "candidate_click_enter_selector" : "candidate_click_enter_point"
        fallback["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
        if ShelfBrowserSession.boolValue(fallback["ok"]) {
            _ = try? await context.keypress("Enter", [], false)
        }
        if canUseSelector && canUsePoint && !ShelfBrowserSession.boolValue(fallback["ok"]) {
            let pointFallbackJSON = try await context.click(
                nil,
                x,
                y,
                false,
                nil,
                nil,
                nil,
                nil,
                nil
            )
            var pointFallback = try ShelfBrowserSession.jsonObject(from: pointFallbackJSON)
            pointFallback["method"] = "candidate_click_enter_point"
            pointFallback["candidate"] = GoogleWorkspaceBrowserService.compactGoogleDriveCandidate(control)
            if ShelfBrowserSession.boolValue(pointFallback["ok"]) {
                _ = try? await context.keypress("Enter", [], false)
            }
            return pointFallback
        }
        return fallback
    }

    func googleFindReplace(find: String, replacement: String, all: Bool) async throws -> [String: Any] {
        guard context.isGoogleWorkspaceEditor() else {
            return [
                "ok": false,
                "error": "not_google_workspace_editor",
                "hint": "Use replace-text for normal editable controls, or open a Google Docs, Sheets, or Slides editor page first."
            ]
        }
        let started = Date()
        if let promotionError = await context.ensureControlledBrowserForGoogleWorkspaceAction(
            "googleFindReplace",
            started
        ) {
            return promotionError
        }

        _ = try await context.keypress("h", ["command", "shift"], false)
        try await Task.sleep(nanoseconds: 500_000_000)

        let controlsJSON = try await context.snapshot(.controls, nil, 80)
        let controlsObject = try ShelfBrowserSession.jsonObject(from: controlsJSON)
        let controls = controlsObject["controls"] as? [[String: Any]] ?? []
        let editableControls = controls.filter { control in
            let tag = (control["tag"] as? String ?? "").lowercased()
            return tag == "input" || tag == "textarea" || (control["role"] as? String ?? "").lowercased().contains("textbox")
        }

        guard editableControls.count >= 2,
              let findSelector = editableControls.first?["selector"] as? String,
              let replaceSelector = editableControls.dropFirst().first?["selector"] as? String else {
            return [
                "ok": false,
                "error": "find_replace_fields_not_found",
                "hint": "Open the Find and Replace dialog, then use find-control and set-value on the Find and Replace fields.",
                "controls": Array(controls.prefix(12))
            ]
        }

        let findJSON = try await context.type(findSelector, find, true, nil, nil, nil, nil)
        let replaceJSON = try await context.type(replaceSelector, replacement, true, nil, nil, nil, nil)
        let buttonLabel = all ? "Replace all" : "Replace"
        let clickResult = try await context.clickControl(buttonLabel, nil, true)
        try await Task.sleep(nanoseconds: 500_000_000)
        let saved = try await context.waitSaved(8, 500)
        let present = try await context.verifyText(replacement, false)
        let oldAbsent = try await context.verifyText(find, true)

        return [
            "ok": ShelfBrowserSession.boolValue(clickResult["ok"]) && ShelfBrowserSession.boolValue(present["ok"]),
            "find": find,
            "replacement": replacement,
            "findField": try ShelfBrowserSession.jsonObject(from: findJSON),
            "replaceField": try ShelfBrowserSession.jsonObject(from: replaceJSON),
            "click": clickResult,
            "saved": saved,
            "verification": [
                "replacementPresent": present,
                "oldTextAbsent": oldAbsent
            ]
        ]
    }

    func googleDocsFind(query: String, closeFindBar: Bool) async throws -> [String: Any] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return ["ok": false, "error": "empty_query"]
        }
        guard context.isGoogleDocsEditor() else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        if let promotionError = await context.ensureControlledBrowserForGoogleWorkspaceAction(
            "googleDocsFind",
            started
        ) {
            return promotionError
        }
        context.logBrowserAction(
            "requested",
            "googleDocsFind",
            [
                "query_length": String(normalizedQuery.count),
                "close_find_bar": String(closeFindBar)
            ],
            nil,
            nil,
            nil
        )

        do {
            _ = try await context.keypress("f", ["command"], false)
            try await Task.sleep(nanoseconds: 250_000_000)
            let findFieldJSON = try await context.type(nil, normalizedQuery, true, "Find in document", nil, nil, nil)
            _ = try await context.keypress("Enter", [], false)
            try await Task.sleep(nanoseconds: 300_000_000)

            let snapshotJSON = try await context.snapshot(.text, normalizedQuery, 2_000)
            let snapshot = try ShelfBrowserSession.jsonObject(from: snapshotJSON)
            let text = snapshot["text"] as? String ?? ""
            let matches = snapshot["matches"] as? [[String: Any]] ?? []
            let countText = Self.googleFindCountText(in: text)
            let foundByCount = countText.map { !$0.hasPrefix("0 of ") } ?? false
            let found = foundByCount || !matches.isEmpty || text.localizedCaseInsensitiveContains(normalizedQuery)
            var closeResult: [String: Any]?
            if closeFindBar,
               let closeJSON = try? await context.keypress("Escape", [], false) {
                closeResult = try? ShelfBrowserSession.jsonObject(from: closeJSON)
            }

            let result: [String: Any] = [
                "ok": found,
                "query": normalizedQuery,
                "found": found,
                "matchCountText": countText ?? "",
                "findField": try ShelfBrowserSession.jsonObject(from: findFieldJSON),
                "close": closeResult ?? [:],
                "elapsedSeconds": Date().timeIntervalSince(started),
                "url": snapshot["url"] as? String ?? "",
                "title": snapshot["title"] as? String ?? ""
            ]
            context.logBrowserAction(
                "completed",
                "googleDocsFind",
                [
                    "query_length": String(normalizedQuery.count),
                    "found": String(found),
                    "match_count_present": String(countText != nil)
                ],
                try ShelfBrowserSession.jsonString(result),
                started,
                nil
            )
            return result
        } catch {
            context.logBrowserAction(
                "failed",
                "googleDocsFind",
                ["query_length": String(normalizedQuery.count)],
                nil,
                started,
                error
            )
            throw error
        }
    }

    func googleDocsInsert(text: String, verifyText: String?, waitSaved shouldWaitSaved: Bool) async throws -> [String: Any] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return ["ok": false, "error": "empty_text"]
        }
        guard context.isGoogleDocsEditor() else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        if let promotionError = await context.ensureControlledBrowserForGoogleWorkspaceAction(
            "googleDocsInsert",
            started
        ) {
            return promotionError
        }
        context.logBrowserAction(
            "requested",
            "googleDocsInsert",
            [
                "text_length": String(normalizedText.count),
                "verify_text_length": String(verifyText?.count ?? 0),
                "wait_saved": String(shouldWaitSaved)
            ],
            nil,
            nil,
            nil
        )

        do {
            let focusJSON = try await context.click(nil, 0.47, 0.45, false, nil, nil, nil, nil, nil)
            let insertJSON = try await context.insertText(normalizedText)
            let saved: [String: Any] = shouldWaitSaved
                ? try await context.waitSaved(10, 500)
                : ["ok": true, "skipped": true]
            let verification: [String: Any]
            if let verifyText, !verifyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                verification = try await googleDocsFind(query: verifyText, closeFindBar: true)
            } else {
                verification = ["ok": true, "skipped": true]
            }

            let focus = try ShelfBrowserSession.jsonObject(from: focusJSON)
            let insert = try ShelfBrowserSession.jsonObject(from: insertJSON)
            let ok = ShelfBrowserSession.boolValue(focus["ok"])
                && ShelfBrowserSession.boolValue(insert["ok"])
                && ShelfBrowserSession.boolValue(saved["ok"])
                && ShelfBrowserSession.boolValue(verification["ok"])
            let result: [String: Any] = [
                "ok": ok,
                "textLength": normalizedText.count,
                "verifyText": verifyText ?? "",
                "focus": focus,
                "insert": insert,
                "saved": saved,
                "verification": verification,
                "elapsedSeconds": Date().timeIntervalSince(started)
            ]
            context.logBrowserAction(
                "completed",
                "googleDocsInsert",
                [
                    "text_length": String(normalizedText.count),
                    "verified": String(ShelfBrowserSession.boolValue(verification["ok"]))
                ],
                try ShelfBrowserSession.jsonString(result),
                started,
                nil
            )
            return result
        } catch {
            context.logBrowserAction(
                "failed",
                "googleDocsInsert",
                ["text_length": String(normalizedText.count)],
                nil,
                started,
                error
            )
            throw error
        }
    }

    func googleDocsReadDocument() async throws -> [String: Any] {
        guard context.isGoogleDocsEditor() else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        if let promotionError = await context.ensureControlledBrowserForGoogleWorkspaceAction(
            "googleDocsReadDocument",
            started
        ) {
            return promotionError
        }
        if let browserRequirement = googleDocsControlledBrowserRequiredResult(
            action: "googleDocsReadDocument",
            method: "browser_select_all_copy",
            started: started
        ) {
            return browserRequirement
        }

        let browserResult = try await googleDocsReadDocumentViaBrowser()
        if ShelfBrowserSession.boolValue(browserResult["ok"]) {
            return browserResult
        }

        var result = browserResult
        result["apiFallbackSkipped"] = true
        result["apiFallbackSkippedReason"] = "browser_use_mode"
        return result
    }

    func googleDocsReadVisiblePage(format: String?, limit: Int?, chunkSize: Int?) async throws -> [String: Any] {
        guard context.isGoogleDocsEditor() else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        var response = try await context.readPage(format ?? "markdown", limit, chunkSize)
        response["source"] = "browser_page_read"
        response["googleDocsMode"] = "visible_page"
        response["fullDocument"] = false
        response["partialSummaryAllowed"] = true
        response["coverage"] = "partial"

        var warnings = response["warnings"] as? [String] ?? []
        warnings.append("Google Docs visible-page reads are partial by design; summarize only the returned content unless the user explicitly accepts that limitation.")
        warnings.append("Use google-docs-read-document in Controlled mode for a full-document summary.")
        response["warnings"] = Array(Set(warnings)).sorted()
        context.updateLastPageReadState(response)
        return response
    }

    func googleDocsReplaceDocument(text: String, verifyText: String?) async throws -> [String: Any] {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return ["ok": false, "error": "empty_text"]
        }
        guard context.isGoogleDocsEditor() else {
            return [
                "ok": false,
                "error": "not_google_docs_editor",
                "hint": "Open a Google Docs document editor page first."
            ]
        }

        let started = Date()
        if let promotionError = await context.ensureControlledBrowserForGoogleWorkspaceAction(
            "googleDocsReplaceDocument",
            started
        ) {
            return promotionError
        }
        if let browserRequirement = googleDocsControlledBrowserRequiredResult(
            action: "googleDocsReplaceDocument",
            method: "browser_select_all_paste",
            started: started
        ) {
            return browserRequirement
        }

        return try await googleDocsReplaceDocumentViaBrowser(
            text: normalizedText,
            verifyText: verifyText
        )
    }

    private func googleDocsControlledBrowserRequiredResult(
        action: String,
        method: String,
        started: Date
    ) -> [String: Any]? {
        let autoPromote = UserDefaults.standard.bool(forKey: AppStorageKeys.browserAutoPromoteGoogleWorkspace)
        guard GoogleWorkspaceBrowserService.googleDocsFullDocumentClipboardRequiresControlled(
            engine: context.engine(),
            autoPromoteGoogleWorkspace: autoPromote
        ) else {
            return nil
        }

        context.logBrowserAction(
            "failed",
            action,
            [
                "error": "google_docs_controlled_browser_required",
                "reason": "embedded_webkit_clipboard_unavailable",
                "required_engine": ShelfBrowserEngine.controlled.rawValue,
                "selected_engine": context.engine().rawValue,
                "auto_promote_google_workspace": String(autoPromote)
            ],
            nil,
            started,
            nil
        )

        var response: [String: Any] = [
            "ok": false,
            "error": "google_docs_controlled_browser_required",
            "reason": "embedded_webkit_clipboard_unavailable",
            "safeEditUnavailable": true,
            "method": method,
            "url": context.currentURL(),
            "title": context.pageTitle(),
            "requiredEngine": ShelfBrowserEngine.controlled.rawValue,
            "selectedEngine": context.engine().rawValue,
            "autoPromoteGoogleWorkspace": autoPromote,
            "copyAttempted": false,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "hint": "Full-document Google Docs browser read/replace requires Controlled mode, or Settings > Appearance > Privacy & Logging > Auto-promote Google Workspace helpers. Embedded WebKit does not expose a reliable fresh clipboard copy from the Docs editor iframe, so ASTRA stopped before selecting or replacing document content."
        ]
        BrowserBridgeRecoveryHints.attach(
            to: &response,
            error: "google_docs_controlled_browser_required",
            action: action
        )
        return response
    }

    private func googleDocsReadDocumentViaBrowser() async throws -> [String: Any] {
        let started = Date()
        let pasteboardSnapshot = Self.capturePasteboardSnapshot()
        defer { Self.restorePasteboardSnapshot(pasteboardSnapshot) }

        let closeJSON = try? await context.keypress("Escape", [], false)
        let focusJSON = try await context.click(nil, 0.47, 0.45, false, nil, nil, nil, nil, nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        let selectJSON = try await context.keypress("a", ["command"], false)
        try await Task.sleep(nanoseconds: 250_000_000)

        let copyStartChangeCount = NSPasteboard.general.changeCount
        let copyJSON = try await context.keypress("c", ["command"], false)
        let copiedText = await Self.waitForPasteboardString(
            afterChangeCount: copyStartChangeCount,
            timeoutSeconds: 2.5,
            requireChange: true
        )
        _ = try? await context.keypress("Escape", [], false)

        let focus = try ShelfBrowserSession.jsonObject(from: focusJSON)
        let select = try ShelfBrowserSession.jsonObject(from: selectJSON)
        let copy = try ShelfBrowserSession.jsonObject(from: copyJSON)
        let close = closeJSON.flatMap { try? ShelfBrowserSession.jsonObject(from: $0) } ?? [:]
        let text = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return [
                "ok": false,
                "error": "google_docs_browser_copy_unavailable",
                "safeEditUnavailable": true,
                "method": "browser_select_all_copy",
                "url": context.currentURL(),
                "title": context.pageTitle(),
                "focus": focus,
                "selectAll": select,
                "copy": copy,
                "close": close,
                "copyChangeObserved": false,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "hint": "ASTRA could not copy a fresh non-empty document backup through the browser. Stop instead of editing without a verified backup."
            ]
        }

        return [
            "ok": true,
            "method": "browser_select_all_copy",
            "text": text,
            "textLength": text.count,
            "url": context.currentURL(),
            "title": context.pageTitle(),
            "focus": focus,
            "selectAll": select,
            "copy": copy,
            "close": close,
            "copyChangeObserved": true,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private func googleDocsReplaceDocumentViaBrowser(text: String, verifyText: String?) async throws -> [String: Any] {
        let started = Date()
        let backup = try await googleDocsReadDocumentViaBrowser()
        guard ShelfBrowserSession.boolValue(backup["ok"]),
              let originalText = backup["text"] as? String,
              !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [
                "ok": false,
                "error": "google_docs_safe_edit_unavailable",
                "safeEditUnavailable": true,
                "method": "browser_select_all_paste",
                "url": context.currentURL(),
                "title": context.pageTitle(),
                "backup": backup,
                "hint": "Full-document browser replacement requires a browser-copied backup first. ASTRA stopped instead of editing without rollback data."
            ]
        }

        let pasteboardSnapshot = Self.capturePasteboardSnapshot()
        defer { Self.restorePasteboardSnapshot(pasteboardSnapshot) }

        let paste = try await googleDocsPasteFullDocumentText(text)
        let saved = try await context.waitSaved(12, 500)
        let verificationQuery = GoogleWorkspaceBrowserService.googleDocsVerificationQuery(explicit: verifyText, text: text)
        let verification: [String: Any]
        if let verificationQuery {
            verification = try await googleDocsFind(query: verificationQuery, closeFindBar: true)
        } else {
            verification = ["ok": true, "skipped": true]
        }

        let pasteOK = ShelfBrowserSession.boolValue(paste["ok"])
        let savedOK = ShelfBrowserSession.boolValue(saved["ok"])
        let verified = ShelfBrowserSession.boolValue(verification["ok"])
        if pasteOK, verified, savedOK {
            return [
                "ok": true,
                "method": "browser_select_all_paste",
                "textLength": text.count,
                "verifyText": verificationQuery ?? "",
                "url": context.currentURL(),
                "title": context.pageTitle(),
                "backupTextLength": originalText.count,
                "backupMethod": backup["method"] as? String ?? "",
                "paste": paste,
                "saved": saved,
                "verification": verification,
                "elapsedSeconds": Date().timeIntervalSince(started)
            ]
        }

        if !verified {
            let rollback = try? await googleDocsPasteFullDocumentText(originalText)
            let rollbackSaved = try? await context.waitSaved(12, 500)
            return [
                "ok": false,
                "error": "google_docs_safe_edit_verification_failed",
                "method": "browser_select_all_paste",
                "textLength": text.count,
                "verifyText": verificationQuery ?? "",
                "url": context.currentURL(),
                "title": context.pageTitle(),
                "backupTextLength": originalText.count,
                "paste": paste,
                "saved": saved,
                "verification": verification,
                "rollback": rollback ?? [:],
                "rollbackSaved": rollbackSaved ?? [:],
                "elapsedSeconds": Date().timeIntervalSince(started),
                "hint": "ASTRA pasted the replacement but could not verify it, so it attempted to restore the browser-copied backup. Stop for user review."
            ]
        }

        return [
            "ok": false,
            "error": savedOK ? "google_docs_browser_paste_failed" : "saved_indicator_not_found",
            "method": "browser_select_all_paste",
            "textLength": text.count,
            "verifyText": verificationQuery ?? "",
            "url": context.currentURL(),
            "title": context.pageTitle(),
            "backupTextLength": originalText.count,
            "paste": paste,
            "saved": saved,
            "verification": verification,
            "elapsedSeconds": Date().timeIntervalSince(started),
            "hint": "ASTRA did not report success because the paste or save check did not complete cleanly. It did not use raw select-all/delete."
        ]
    }

    private func googleDocsPasteFullDocumentText(_ text: String) async throws -> [String: Any] {
        let started = Date()
        let closeJSON = try? await context.keypress("Escape", [], false)
        let focusJSON = try await context.click(nil, 0.47, 0.45, false, nil, nil, nil, nil, nil)
        try await Task.sleep(nanoseconds: 250_000_000)
        let selectJSON = try await context.keypress("a", ["command"], false)
        try await Task.sleep(nanoseconds: 250_000_000)

        let inputJSON: String
        let method: String
        if context.isUsingControlledBrowser() {
            guard Self.writePasteboardString(text) else {
                return [
                    "ok": false,
                    "error": "pasteboard_write_failed",
                    "method": "browser_select_all_paste",
                    "textLength": text.count
                ]
            }
            inputJSON = try await context.keypress("v", ["command"], true)
            method = "browser_select_all_paste"
            try await Task.sleep(nanoseconds: 500_000_000)
        } else {
            inputJSON = try await context.insertText(text)
            method = "browser_select_all_insert_text"
        }

        let focus = try ShelfBrowserSession.jsonObject(from: focusJSON)
        let select = try ShelfBrowserSession.jsonObject(from: selectJSON)
        let input = try ShelfBrowserSession.jsonObject(from: inputJSON)
        let close = closeJSON.flatMap { try? ShelfBrowserSession.jsonObject(from: $0) } ?? [:]
        return [
            "ok": ShelfBrowserSession.boolValue(focus["ok"]) && ShelfBrowserSession.boolValue(select["ok"]) && ShelfBrowserSession.boolValue(input["ok"]),
            "method": method,
            "textLength": text.count,
            "close": close,
            "focus": focus,
            "selectAll": select,
            "input": input,
            "elapsedSeconds": Date().timeIntervalSince(started)
        ]
    }

    private static func waitForPasteboardString(
        afterChangeCount: Int,
        timeoutSeconds: Double,
        requireChange: Bool = false
    ) async -> String? {
        let started = Date()
        let timeout = max(0.1, min(timeoutSeconds, 10))
        var latest: String?
        while Date().timeIntervalSince(started) <= timeout {
            let pasteboard = NSPasteboard.general
            if let value = pasteboard.string(forType: .string),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if pasteboard.changeCount != afterChangeCount {
                    return value
                }
                if !requireChange {
                    latest = value
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return latest
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func capturePasteboardSnapshot() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.compactMap { values -> NSPasteboardItem? in
            guard !values.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func writePasteboardString(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func googleFindCountText(in text: String) -> String? {
        guard let range = text.range(
            of: #"(?i)\b\d+\s+of\s+\d+\b"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(text[range])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
}
