import Foundation

protocol ShelfBrowserBridgeRouteHandling {
    var supportedRoutes: Set<ShelfBrowserBridgeRoute> { get }
    var automationEngine: any BrowserAutomationEngineDescribing { get }

    func handleDirect(
        route: ShelfBrowserBridgeRoute,
        request: BrowserBridgeRequest
    ) async throws -> BrowserBridgeResponse?

    func handleBatch(
        route: ShelfBrowserBridgeRoute,
        action: BatchActionCommand
    ) async throws -> [String: Any]?
}

struct ShelfBrowserBridgeVerificationCommandHandler: ShelfBrowserBridgeRouteHandling {
    static let routes: Set<ShelfBrowserBridgeRoute> = [
        .verifyText,
        .waitSaved,
        .waitForText,
        .waitForSelector
    ]

    let automationEngine: any BrowserAutomationEngineDescribing

    private let verifyTextAction: (String, Bool) async throws -> [String: Any]
    private let waitSavedAction: (Double, Int) async throws -> [String: Any]
    private let waitForTextAction: (String, Double, Int) async throws -> [String: Any]
    private let waitForSelectorAction: (String, Double, Int) async throws -> [String: Any]

    var supportedRoutes: Set<ShelfBrowserBridgeRoute> { Self.routes }

    init(
        automationEngine: any BrowserAutomationEngineDescribing,
        verifyText: @escaping (String, Bool) async throws -> [String: Any],
        waitSaved: @escaping (Double, Int) async throws -> [String: Any],
        waitForText: @escaping (String, Double, Int) async throws -> [String: Any],
        waitForSelector: @escaping (String, Double, Int) async throws -> [String: Any]
    ) {
        self.automationEngine = automationEngine
        self.verifyTextAction = verifyText
        self.waitSavedAction = waitSaved
        self.waitForTextAction = waitForText
        self.waitForSelectorAction = waitForSelector
    }

    func handleDirect(
        route: ShelfBrowserBridgeRoute,
        request: BrowserBridgeRequest
    ) async throws -> BrowserBridgeResponse? {
        switch route {
        case .verifyText:
            let command = try request.decodeJSON(VerifyTextCommand.self)
            return .json(try await verifyTextAction(command.text, command.absent ?? false))
        case .waitSaved:
            let command = try request.decodeJSON(WaitSavedCommand.self)
            return .json(try await waitSavedAction(
                command.timeoutSeconds ?? 8,
                command.intervalMilliseconds ?? 500
            ))
        case .waitForText:
            let command = try request.decodeJSON(WaitTextCommand.self)
            return .json(try await waitForTextAction(
                command.text,
                command.timeoutSeconds ?? 5,
                command.intervalMilliseconds ?? 250
            ))
        case .waitForSelector:
            let command = try request.decodeJSON(WaitSelectorCommand.self)
            return .json(try await waitForSelectorAction(
                command.selector,
                command.timeoutSeconds ?? 5,
                command.intervalMilliseconds ?? 250
            ))
        default:
            return nil
        }
    }

    func handleBatch(
        route: ShelfBrowserBridgeRoute,
        action: BatchActionCommand
    ) async throws -> [String: Any]? {
        switch route {
        case .verifyText:
            guard let text = action.text ?? action.query else {
                return missingFieldResult(action: action, error: "missing_text")
            }
            return try await verifyTextAction(text, action.absent ?? false)
                .merging(["action": action.action], uniquingKeysWith: { current, _ in current })
        case .waitSaved:
            return try await waitSavedAction(
                action.timeoutSeconds ?? 8,
                action.intervalMilliseconds ?? 500
            ).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
        case .waitForText:
            guard let text = action.text else {
                return missingFieldResult(action: action, error: "missing_text")
            }
            return try await waitForTextAction(
                text,
                action.timeoutSeconds ?? 5,
                action.intervalMilliseconds ?? 250
            ).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
        case .waitForSelector:
            guard let selector = action.normalizedSelector else {
                return missingFieldResult(action: action, error: "missing_selector")
            }
            return try await waitForSelectorAction(
                selector,
                action.timeoutSeconds ?? 5,
                action.intervalMilliseconds ?? 250
            ).merging(["action": action.action], uniquingKeysWith: { current, _ in current })
        default:
            return nil
        }
    }

    private func missingFieldResult(action: BatchActionCommand, error: String) -> [String: Any] {
        ["ok": false, "action": action.action, "error": error]
    }
}
