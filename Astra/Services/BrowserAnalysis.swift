import Foundation

enum BrowserActionKind: String, CaseIterable {
    case click
    case doubleClick
    case focus
    case fill
    case setValue
    case select
    case open
    case contextMenu
    case insertText
    case verifyText
    case waitFor
    case googleFindReplace
    case googleDocsFind
    case googleDocsInsert
    case googleDriveOpen

    static func normalized(_ value: String) -> BrowserActionKind? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "click":
            return .click
        case "doubleclick", "double-click", "double_click":
            return .doubleClick
        case "focus":
            return .focus
        case "fill", "type":
            return .fill
        case "setvalue", "set-value", "set_value":
            return .setValue
        case "select":
            return .select
        case "open":
            return .open
        case "contextmenu", "context-menu", "context_menu", "rightclick", "right-click":
            return .contextMenu
        case "inserttext", "insert-text", "text":
            return .insertText
        case "verifytext", "verify-text":
            return .verifyText
        case "waitfor", "wait-for", "wait":
            return .waitFor
        case "googlefindreplace", "google-find-replace":
            return .googleFindReplace
        case "googledocsfind", "google-docs-find":
            return .googleDocsFind
        case "googledocsinsert", "google-docs-insert":
            return .googleDocsInsert
        case "googledriveopen", "google-drive-open", "drive-open":
            return .googleDriveOpen
        default:
            return nil
        }
    }
}

enum BrowserRisk: String {
    case normal
    case navigation
    case externalNavigation
    case formSubmit
    case destructive
    case sendMessage
    case payment
    case purchase
    case authorization
    case privacySensitive
    case credentialInput
    case mfaInput
    case unknownHighImpact

    var requiresUserConfirmation: Bool {
        switch self {
        case .normal, .navigation, .externalNavigation, .privacySensitive:
            return false
        case .formSubmit, .destructive, .sendMessage, .payment, .purchase, .authorization, .credentialInput, .mfaInput, .unknownHighImpact:
            return true
        }
    }
}

struct BrowserPageFingerprint: Equatable {
    let value: String
    let stateValue: String
    let url: String
    let title: String
    let controlCount: Int

    var jsonObject: [String: Any] {
        [
            "value": value,
            "stateValue": stateValue,
            "url": url,
            "title": title,
            "controlCount": controlCount
        ]
    }
}

struct BrowserControl {
    let controlID: String
    let identityHash: String
    let selector: String
    let label: String
    let name: String
    let role: String
    let tag: String
    let type: String
    let placeholder: String
    let testID: String
    let value: String
    let href: String
    let disabled: Bool
    let visible: Bool
    let actionable: Bool
    let bounds: [String: Any]
    let validActions: [BrowserActionKind]
    let primaryAction: BrowserActionKind?
    let actionOutcomes: [[String: Any]]
    let risk: BrowserRisk
    let confidence: Double
    let rank: Int
    let evidence: [String: Any]

    var requiresUserConfirmation: Bool {
        risk.requiresUserConfirmation
    }

    func supports(_ action: BrowserActionKind) -> Bool {
        validActions.contains(action)
    }

    func jsonObject(debug: Bool = false) -> [String: Any] {
        var object: [String: Any] = [
            "controlID": controlID,
            "label": label,
            "name": name,
            "role": role,
            "tag": tag,
            "type": type,
            "selector": selector,
            "placeholder": placeholder,
            "testID": testID,
            "value": value,
            "href": href,
            "state": disabled ? "disabled" : "enabled",
            "disabled": disabled,
            "visible": visible,
            "actionable": actionable,
            "bounds": bounds,
            "validActions": validActions.map(\.rawValue),
            "primaryAction": primaryAction?.rawValue ?? "",
            "actionOutcomes": actionOutcomes,
            "risk": risk.rawValue,
            "requiresUserConfirmation": requiresUserConfirmation,
            "confidence": confidence
        ]
        if debug {
            object["identityHash"] = identityHash
            object["rank"] = rank
            object["evidence"] = evidence
        } else {
            object["evidence"] = [
                "labelSource": evidence["labelSource"] as? String ?? "computed",
                "selectorSource": evidence["selectorSource"] as? String ?? "generated",
                "visible": visible,
                "enabled": !disabled
            ]
        }
        return object
    }
}

struct BrowserAnalysis {
    let analysisID: String
    let createdAt: Date
    let ttlSeconds: TimeInterval
    let backend: String
    let engine: String
    let fingerprint: BrowserPageFingerprint
    let pageType: String
    let summary: String
    let controls: [BrowserControl]
    let recommendations: [[String: Any]]
    let siteAdapters: [[String: Any]]

