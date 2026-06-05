import Foundation

enum ShelfBrowserCommandNormalization {
    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
