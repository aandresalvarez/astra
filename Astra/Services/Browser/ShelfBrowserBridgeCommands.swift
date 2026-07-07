import Foundation

enum ShelfBrowserCommandNormalization {
    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum BrowserDangerousActionApproval {
    /// Browser bridge payloads are provider-controlled. A boolean in that
    /// payload is not user consent, so it must never satisfy ASTRA's dangerous
    /// action confirmation gate.
    static func trustedProviderApproval(_ allowDangerous: Bool?) -> Bool {
        false
    }
}

struct NavigateCommand: Decodable {
    let url: String
}

struct ClickCommand: Decodable {
    let analysisID: String?
    let controlID: String?
    let selector: String?
    let label: String?
    let role: String?
    let text: String?
    let placeholder: String?
    let testID: String?
    let x: Double?
    let y: Double?
    let allowDangerous: Bool?
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?

    var normalizedSelector: String? { ShelfBrowserCommandNormalization.normalized(selector) }
    var normalizedLabel: String? { ShelfBrowserCommandNormalization.normalized(label) }
    var normalizedRole: String? { ShelfBrowserCommandNormalization.normalized(role) }
    var normalizedText: String? { ShelfBrowserCommandNormalization.normalized(text) }
    var normalizedPlaceholder: String? { ShelfBrowserCommandNormalization.normalized(placeholder) }
    var normalizedTestID: String? { ShelfBrowserCommandNormalization.normalized(testID) }
    var hasAnalysisControl: Bool {
        ShelfBrowserCommandNormalization.normalized(analysisID) != nil
            && ShelfBrowserCommandNormalization.normalized(controlID) != nil
    }
}

struct TypeCommand: Decodable {
    let analysisID: String?
    let controlID: String?
    let selector: String?
    let text: String
    let clear: Bool?
    let label: String?
    let role: String?
    let placeholder: String?
    let testID: String?
    let allowDangerous: Bool?

    var normalizedSelector: String? { ShelfBrowserCommandNormalization.normalized(selector) }
    var normalizedLabel: String? { ShelfBrowserCommandNormalization.normalized(label) }
    var normalizedRole: String? { ShelfBrowserCommandNormalization.normalized(role) }
    var normalizedPlaceholder: String? { ShelfBrowserCommandNormalization.normalized(placeholder) }
    var normalizedTestID: String? { ShelfBrowserCommandNormalization.normalized(testID) }
    var hasAnalysisControl: Bool {
        ShelfBrowserCommandNormalization.normalized(analysisID) != nil
            && ShelfBrowserCommandNormalization.normalized(controlID) != nil
    }
}

struct ReplaceTextCommand: Decodable {
    let analysisID: String?
    let controlID: String?
    let find: String
    let replacement: String
    let selector: String?
    let all: Bool?
    let allowDangerous: Bool?

    var normalizedSelector: String? {
        ShelfBrowserCommandNormalization.normalized(selector)
    }
    var hasAnalysisControl: Bool {
        ShelfBrowserCommandNormalization.normalized(analysisID) != nil
            && ShelfBrowserCommandNormalization.normalized(controlID) != nil
    }
}

struct ClickControlCommand: Decodable {
    let analysisID: String?
    let controlID: String?
    let label: String?
    let role: String?
    let allowDangerous: Bool?

    var normalizedLabel: String? {
        ShelfBrowserCommandNormalization.normalized(label)
    }