    var expiresAt: Date {
        createdAt.addingTimeInterval(ttlSeconds)
    }

    func isFresh(now: Date = Date()) -> Bool {
        now <= expiresAt
    }

    func control(id: String) -> BrowserControl? {
        controls.first { $0.controlID == id }
    }

    func responseObject(query: String?, full: Bool, limit: Int?, debug: Bool = false) -> [String: Any] {
        let normalizedQuery = BrowserAnalysisBuilder.normalized(query)
        let filtered = BrowserAnalysisBuilder.filteredControls(controls, query: normalizedQuery)
        let ranked = filtered.sorted { left, right in
            if left.rank == right.rank {
                return left.controlID < right.controlID
            }
            return left.rank > right.rank
        }
        let responseLimit = max(1, min(limit ?? (full ? 200 : 20), full ? 200 : 50))
        let returned = Array(ranked.prefix(responseLimit))

        var object: [String: Any] = [
            "ok": true,
            "analysisID": analysisID,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt),
            "ttlSeconds": ttlSeconds,
            "backend": backend,
            "engine": engine,
            "fingerprint": fingerprint.value,
            "stateFingerprint": fingerprint.stateValue,
            "fingerprintDetails": debug ? fingerprint.jsonObject : [:],
            "url": fingerprint.url,
            "title": fingerprint.title,
            "pageType": pageType,
            "summary": summary,
            "query": normalizedQuery ?? "",
            "full": full,
            "controlCount": controls.count,
            "matchedControlCount": ranked.count,
            "returnedControlCount": returned.count,
            "omittedControlCount": max(0, ranked.count - returned.count),
            "siteAdapters": siteAdapters,
            "controls": returned.map { $0.jsonObject(debug: debug) },
            "recommendedActions": recommendations
        ]
        if let ambiguity = BrowserAnalysisBuilder.ambiguityObject(for: ranked, query: normalizedQuery) {
            object["ambiguity"] = ambiguity
        }
        return object
    }
}

final class BrowserAnalysisCache {
    private var analyses: [String: BrowserAnalysis] = [:]
    private var order: [String] = []
    private let maxEntries: Int

    init(maxEntries: Int = 8) {
        self.maxEntries = max(1, maxEntries)
    }

    func store(_ analysis: BrowserAnalysis) {
        if analyses[analysis.analysisID] == nil {
            order.append(analysis.analysisID)
        }
        analyses[analysis.analysisID] = analysis
        while order.count > maxEntries {
            let id = order.removeFirst()
            analyses[id] = nil
        }
    }

    func lookup(_ analysisID: String) -> BrowserAnalysis? {
        analyses[analysisID]
    }

    func invalidate() {
        analyses.removeAll()
        order.removeAll()
    }
}

enum BrowserAnalysisBuilder {
    static let defaultTTLSeconds: TimeInterval = 30

    static func build(
        snapshot: [String: Any],
        backend: String,
        engine: String,
        createdAt: Date = Date(),
        analysisID: String? = nil,
        ttlSeconds: TimeInterval = defaultTTLSeconds,
        enabledBrowserAdapters: [String] = []
    ) -> BrowserAnalysis {
        let enabledAdapterIDs = BrowserSiteAdapterID.normalizedSet(enabledBrowserAdapters)
        let url = string(snapshot["url"])
        let title = string(snapshot["title"])
        let controlsObject = snapshot["controls"] as? [[String: Any]] ?? []
        let focused = snapshot["focusedElement"] as? [String: Any]
        let text = string(snapshot["text"])
        let viewport = snapshot["viewport"] as? [String: Any]
        let fingerprint = makeFingerprint(
            url: url,
            title: title,
            controls: controlsObject,
            focused: focused,
            text: text,
            viewport: viewport,
            engine: engine
        )
        let controls = controlsObject.enumerated().map { index, raw in
            makeControl(raw, index: index, pageURL: url, fingerprint: fingerprint, enabledBrowserAdapters: enabledAdapterIDs)
        }
        let pageType = inferPageType(url: url, title: title, text: text, controls: controls, enabledBrowserAdapters: enabledAdapterIDs)
        let recommendations = recommendedActions(pageType: pageType, controls: controls, enabledBrowserAdapters: enabledAdapterIDs)
        let resolvedAnalysisID = analysisID ?? makeAnalysisID(fingerprint: fingerprint, date: createdAt)
        let siteAdapters = activeSiteAdapters(url: url, enabledBrowserAdapters: enabledAdapterIDs)

        return BrowserAnalysis(
            analysisID: resolvedAnalysisID,
            createdAt: createdAt,
            ttlSeconds: ttlSeconds,
            backend: backend,
            engine: engine,
            fingerprint: fingerprint,
            pageType: pageType,
            summary: makeSummary(pageType: pageType, title: title, controls: controls),
            controls: controls,
            recommendations: recommendations,
            siteAdapters: siteAdapters
        )
    }

