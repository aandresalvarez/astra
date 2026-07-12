import Foundation
import ASTRAModels

enum BrowserAutomationEngineKind: String, CaseIterable, Sendable {
    case embeddedWebKit = "embedded-webkit"
    case controlledCDP = "controlled-cdp"
    case playwrightCDP = "playwright-cdp"
}

struct BrowserAutomationEngineDescriptor: Equatable, Sendable {
    let kind: BrowserAutomationEngineKind

    var providerToolName: String { "astra-browser" }

    var label: String {
        switch kind {
        case .embeddedWebKit: "Embedded"
        case .controlledCDP: "Controlled"
        case .playwrightCDP: "Playwright"
        }
    }

    var bridgeBackendLabel: String {
        switch kind {
        case .embeddedWebKit: "embedded WebKit"
        case .controlledCDP: "controlled Chromium profile"
        case .playwrightCDP: "Playwright-controlled Chromium profile"
        }
    }

    /// The provider must only see ASTRA's task-bound bridge, never the raw
    /// CDP/WebSocket implementation endpoint that powers a concrete engine.
    var exposesRawDebugEndpoint: Bool { false }

    var jsonObject: [String: Any] {
        [
            "kind": kind.rawValue,
            "label": label,
            "backend": bridgeBackendLabel,
            "providerToolName": providerToolName,
            "exposesRawDebugEndpoint": exposesRawDebugEndpoint
        ]
    }
}

protocol BrowserAutomationEngineDescribing {
    var automationDescriptor: BrowserAutomationEngineDescriptor { get }
    var bridgeBackendLabel: String { get }
}

extension ShelfBrowserEngine: BrowserAutomationEngineDescribing {}

extension ShelfBrowserEngine {
    var automationDescriptor: BrowserAutomationEngineDescriptor {
        switch self {
        case .embedded:
            BrowserAutomationEngineDescriptor(kind: .embeddedWebKit)
        case .controlled:
            BrowserAutomationEngineDescriptor(kind: .controlledCDP)
        }
    }
}