    var hasAnalysisControl: Bool {
        ShelfBrowserCommandNormalization.normalized(analysisID) != nil
            && ShelfBrowserCommandNormalization.normalized(controlID) != nil
    }
}

struct BrowserPreflightCommand: Decodable {
    let analysisID: String?
    let controlID: String?
    let action: String
    let allowDangerous: Bool?
}

struct BrowserPreflightExecution {
    let ok: Bool
    let cachedControl: BrowserControl?
    let currentControl: BrowserControl?
    let currentControlRef: BrowserControlRef?
    let resolutionStrategy: String
    let response: [String: Any]
}

struct BrowserControlActionTarget {
    let selector: String?
    let x: Double?
    let y: Double?
    let label: String?
    let role: String?
    let placeholder: String?
    let testID: String?
    let source: String
    let usedSelector: Bool
}

enum BrowserControlTargetingPolicy {
    static func semanticName(for control: BrowserControl, source: BrowserControlSource) -> String {
        if source == .dom {
            return control.name.isEmpty ? control.label : control.name
        }
        return control.label.isEmpty ? control.name : control.label
    }

    static func stableDOMIdentityMatches(cachedControl: BrowserControl, liveControl: BrowserControl) -> Bool {
        if !cachedControl.controlID.isEmpty, cachedControl.controlID == liveControl.controlID {
            return true
        }
        guard sameDOMScope(cachedControl, liveControl) else {
            return false
        }
        if !cachedControl.selector.isEmpty, cachedControl.selector == liveControl.selector {
            return true
        }
        if !cachedControl.name.isEmpty, cachedControl.name == liveControl.name, compatibleElementShape(cachedControl, liveControl) {
            return true
        }
        if !cachedControl.testID.isEmpty, cachedControl.testID == liveControl.testID, compatibleElementShape(cachedControl, liveControl) {
            return true
        }
        return false
    }

    private static func sameDOMScope(_ left: BrowserControl, _ right: BrowserControl) -> Bool {
        left.framePath == right.framePath && left.shadowDepth == right.shadowDepth
    }

    private static func compatibleElementShape(_ left: BrowserControl, _ right: BrowserControl) -> Bool {
        (left.tag.isEmpty || right.tag.isEmpty || left.tag == right.tag)
            && (left.type.isEmpty || right.type.isEmpty || left.type == right.type)
    }
}

struct VerifyTextCommand: Decodable {
    let text: String
    let absent: Bool?
}

struct WaitSavedCommand: Decodable {
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?
}

struct GoogleFindReplaceCommand: Decodable {
    let find: String
    let replacement: String
    let all: Bool?
}

struct GoogleDocsFindCommand: Decodable {
    let query: String
    let closeFindBar: Bool?
}

struct GoogleDocsInsertCommand: Decodable {
    let text: String
    let verifyText: String?
    let waitSaved: Bool?

    var normalizedVerifyText: String? {
        ShelfBrowserCommandNormalization.normalized(verifyText)
    }
}

struct GoogleDocsReplaceDocumentCommand: Decodable {
    let text: String
    let verifyText: String?

    var normalizedVerifyText: String? {
        ShelfBrowserCommandNormalization.normalized(verifyText)
    }
}

struct GoogleDriveOpenCommand: Decodable {
    let name: String
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ActCommand: Decodable {
    let analysisID: String?
    let controlID: String?
    let setAnalysisID: String?
    let setControlID: String?
    let clickAnalysisID: String?
    let clickControlID: String?
    let find: String?
    let set: String?
    let role: String?
    let click: String?
    let clickRole: String?
    let allowDangerous: Bool?
    let waitSaved: Bool?
    let verify: String?
    let absent: String?
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?
}

struct KeypressCommand: Decodable {
    let key: String
    let modifiers: [String]?
}

struct TextCommand: Decodable {
    let text: String
}

struct PageReadCommand: Decodable {
    let format: String?
    let limit: Int?
    let chunkSize: Int?
}

struct WaitTextCommand: Decodable {
    let text: String
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?
}

struct WaitSelectorCommand: Decodable {
    let selector: String
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?
}

struct BatchCommand: Decodable {
    let actions: [BatchActionCommand]
    let snapshotMode: String?
    let snapshotQuery: String?
    let snapshotLimit: Int?
}

struct BatchActionCommand: Decodable {
    let action: String
    let analysisID: String?
    let controlID: String?
    let url: String?
    let selector: String?
    let label: String?
    let role: String?
    let placeholder: String?
    let testID: String?
    let x: Double?
    let y: Double?
    let allowDangerous: Bool?
    let name: String?
    let text: String?
    let find: String?
    let replacement: String?
    let set: String?
    let click: String?
    let clickRole: String?
    let waitSaved: Bool?
    let verify: String?
    let absentText: String?
    let all: Bool?
    let absent: Bool?
    let clear: Bool?
    let key: String?
    let modifiers: [String]?
    let timeoutSeconds: Double?
    let intervalMilliseconds: Int?
    let mode: String?
    let format: String?
    let query: String?
    let limit: Int?
    let chunkSize: Int?
    let closeFindBar: Bool?
    let full: Bool?
    let debug: Bool?
    let v2: Bool?
    let version: String?
    let analysisVersion: String?
    let preflightAction: String?

