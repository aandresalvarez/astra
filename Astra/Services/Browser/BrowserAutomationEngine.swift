import Foundation

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