    static func filteredControls(_ controls: [BrowserControl], query: String?) -> [BrowserControl] {
        guard let query, !query.isEmpty else { return controls }
        return controls.filter { control in
            [
                control.label,
                control.name,
                control.role,
                control.tag,
                control.type,
                control.placeholder,
                control.testID,
                control.value,
                control.href,
                control.selector
            ].contains { $0.lowercased().contains(query) }
        }
    }

    static func ambiguityObject(for controls: [BrowserControl], query: String?) -> [String: Any]? {
        guard controls.count > 1 else { return nil }
        let visibleControls = Array(controls.prefix(12))
        let duplicateLabelGroups = Dictionary(grouping: visibleControls) { control in
            disambiguationKey(for: control)
        }
        let duplicateLabels = duplicateLabelGroups
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
            .map { key, values in
                [
                    "label": key,
                    "count": values.count,
                    "controlIDs": values.prefix(5).map(\.controlID)
                ] as [String: Any]
            }
            .sorted { left, right in
                let leftCount = left["count"] as? Int ?? 0
                let rightCount = right["count"] as? Int ?? 0
                return leftCount == rightCount
                    ? (left["label"] as? String ?? "") < (right["label"] as? String ?? "")
                    : leftCount > rightCount
            }

        guard query != nil || !duplicateLabels.isEmpty else { return nil }
        return [
            "type": duplicateLabels.isEmpty ? "multipleMatches" : "duplicateLabels",
            "matchCount": controls.count,
            "duplicateLabels": duplicateLabels,
            "controlIDs": visibleControls.map(\.controlID),
            "recommendedDisambiguators": [
                "visible label",
                "role",
                "bounds.centerY",
                "file type",
                "opened or modified time",
                "folder"
            ],
            "summary": "Multiple matching controls were found. Pick a controlID only after checking role, visible bounds, and nearby context."
        ]
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isGoogleDriveFileControl(
        pageURL: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        href: String
    ) -> Bool {
        GoogleDriveBrowserAdapter.isFileControl(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            href: href
        )
    }

    static func googleDriveNameHint(from label: String) -> String {
        GoogleDriveBrowserAdapter.nameHint(from: label)
    }

    static func fingerprintsCompatible(_ cached: BrowserPageFingerprint, _ current: BrowserPageFingerprint) -> Bool {
        cached.value == current.value
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func makeFingerprint(
        url: String,
        title: String,
        controls: [[String: Any]],
        focused: [String: Any]?,
        text: String,
        viewport: [String: Any]?,
        engine: String
    ) -> BrowserPageFingerprint {
        let components = URLComponents(string: url)
        let stableQueryNames = (components?.queryItems ?? [])
            .map(\.name)
            .filter { !$0.lowercased().contains("token") && !$0.lowercased().contains("session") }
            .sorted()
            .joined(separator: ",")
        let viewportBucket = [
            String((int(viewport?["width"]) ?? 0) / 100 * 100),
            String((int(viewport?["height"]) ?? 0) / 100 * 100)
        ].joined(separator: "x")
        let controlSignatures = controls.prefix(80).map { raw in
            [
                string(raw["selector"]),
                string(raw["role"]),
                string(raw["tag"]),
                string(raw["type"]),
                string(raw["label"]).lowercased(),
                string(raw["placeholder"]).lowercased(),
                string(raw["testID"]).lowercased(),
                bool(raw["disabled"]) ? "disabled" : "enabled"
            ].joined(separator: "|")
        }.joined(separator: "||")
        let structuralSeed = [
            engine,
            components?.host?.lowercased() ?? "",
            components?.path ?? "",
            stableQueryNames,
            title.lowercased(),
            viewportBucket,
            String(controls.count),
            controlSignatures
        ].joined(separator: "\u{1f}")
        let focusSeed = [
            string(focused?["selector"]),
            string(focused?["role"]),
            string(focused?["label"]),
            stableHash(string(focused?["value"]))
        ].joined(separator: "|")
        let stateSeed = [
            structuralSeed,
            focusSeed,
            stableHash(String(text.prefix(700)))
        ].joined(separator: "\u{1f}")
        return BrowserPageFingerprint(
            value: "fp_\(stableHash(structuralSeed).prefix(12))",
            stateValue: "st_\(stableHash(stateSeed).prefix(12))",
            url: url,
            title: title,
            controlCount: controls.count
        )
    }

    private static func makeControl(
        _ raw: [String: Any],
        index: Int,
        pageURL: String,
        fingerprint: BrowserPageFingerprint,
        enabledBrowserAdapters: Set<String>
    ) -> BrowserControl {
        let selector = string(raw["selector"])
        let label = string(raw["label"])
        let name = string(raw["name"])
        let role = string(raw["role"])
        let tag = string(raw["tag"])
        let type = string(raw["type"])
        let placeholder = string(raw["placeholder"])
        let testID = string(raw["testID"])
        let value = string(raw["value"])
        let href = string(raw["href"])
        let disabled = bool(raw["disabled"])
        let visible = true
        let actionable = bool(raw["actionable"]) && !disabled
        let bounds = raw["bounds"] as? [String: Any] ?? [:]
        let risk = classifyRisk(
            pageURL: pageURL,
            selector: selector,
            label: label,
            role: role,
            tag: tag,
            type: type,
            placeholder: placeholder,
            testID: testID,
            href: href
        )
        let actions = validActions(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            type: type,
            actionable: actionable,
            disabled: disabled,
            href: href,
            enabledBrowserAdapters: enabledBrowserAdapters
        )
        let primaryAction = primaryAction(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            type: type,
            actions: actions,
            enabledBrowserAdapters: enabledBrowserAdapters
        )
        let actionOutcomes = actionOutcomes(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            type: type,
            href: href,
            actions: actions,
            enabledBrowserAdapters: enabledBrowserAdapters
        )
        let identitySeed = [
            selector,
            role,
            label.lowercased(),
            name.lowercased(),
            tag,
            type,
            placeholder.lowercased(),
            testID.lowercased(),
            boundsBucket(bounds)
        ].joined(separator: "\u{1f}")
        let identityHash = stableHash(identitySeed)
        let slugSource = label.isEmpty ? (role.isEmpty ? tag : role) : label
        let rank = rankControl(
            label: label,
            role: role,
            tag: tag,
            type: type,
            testID: testID,
            placeholder: placeholder,
            actionable: actionable,
            disabled: disabled,
            risk: risk,
            index: index
        )
        let confidence = min(0.99, max(0.2, Double(rank) / 100.0))
        let controlID = [
            "ctl",
            slug(slugSource),
            String(fingerprint.value.dropFirst(3).prefix(6)),
            String(identityHash.prefix(8))
        ].joined(separator: "_")
        let evidence: [String: Any] = [
            "selectorSource": selectorSource(selector),
            "labelSource": label.isEmpty ? "missing" : "computed",
            "identityHash": identityHash,
            "sourceIndex": index,
            "visible": visible,
            "enabled": !disabled,
            "actionable": actionable
        ]

        return BrowserControl(
            controlID: controlID,
            identityHash: identityHash,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            type: type,
            placeholder: placeholder,
            testID: testID,
            value: value,
            href: href,
            disabled: disabled,
            visible: visible,
            actionable: actionable,
            bounds: bounds,
            validActions: actions,
            primaryAction: primaryAction,
            actionOutcomes: actionOutcomes,
            risk: risk,
            confidence: confidence,
            rank: rank,
            evidence: evidence
        )
    }

    private static func validActions(
        pageURL: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        type: String,
        actionable: Bool,
        disabled: Bool,
        href: String,
        enabledBrowserAdapters: Set<String>
    ) -> [BrowserActionKind] {
        guard !disabled else { return [] }
        let lowerRole = role.lowercased()
        let lowerTag = tag.lowercased()
        let lowerType = type.lowercased()
        var actions: [BrowserActionKind] = []
        let driveFile = GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters) && GoogleDriveBrowserAdapter.isFileControl(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            href: href
        )

        if lowerTag == "input" || lowerTag == "textarea" || lowerRole.contains("textbox") {
            actions.append(contentsOf: [.focus, .fill, .setValue])
        }
        if lowerTag == "select" || lowerRole.contains("combobox") {
            actions.append(contentsOf: [.focus, .select, .setValue])
        }
        if lowerRole.contains("checkbox") || lowerRole.contains("radio") {
            actions.append(.click)
        }
        if actionable || lowerTag == "button" || lowerTag == "a" || lowerRole.contains("button") || lowerRole.contains("link") || lowerType == "button" || lowerType == "submit" {
            actions.append(.click)
        }
        if driveFile {
            actions.append(contentsOf: [.select, .open, .doubleClick])
        } else if !href.isEmpty || lowerTag == "a" || lowerRole.contains("link") {
            actions.append(.open)
        }

        return Array(Set(actions)).sorted { $0.rawValue < $1.rawValue }
    }

    private static func primaryAction(
        pageURL: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        type: String,
        actions: [BrowserActionKind],
        enabledBrowserAdapters: Set<String>
    ) -> BrowserActionKind? {
        if GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters),
           GoogleDriveBrowserAdapter.isFileControl(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            href: ""
        ) {
            return .open
        }
        if actions.contains(.fill) { return .fill }
        if actions.contains(.setValue) { return .setValue }
        if actions.contains(.open) { return .open }
        return actions.first
    }