/// A single automation backend's raw operation surface — the part of browser
/// automation that genuinely differs between the embedded WebKit engine
/// (evaluates `BrowserAutomationScripts` JS against the on-screen `WKWebView`)
/// and the controlled CDP engine (drives an external Chromium profile via
/// `ControlledBrowserController`).
///
/// This protocol intentionally covers ONLY raw operation dispatch. Preflight
/// checks, safety gating, logging, loop-hint annotation, and post-action
/// settle waits stay on `ShelfBrowserSession` — callers invoke `engine.op(...)`
/// once where they previously branched on `isUsingControlledBrowser`, then
/// keep doing everything else exactly as before.
///
/// Method shapes mirror whichever side (embedded JS-eval or
/// `ControlledBrowserController`) already defined the operation, so adapting
/// both sides to a common signature required no behavior changes.
///
/// `readPage` is deliberately NOT part of this protocol: the embedded path's
/// `readEmbeddedPage` is a multi-frame orchestration built on a
/// `WKScriptMessageHandler` reporter bridge (session-private request
/// tracking, frame expansion, per-frame warnings) rather than a plain
/// JS-eval-and-parse call, so its result shape and mechanism are not a
/// same-signature match for the controlled engine's single JSON-string
/// `readPage`. Unifying it would require either changing the embedded
/// return type/mechanism or leaking session-private frame-read state into
/// the engine, both of which are out of scope for a pure dispatch collapse.
/// That single `isUsingControlledBrowser` branch remains in
/// `ShelfBrowserSession.readPage(format:limit:chunkSize:)`.
@MainActor
protocol BrowserAutomationEngineOperating: BrowserAutomationEngineDescribing {
    func snapshot() async throws -> String
    func targetInfo(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String
    func click(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String
    func doubleClick(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String
    func type(
        selector: String?,
        text: String,
        clear: Bool,
        label: String?,
        role: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String
    func replaceText(find: String, replacement: String, selector: String?, all: Bool) async throws -> String
    func keypress(
        key: String,
        modifiers: [String],
        expectedFocusedTargetSignature: String?,
        allowUnboundFocusedTargetDispatch: Bool
    ) async throws -> String
    func insertText(_ text: String, expectedFocusedTargetSignature: String?) async throws -> String
}

enum BrowserAutomationEngineRequirement {
    static let environmentKey = "ASTRA_BROWSER_REQUIRED_ENGINE"
    static let headerName = "X-ASTRA-Browser-Required-Engine"

    static func requiredEngine(for task: AgentTask, contextText: String = "") -> BrowserAutomationEngineKind? {
        requiredEngine(text: [
            task.title,
            task.goal,
            task.inputs.joined(separator: " "),
            task.constraints.joined(separator: " "),
            task.acceptanceCriteria.joined(separator: " "),
            contextText
        ].joined(separator: " "))
    }

    static func requiredEngine(text: String) -> BrowserAutomationEngineKind? {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else { return nil }
        if controlledRequirementTerms.contains(where: { normalized.contains($0) }) {
            return .controlledCDP
        }
        return nil
    }

    static func requiredEngine(headerValue: String?) -> BrowserAutomationEngineKind? {
        guard let value = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return BrowserAutomationEngineKind(rawValue: value)
    }

    static func mismatchResponse(
        required: BrowserAutomationEngineKind?,
        actual: BrowserAutomationEngineDescriptor
    ) -> [String: Any]? {
        guard let required, required != actual.kind else { return nil }
        return mismatchResponse(required: required, actual: actual)
    }

    static func mismatchResponse(
        required: BrowserAutomationEngineKind,
        actual: BrowserAutomationEngineDescriptor
    ) -> [String: Any]? {
        guard required != actual.kind else { return nil }
        return [
            "ok": false,
            "error": "browser_engine_requirement_not_met",
            "requiredAutomationEngine": required.rawValue,
            "actualAutomationEngine": actual.jsonObject,
            "message": mismatchMessage(required: required, actual: actual),
            "recovery": [
                "kind": "switch-browser-engine",
                "requiredAutomationEngine": required.rawValue,
                "actualAutomationEngine": actual.kind.rawValue,
                "nextStep": "Open the ASTRA Shelf Browser menu, choose Open Controlled Browser, then retry the task."
            ]
        ]
    }

    private static func mismatchMessage(
        required: BrowserAutomationEngineKind,
        actual: BrowserAutomationEngineDescriptor
    ) -> String {
        switch required {
        case .controlledCDP:
            return "This task requires the ASTRA Controlled Browser / CDP engine, but the active Shelf browser backend is \(actual.bridgeBackendLabel). ASTRA did not execute the embedded WebKit fallback. Open the Controlled Browser, then retry."
        case .playwrightCDP:
            return "This task requires the Playwright/CDP browser engine, but the active Shelf browser backend is \(actual.bridgeBackendLabel). ASTRA did not execute a different browser fallback."
        case .embeddedWebKit:
            return "This task requires the embedded WebKit browser engine, but the active Shelf browser backend is \(actual.bridgeBackendLabel). ASTRA did not execute a different browser fallback."
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let controlledRequirementTerms: [String] = [
        "controlled browser",
        "astra controlled browser",
        "controlled cdp",
        "controlled chromium",
        "cdp browser automation",
        "browser cdp automation",
        "browser cdp browser automation",
        "action settlement cdp",
        "cdp settlement",
        "cdpsettlement",
        "do not use embedded webkit",
        "do not use the embedded webkit",
        "not use embedded webkit",
        "without embedded webkit"
    ]
}

enum BrowserAutomationEngineRequirementBridgePolicy {
    static func mismatchResponse(
        for request: BrowserBridgeRequest,
        actual: BrowserAutomationEngineDescriptor,
        backend: String,
        controlledBrowserRunning: Bool,
        controlledBrowserState: String,
        controlledBrowserStatus: String
    ) -> [String: Any]? {
        let required = BrowserAutomationEngineRequirement.requiredEngine(
            headerValue: request.headerValue(BrowserAutomationEngineRequirement.headerName)
        )
        guard var response = BrowserAutomationEngineRequirement.mismatchResponse(
            required: required,
            actual: actual
        ) else {
            return nil
        }
        response["backend"] = backend
        response["route"] = "\(request.method) \(request.path)"
        response["controlledBrowserRunning"] = controlledBrowserRunning
        response["controlledBrowserState"] = controlledBrowserState
        response["controlledBrowserStatus"] = controlledBrowserStatus
        return response
    }
}

/// Thin adapter from `ControlledBrowserController`'s existing async-throws
/// method surface to `BrowserAutomationEngineOperating`. `ControlledBrowserController`
/// already implements every one of these operations (it is the CDP transport
/// itself); this type only forwards calls so the controller doesn't need to
/// know about the engine protocol and `ShelfBrowserSession` can hold a single
/// `any BrowserAutomationEngineOperating` regardless of which backend is active.
@MainActor
struct ControlledBrowserEngineAdapter: BrowserAutomationEngineOperating {
    let controller: ControlledBrowserController

    nonisolated var automationDescriptor: BrowserAutomationEngineDescriptor {
        BrowserAutomationEngineDescriptor(kind: .controlledCDP)
    }

    nonisolated var bridgeBackendLabel: String { automationDescriptor.bridgeBackendLabel }

    func snapshot() async throws -> String {
        try await controller.snapshot()
    }

    func targetInfo(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await controller.targetInfo(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        )
    }

    func click(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await controller.click(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        )
    }

    func doubleClick(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await controller.doubleClick(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        )
    }

    func type(
        selector: String?,
        text: String,
        clear: Bool,
        label: String?,
        role: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await controller.type(
            selector: selector,
            text: text,
            clear: clear,
            label: label,
            role: role,
            placeholder: placeholder,
            testID: testID
        )
    }

    func replaceText(find: String, replacement: String, selector: String?, all: Bool) async throws -> String {
        try await controller.replaceText(find: find, replacement: replacement, selector: selector, all: all)
    }

    func keypress(
        key: String,
        modifiers: [String],
        expectedFocusedTargetSignature: String?,
        allowUnboundFocusedTargetDispatch: Bool
    ) async throws -> String {
        try await controller.keypress(
            key: key,
            modifiers: modifiers,
            expectedFocusedTargetSignature: expectedFocusedTargetSignature,
            allowUnboundFocusedTargetDispatch: allowUnboundFocusedTargetDispatch
        )
    }

    func insertText(_ text: String, expectedFocusedTargetSignature: String?) async throws -> String {
        try await controller.insertText(text, expectedFocusedTargetSignature: expectedFocusedTargetSignature)
    }
}

/// Thin adapter from `ShelfBrowserSession`'s embedded-WebKit JS-eval methods
/// to `BrowserAutomationEngineOperating`. The session owns `WKWebView` (and
/// all the lazy-creation, lifecycle, and TCC-prompt-avoidance logic around
/// it — see `ShelfBrowserSession.webView`), so this adapter is deliberately
/// stateless: it holds only a closure back to
/// `ShelfBrowserSession.evaluateJavaScriptString(_:)` and builds each
/// operation's script via the existing `BrowserAutomationScripts` builders,
/// exactly as the former `isUsingControlledBrowser`-branch `else` clauses did.
@MainActor
struct EmbeddedWebKitEngine: BrowserAutomationEngineOperating {
    let evaluateJavaScript: (String) async throws -> String

    nonisolated var automationDescriptor: BrowserAutomationEngineDescriptor {
        BrowserAutomationEngineDescriptor(kind: .embeddedWebKit)
    }

    nonisolated var bridgeBackendLabel: String { automationDescriptor.bridgeBackendLabel }

    func snapshot() async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.snapshotScript)
    }

    func targetInfo(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.targetInfoScript(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        ))
    }

    func click(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.clickScript(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        ))
    }

    func doubleClick(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.doubleClickScript(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        ))
    }

    func type(
        selector: String?,
        text: String,
        clear: Bool,
        label: String?,
        role: String?,
        placeholder: String?,
        testID: String?
    ) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.typeScript(
            selector: selector,
            text: text,
            clear: clear,
            label: label,
            role: role,
            placeholder: placeholder,
            testID: testID
        ))
    }

    func replaceText(find: String, replacement: String, selector: String?, all: Bool) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.replaceTextScript(
            find: find,
            replacement: replacement,
            selector: selector,
            all: all
        ))
    }

    func keypress(
        key: String,
        modifiers: [String],
        expectedFocusedTargetSignature: String?,
        allowUnboundFocusedTargetDispatch: Bool
    ) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.keypressScript(
            key: key,
            modifiers: modifiers,
            expectedFocusedTargetSignature: expectedFocusedTargetSignature,
            allowUnboundFocusedTargetDispatch: allowUnboundFocusedTargetDispatch
        ))
    }

    func insertText(_ text: String, expectedFocusedTargetSignature: String?) async throws -> String {
        try await evaluateJavaScript(BrowserAutomationScripts.insertTextScript(
            text,
            expectedFocusedTargetSignature: expectedFocusedTargetSignature
        ))
    }
}