    var normalizedAction: String {
        action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedSelector: String? {
        ShelfBrowserCommandNormalization.normalized(selector)
    }

    var normalizedLabel: String? { ShelfBrowserCommandNormalization.normalized(label) }
    var normalizedRole: String? { ShelfBrowserCommandNormalization.normalized(role) }
    var normalizedPlaceholder: String? { ShelfBrowserCommandNormalization.normalized(placeholder) }
    var normalizedTestID: String? { ShelfBrowserCommandNormalization.normalized(testID) }
    var hasAnalysisControl: Bool {
        ShelfBrowserCommandNormalization.normalized(analysisID) != nil
            && ShelfBrowserCommandNormalization.normalized(controlID) != nil
    }
}

enum ShelfBrowserBridgeBatchActionRequest {
    case request(BrowserBridgeRequest)
    case failure([String: Any], stopReason: String?)
}

enum ShelfBrowserBridgeBatchRequestFactory {
    static let supportedRoutes: Set<ShelfBrowserBridgeRoute> = [
        .analyze,
        .preflight,
        .snapshot,
        .navigate,
        .type,
        .setValue,
        .replaceText,
        .findControl,
        .clickControl,
        .verifyText,
        .waitSaved,
        .googleFindReplace,
        .googleDocsFind,
        .googleDocsInsert,
        .googleDocsReadVisiblePage,
        .googleDocsReadDocument,
        .googleDocsReplaceDocument,
        .googleDriveOpen,
        .act,
        .click,
        .open,
        .doubleClick,
        .fill,
        .keypress,
        .text,
        .waitForText,
        .waitForSelector
    ]