    private static func actionOutcomes(
        pageURL: String,
        selector: String,
        label: String,
        name: String,
        role: String,
        tag: String,
        type: String,
        href: String,
        actions: [BrowserActionKind],
        enabledBrowserAdapters: Set<String>
    ) -> [[String: Any]] {
        if GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters),
           GoogleDriveBrowserAdapter.isFileControl(
            pageURL: pageURL,
            selector: selector,
            label: label,
            name: name,
            role: role,
            tag: tag,
            href: href
        ) {
            return [
                [
                    "action": BrowserActionKind.click.rawValue,
                    "semanticAction": BrowserActionKind.select.rawValue,
                    "expectedOutcome": "driveFileSelected",
                    "goalSatisfiedWhen": "The file becomes selected. This does not mean the document opened.",
                    "doesNotGuarantee": "googleEditorOpened"
                ],
                [
                    "action": BrowserActionKind.doubleClick.rawValue,
                    "semanticAction": BrowserActionKind.open.rawValue,
                    "expectedOutcome": "googleEditorOpened",
                    "goalSatisfiedWhen": "The page URL or title changes to a Google Docs, Sheets, or Slides editor."
                ],
                [
                    "action": BrowserActionKind.googleDriveOpen.rawValue,
                    "adapterID": BrowserSiteAdapterID.googleDrive,
                    "semanticAction": BrowserActionKind.open.rawValue,
                    "expectedOutcome": "googleEditorOpened",
                    "preferred": true,
                    "goalSatisfiedWhen": "The bridge verifies that a matching Google Drive file opened."
                ]
            ]
        }