    static func makeRequest(
        route: ShelfBrowserBridgeRoute,
        action: BatchActionCommand
    ) throws -> ShelfBrowserBridgeBatchActionRequest {
        guard supportedRoutes.contains(route) else {
            return .failure(unknownActionResult(action: action), stopReason: nil)
        }

        switch route {
        case .analyze:
            return try request(route: route, query: [
                ("query", action.query),
                ("full", action.full ?? (action.mode?.lowercased() == "full")),
                ("limit", action.limit),
                ("debug", action.debug ?? false),
                ("v2", action.v2),
                ("version", action.analysisVersion ?? action.version)
            ])
        case .preflight:
            guard action.hasAnalysisControl else {
                return missingField(action: action, error: "missing_analysis_or_control", stop: true)
            }
            return try request(route: route, body: [
                ("analysisID", action.analysisID),
                ("controlID", action.controlID),
                ("action", action.preflightAction ?? action.action),
                ("allowDangerous", action.allowDangerous)
            ])
        case .snapshot:
            let mode = BrowserSnapshotMode(rawValue: action.mode ?? "summary") ?? .summary
            return try request(route: route, query: [
                ("mode", mode.rawValue),
                ("query", action.query),
                ("limit", action.limit)
            ])
        case .navigate:
            guard let url = action.url else {
                return .failure(["ok": false, "action": action.action, "error": "invalid_url"], stopReason: nil)
            }
            return try request(route: route, body: [("url", url)])
        case .click, .doubleClick:
            return try request(route: route, body: clickPayload(action: action))
        case .open:
            guard action.hasAnalysisControl else {
                return missingField(action: action, error: "missing_analysis_or_control", stop: true)
            }
            return try request(route: route, body: clickPayload(action: action) + [
                ("timeoutSeconds", action.timeoutSeconds),
                ("intervalMilliseconds", action.intervalMilliseconds)
            ])
        case .type:
            guard let text = action.text else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: typePayload(action: action, text: text, clear: action.clear))
        case .setValue, .fill:
            guard let text = action.text else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: typePayload(action: action, text: text, clear: true))
        case .replaceText:
            guard let find = action.find,
                  let replacement = action.replacement ?? action.text else {
                return missingField(action: action, error: "missing_find_or_replacement")
            }
            return try request(route: route, body: [
                ("analysisID", action.analysisID),
                ("controlID", action.controlID),
                ("find", find),
                ("replacement", replacement),
                ("selector", action.normalizedSelector),
                ("all", action.all),
                ("allowDangerous", action.allowDangerous)
            ])
        case .findControl:
            return try request(route: route, query: [
                ("query", action.query ?? action.label ?? ""),
                ("role", action.role),
                ("limit", action.limit)
            ])
        case .clickControl:
            return try request(route: route, body: [
                ("analysisID", action.analysisID),
                ("controlID", action.controlID),
                ("label", action.label ?? action.query),
                ("role", action.role),
                ("allowDangerous", action.allowDangerous)
            ])
        case .verifyText:
            guard let text = action.text ?? action.query else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: [
                ("text", text),
                ("absent", action.absent)
            ])
        case .waitSaved:
            return try request(route: route, body: [
                ("timeoutSeconds", action.timeoutSeconds),
                ("intervalMilliseconds", action.intervalMilliseconds)
            ])
        case .googleFindReplace:
            guard let find = action.find,
                  let replacement = action.replacement ?? action.text else {
                return missingField(action: action, error: "missing_find_or_replacement")
            }
            return try request(route: route, body: [
                ("find", find),
                ("replacement", replacement),
                ("all", action.all)
            ])
        case .googleDocsFind:
            guard let query = action.query ?? action.text ?? action.verify else {
                return missingField(action: action, error: "missing_query")
            }
            return try request(route: route, body: [
                ("query", query),
                ("closeFindBar", action.closeFindBar)
            ])
        case .googleDocsInsert:
            guard let text = action.text else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: [
                ("text", text),
                ("verifyText", action.verify ?? action.query),
                ("waitSaved", action.waitSaved)
            ])
        case .googleDocsReadVisiblePage:
            return try request(route: route, body: [
                ("format", action.format ?? "markdown"),
                ("limit", action.limit),
                ("chunkSize", action.chunkSize)
            ])
        case .googleDocsReadDocument:
            return try request(route: route)
        case .googleDocsReplaceDocument:
            guard let text = action.text else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: [
                ("text", text),
                ("verifyText", action.verify ?? action.query)
            ])
        case .googleDriveOpen:
            guard let name = action.name ?? action.query ?? action.text else {
                return missingField(action: action, error: "missing_name")
            }
            return try request(route: route, body: [
                ("name", name),
                ("timeoutSeconds", action.timeoutSeconds),
                ("intervalMilliseconds", action.intervalMilliseconds)
            ])
        case .act:
            return try request(route: route, body: [
                ("analysisID", action.analysisID),
                ("controlID", action.controlID),
                ("setAnalysisID", nil),
                ("setControlID", nil),
                ("clickAnalysisID", nil),
                ("clickControlID", nil),
                ("find", action.find ?? action.query),
                ("set", action.set ?? action.text),
                ("role", action.role),
                ("click", action.click ?? action.label),
                ("clickRole", action.clickRole),
                ("allowDangerous", action.allowDangerous),
                ("waitSaved", action.waitSaved),
                ("verify", action.verify),
                ("absent", action.absentText ?? (action.absent == true ? action.text : nil)),
                ("timeoutSeconds", action.timeoutSeconds),
                ("intervalMilliseconds", action.intervalMilliseconds)
            ])
        case .keypress:
            guard let key = action.key else {
                return missingField(action: action, error: "missing_key")
            }
            return try request(route: route, body: [
                ("key", key),
                ("modifiers", action.modifiers)
            ])
        case .text:
            guard let text = action.text else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: [("text", text)])
        case .waitForText:
            guard let text = action.text else {
                return missingField(action: action, error: "missing_text")
            }
            return try request(route: route, body: [
                ("text", text),
                ("timeoutSeconds", action.timeoutSeconds),
                ("intervalMilliseconds", action.intervalMilliseconds)
            ])
        case .waitForSelector:
            guard let selector = action.normalizedSelector else {
                return missingField(action: action, error: "missing_selector")
            }
            return try request(route: route, body: [
                ("selector", selector),
                ("timeoutSeconds", action.timeoutSeconds),
                ("intervalMilliseconds", action.intervalMilliseconds)
            ])
        case .health, .actions, .trace, .benchmark, .readPage, .locator, .batch:
            return .failure(unknownActionResult(action: action), stopReason: nil)
        }
    }

    private static func request(
        route: ShelfBrowserBridgeRoute,
        query: [(String, Any?)] = [],
        body: [(String, Any?)] = []
    ) throws -> ShelfBrowserBridgeBatchActionRequest {
        guard let command = ShelfBrowserBridgeCommandRouter.command(for: route) else {
            return .failure(["ok": false, "error": "unknown_action"], stopReason: nil)
        }

        let requestBody: Data
        if command.method == "POST" {
            requestBody = try JSONSerialization.data(withJSONObject: compact(body))
        } else {
            requestBody = Data()
        }

        return .request(BrowserBridgeRequest(
            method: command.method,
            path: command.path,
            headers: [:],
            queryItems: queryItems(query),
            body: requestBody
        ))
    }

    private static func clickPayload(action: BatchActionCommand) -> [(String, Any?)] {
        [
            ("analysisID", action.analysisID),
            ("controlID", action.controlID),
            ("selector", action.normalizedSelector),
            ("label", action.normalizedLabel),
            ("role", action.normalizedRole),
            ("text", action.text),
            ("placeholder", action.normalizedPlaceholder),
            ("testID", action.normalizedTestID),
            ("x", action.x),
            ("y", action.y),
            ("allowDangerous", action.allowDangerous)
        ]
    }

    private static func typePayload(
        action: BatchActionCommand,
        text: String,
        clear: Bool?
    ) -> [(String, Any?)] {
        [
            ("analysisID", action.analysisID),
            ("controlID", action.controlID),
            ("selector", action.normalizedSelector),
            ("text", text),
            ("clear", clear),
            ("label", action.normalizedLabel),
            ("role", action.normalizedRole),
            ("placeholder", action.normalizedPlaceholder),
            ("testID", action.normalizedTestID),
            ("allowDangerous", action.allowDangerous)
        ]
    }

    private static func missingField(
        action: BatchActionCommand,
        error: String,
        stop: Bool = false
    ) -> ShelfBrowserBridgeBatchActionRequest {
        .failure(["ok": false, "action": action.action, "error": error], stopReason: stop ? error : nil)
    }

    private static func unknownActionResult(action: BatchActionCommand) -> [String: Any] {
        ["ok": false, "action": action.action, "error": "unknown_action"]
    }

    private static func compact(_ values: [(String, Any?)]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (key, value) in values {
            if let value {
                object[key] = value
            }
        }
        return object
    }

    private static func queryItems(_ values: [(String, Any?)]) -> [String: String] {
        var object: [String: String] = [:]
        for (key, value) in values {
            if let string = stringValue(value) {
                object[key] = string
            }
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let string as String:
            return string
        default:
            return String(describing: value)
        }
    }
}