        if actions.contains(.fill) || actions.contains(.setValue) {
            return [
                [
                    "action": BrowserActionKind.fill.rawValue,
                    "semanticAction": "editValue",
                    "expectedOutcome": "valueChanged"
                ],
                [
                    "action": BrowserActionKind.setValue.rawValue,
                    "semanticAction": "replaceValue",
                    "expectedOutcome": "valueChanged"
                ]
            ]
        }

        if actions.contains(.open) {
            return [
                [
                    "action": BrowserActionKind.open.rawValue,
                    "semanticAction": BrowserActionKind.open.rawValue,
                    "expectedOutcome": href.isEmpty ? "navigationOrDisclosure" : "navigation",
                    "href": href
                ]
            ]
        }

        return actions.map { action in
            [
                "action": action.rawValue,
                "semanticAction": action.rawValue,
                "expectedOutcome": action == .click ? "activation" : "stateChange"
            ]
        }
    }

    private static func classifyRisk(
        pageURL: String,
        selector: String,
        label: String,
        role: String,
        tag: String,
        type: String,
        placeholder: String,
        testID: String,
        href: String
    ) -> BrowserRisk {
        let text = [
            selector,
            label,
            role,
            tag,
            type,
            placeholder,
            testID,
            href
        ].joined(separator: " ").lowercased()

        if type.lowercased() == "password" || containsAny(text, ["password", "passcode", "secret"]) {
            return .credentialInput
        }
        if containsAny(text, ["mfa", "2fa", "two factor", "two-factor", "verification code", "security code", "otp", "one-time"]) {
            return .mfaInput
        }
        if containsAny(text, ["delete", "remove", "destroy", "discard", "revoke", "terminate", "erase"]) {
            return .destructive
        }
        if containsAny(text, ["purchase", "buy now", "place order", "checkout"]) {
            return .purchase
        }
        if containsAny(text, ["pay", "payment", "billing", "credit card", "card number"]) {
            return .payment
        }
        if containsAny(text, ["authorize", "approve", "grant", "allow access", "permission", "consent"]) {
            return .authorization
        }
        let lowerTag = tag.lowercased()
        let lowerRole = role.lowercased()
        let isEditable = lowerTag == "input" || lowerTag == "textarea" || lowerRole.contains("textbox")
        if !isEditable, containsAny(text, ["send", "email", "message", "post", "publish", "comment", "reply"]) {
            return .sendMessage
        }
        if type.lowercased() == "submit" || containsAny(text, ["submit", "confirm"]) {
            return .formSubmit
        }
        if !href.isEmpty {
            let pageHost = URL(string: pageURL)?.host?.lowercased()
            let hrefHost = URL(string: href)?.host?.lowercased()
            if let pageHost, let hrefHost, pageHost != hrefHost {
                return .externalNavigation
            }
            return .navigation
        }
        if containsAny(text, ["ssn", "social security", "date of birth", "dob", "medical record", "mrn"]) {
            return .privacySensitive
        }
        return .normal
    }

    private static func rankControl(
        label: String,
        role: String,
        tag: String,
        type: String,
        testID: String,
        placeholder: String,
        actionable: Bool,
        disabled: Bool,
        risk: BrowserRisk,
        index: Int
    ) -> Int {
        var score = max(0, 30 - min(index, 30) / 3)
        if actionable { score += 25 }
        if !disabled { score += 15 }
        if !label.isEmpty { score += 20 }
        if !testID.isEmpty { score += 15 }
        if !placeholder.isEmpty { score += 10 }
        if ["button", "link", "textbox", "combobox"].contains(role.lowercased()) { score += 10 }
        if tag.lowercased() == "button" || type.lowercased() == "submit" { score += 8 }
        if risk.requiresUserConfirmation { score -= 10 }
        return score
    }

    private static func inferPageType(
        url: String,
        title: String,
        text: String,
        controls: [BrowserControl],
        enabledBrowserAdapters: Set<String>
    ) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        let path = URL(string: url)?.path.lowercased() ?? ""
        if host == "docs.google.com", path.hasPrefix("/document/") { return "googleDocsEditor" }
        if host == "docs.google.com", path.hasPrefix("/spreadsheets/") { return "googleSheetsEditor" }
        if host == "docs.google.com", path.hasPrefix("/presentation/") { return "googleSlidesEditor" }
        if host == "drive.google.com", GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters) { return "googleDrive" }
        if controls.contains(where: { $0.risk == .credentialInput }) { return "login" }
        if controls.contains(where: { $0.placeholder.lowercased().contains("search") || $0.label.lowercased().contains("search") }) { return "search" }
        let editableCount = controls.filter { $0.validActions.contains(.fill) || $0.validActions.contains(.setValue) }.count
        if editableCount >= 2 { return "form" }
        let clickableCount = controls.filter { $0.validActions.contains(.click) }.count
        if clickableCount >= 20 { return "dashboard" }
        let combined = "\(title) \(text.prefix(300))".lowercased()
        if containsAny(combined, ["settings", "preferences"]) { return "settings" }
        return "unknown"
    }

    private static func recommendedActions(
        pageType: String,
        controls: [BrowserControl],
        enabledBrowserAdapters: Set<String>
    ) -> [[String: Any]] {
        switch pageType {
        case "googleDocsEditor":
            return [
                ["action": BrowserActionKind.googleDocsFind.rawValue, "reason": "Google Docs content may be canvas-rendered."],
                ["action": BrowserActionKind.googleDocsInsert.rawValue, "reason": "Use the document helper for reliable insertion."],
                ["action": BrowserActionKind.googleFindReplace.rawValue, "reason": "Use the Google editor find/replace helper for text swaps."]
            ]
        case "googleSheetsEditor", "googleSlidesEditor":
            return [
                ["action": BrowserActionKind.googleFindReplace.rawValue, "reason": "Use the Google editor find/replace helper for text swaps."]
            ]
        case "googleDrive":
            return GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters)
                ? GoogleDriveBrowserAdapter.recommendations
                : []
        default:
            return controls
                .filter { !$0.requiresUserConfirmation && !$0.validActions.isEmpty }
                .sorted { $0.rank > $1.rank }
                .prefix(5)
                .map { control in
                    [
                        "action": control.validActions.first?.rawValue ?? "",
                        "controlID": control.controlID,
                        "reason": "High-confidence \(control.role.isEmpty ? control.tag : control.role) control"
                    ]
                }
        }
    }

    private static func activeSiteAdapters(url: String, enabledBrowserAdapters: Set<String>) -> [[String: Any]] {
        [GoogleDriveBrowserAdapter.activeMetadata(pageURL: url, enabledAdapterIDs: enabledBrowserAdapters)].compactMap { $0 }
    }

    private static func makeSummary(pageType: String, title: String, controls: [BrowserControl]) -> String {
        let editableCount = controls.filter { $0.validActions.contains(.fill) || $0.validActions.contains(.setValue) }.count
        let clickableCount = controls.filter { $0.validActions.contains(.click) }.count
        let dangerousCount = controls.filter(\.requiresUserConfirmation).count
        let displayTitle = title.isEmpty ? "Untitled page" : title
        return "\(displayTitle): \(pageType) page with \(controls.count) controls, \(editableCount) editable, \(clickableCount) clickable, \(dangerousCount) requiring confirmation."
    }

    private static func makeAnalysisID(fingerprint: BrowserPageFingerprint, date: Date) -> String {
        let millis = Int(date.timeIntervalSince1970 * 1000)
        return "ana_\(fingerprint.value.dropFirst(3))_\(millis)"
    }

    private static func selectorSource(_ selector: String) -> String {
        if selector.hasPrefix("#") { return "id" }
        if selector.contains("data-testid") || selector.contains("data-test") { return "testID" }
        if selector.contains("aria-label") { return "ariaLabel" }
        return selector.isEmpty ? "missing" : "generated"
    }

    private static func boundsBucket(_ bounds: [String: Any]) -> String {
        let x = (int(bounds["x"]) ?? 0) / 20 * 20
        let y = (int(bounds["y"]) ?? 0) / 20 * 20
        let width = (int(bounds["width"]) ?? 0) / 20 * 20
        let height = (int(bounds["height"]) ?? 0) / 20 * 20
        return "\(x),\(y),\(width),\(height)"
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func disambiguationKey(for control: BrowserControl) -> String {
        var value = control.label.isEmpty ? control.name : control.label
        let removablePatterns = [
            #"More actions"#,
            #"More info \(Option \+ [^)]+\)"#,
            #"You opened • [^A-Z\n]+"#,
            #"You edited • [^A-Z\n]+"#,
            #"Located in [^A-Z\n]+"#
        ]
        for pattern in removablePatterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func slug(_ value: String) -> String {
        let lower = value.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((collapsed.isEmpty ? "control" : collapsed).prefix(24))
    }

    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

enum BrowserActionOutcomeVerifier {
    static func outcome(
        action: BrowserActionKind,
        control: BrowserControl?,
        result: [String: Any],
        before: [String: Any]?,
        after: [String: Any]?,
        enabledBrowserAdapters: [String] = []
    ) -> [String: Any] {
        let enabledAdapterIDs = BrowserSiteAdapterID.normalizedSet(enabledBrowserAdapters)
        let executed = bool(result["ok"])
        let beforeURL = string(before?["url"])
        let afterURL = string(after?["url"])
        let beforeTitle = string(before?["title"])
        let afterTitle = string(after?["title"])
        let expected = expectedOutcome(
            action: action,
            control: control,
            beforeURL: beforeURL,
            enabledBrowserAdapters: enabledAdapterIDs
        )
        let observed = observedOutcome(
            action: action,
            control: control,
            result: result,
            beforeURL: beforeURL,
            afterURL: afterURL,
            beforeTitle: beforeTitle,
            afterTitle: afterTitle,
            after: after
        )
        let knownDriveFile = control.map {
            GoogleDriveBrowserAdapter.isEnabled(in: enabledAdapterIDs) && GoogleDriveBrowserAdapter.isFileControl(
                pageURL: beforeURL.isEmpty ? afterURL : beforeURL,
                selector: $0.selector,
                label: $0.label,
                name: $0.name,
                role: $0.role,
                tag: $0.tag,
                href: $0.href
            )
        } ?? false
        let goalSatisfied: Bool
        let outcomeVerified: Bool
        let reason: String

        if !executed {
            goalSatisfied = false
            outcomeVerified = true
            reason = "The browser action did not execute successfully."
        } else if knownDriveFile {
            goalSatisfied = observed == "googleEditorOpened"
            outcomeVerified = true
            reason = goalSatisfied
                ? "The Google Drive file opened in an editor."
                : "The Google Drive file control was activated, but the page did not open a Google editor. Treat this as selection, not completion."
        } else if [.fill, .setValue, .insertText].contains(action) {
            goalSatisfied = observed == "valueChanged" || executed
            outcomeVerified = observed == "valueChanged" || executed
            reason = goalSatisfied ? "The edit action executed." : "The edit action did not produce a verified value change."
        } else if expected == "navigation" {
            goalSatisfied = observed == "navigation" || observed == "googleEditorOpened"
            outcomeVerified = true
            reason = goalSatisfied ? "The page navigated after the action." : "The action executed, but the URL did not change."
        } else {
            goalSatisfied = observed == "navigation" || observed == "googleEditorOpened" || observed == "pageChanged"
            outcomeVerified = goalSatisfied
            reason = goalSatisfied
                ? "The page changed after the action."
                : "The action executed, but no specific page-level outcome was verified."
        }

        var object: [String: Any] = [
            "executed": executed,
            "expectedOutcome": expected,
            "observedOutcome": observed,
            "goalSatisfied": goalSatisfied,
            "outcomeVerified": outcomeVerified,
            "outcomeReason": reason,
            "beforeURL": beforeURL,
            "afterURL": afterURL,
            "beforeTitle": beforeTitle,
            "afterTitle": afterTitle
        ]
        let suggestions = suggestedNextActions(
            action: action,
            control: control,
            knownDriveFile: knownDriveFile,
            observedOutcome: observed,
            goalSatisfied: goalSatisfied
        )
        if !suggestions.isEmpty {
            object["suggestedNextActions"] = suggestions
        }
        return object
    }

    private static func expectedOutcome(
        action: BrowserActionKind,
        control: BrowserControl?,
        beforeURL: String,
        enabledBrowserAdapters: Set<String>
    ) -> String {
        if let control,
           GoogleDriveBrowserAdapter.isEnabled(in: enabledBrowserAdapters),
           GoogleDriveBrowserAdapter.isFileControl(
            pageURL: beforeURL,
            selector: control.selector,
            label: control.label,
            name: control.name,
            role: control.role,
            tag: control.tag,
            href: control.href
           ) {
            switch action {
            case .click, .select:
                return "driveFileSelected"
            case .doubleClick, .open, .googleDriveOpen:
                return "googleEditorOpened"
            default:
                return "driveFileStateChanged"
            }
        }
        if [.fill, .setValue, .insertText].contains(action) {
            return "valueChanged"
        }
        if control?.href.isEmpty == false || action == .open {
            return "navigation"
        }
        return action == .click ? "activation" : "stateChange"
    }

    private static func observedOutcome(
        action: BrowserActionKind,
        control: BrowserControl?,
        result: [String: Any],
        beforeURL: String,
        afterURL: String,
        beforeTitle: String,
        afterTitle: String,
        after: [String: Any]?
    ) -> String {
        if isGoogleEditorURL(afterURL) {
            return "googleEditorOpened"
        }
        if !beforeURL.isEmpty, !afterURL.isEmpty, beforeURL != afterURL {
            return "navigation"
        }
        if [.fill, .setValue, .insertText].contains(action), bool(result["ok"]) {
            return "valueChanged"
        }
        if let control, focusMatches(control: control, snapshot: after) {
            return "selectedOrFocused"
        }
        if !beforeTitle.isEmpty, !afterTitle.isEmpty, beforeTitle != afterTitle {
            return "pageChanged"
        }
        if bool(result["clicked"]) {
            return "clickedNoPageChange"
        }
        return bool(result["ok"]) ? "executedNoObservedChange" : "notExecuted"
    }

    private static func suggestedNextActions(
        action: BrowserActionKind,
        control: BrowserControl?,
        knownDriveFile: Bool,
        observedOutcome: String,
        goalSatisfied: Bool
    ) -> [[String: Any]] {
        guard knownDriveFile, !goalSatisfied else { return [] }
        let label = control?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            [
                "action": BrowserActionKind.googleDriveOpen.rawValue,
                "adapterID": BrowserSiteAdapterID.googleDrive,
                "reason": "Use the Drive open helper because it verifies that the file opened.",
                "nameHint": GoogleDriveBrowserAdapter.nameHint(from: label)
            ],
            [
                "action": BrowserActionKind.doubleClick.rawValue,
                "reason": "A Drive grid click may only select the file; opening usually needs double-click or Enter after selection."
            ],
            [
                "action": "keypress",
                "key": "Enter",
                "reason": "Use only after confirming the intended Drive file is selected."
            ]
        ]
    }

    private static func focusMatches(control: BrowserControl, snapshot: [String: Any]?) -> Bool {
        guard let focused = snapshot?["focusedElement"] as? [String: Any] else { return false }
        let focusedSelector = string(focused["selector"])
        let focusedLabel = string(focused["label"])
        if !control.selector.isEmpty, focusedSelector == control.selector {
            return true
        }
        if !control.label.isEmpty, focusedLabel == control.label {
            return true
        }
        return false
    }

    private static func isGoogleEditorURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.host?.lowercased() == "docs.google.com" else {
            return false
        }
        let path = components.path.lowercased()
        return path.hasPrefix("/document/")
            || path.hasPrefix("/spreadsheets/")
            || path.hasPrefix("/presentation/")
    }

    private static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
