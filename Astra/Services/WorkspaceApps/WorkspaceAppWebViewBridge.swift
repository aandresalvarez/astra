import Foundation

struct WorkspaceAppWebViewBridgeRequest: Codable, Sendable, Equatable {
    var widgetID: String
    var actionID: String
    var input: [String: WorkspaceAppStorageValue]

    init(
        widgetID: String,
        actionID: String,
        input: [String: WorkspaceAppStorageValue] = [:]
    ) {
        self.widgetID = widgetID
        self.actionID = actionID
        self.input = input
    }
}

struct WorkspaceAppWebViewBridgeValidation: Sendable, Equatable {
    var isAllowed: Bool
    var action: WorkspaceAppActionSpec?
    var issue: WorkspaceAppManifestValidationReport.Issue?

    static func allowed(action: WorkspaceAppActionSpec) -> WorkspaceAppWebViewBridgeValidation {
        WorkspaceAppWebViewBridgeValidation(isAllowed: true, action: action, issue: nil)
    }

    static func blocked(path: String, message: String) -> WorkspaceAppWebViewBridgeValidation {
        WorkspaceAppWebViewBridgeValidation(
            isAllowed: false,
            action: nil,
            issue: WorkspaceAppManifestValidationReport.Issue(
                severity: .blocker,
                path: path,
                message: message
            )
        )
    }
}

enum WorkspaceAppWebViewBridge {
    static func validate(
        _ request: WorkspaceAppWebViewBridgeRequest,
        manifest: WorkspaceAppManifest
    ) -> WorkspaceAppWebViewBridgeValidation {
        guard WorkspaceAppManifestValidator.validate(manifest).isValid else {
            return .blocked(path: "/manifest", message: "Workspace App manifest is not valid for WebView bridge requests.")
        }

        guard let widget = webViewWidget(id: request.widgetID, in: manifest) else {
            return .blocked(path: "/widgetID", message: "Unknown WebView widget '\(request.widgetID)'.")
        }
        guard widget.allowedActions.contains(request.actionID) else {
            return .blocked(
                path: "/actionID",
                message: "WebView widget '\(request.widgetID)' is not allowed to request action '\(request.actionID)'."
            )
        }
        guard let action = manifest.actions.first(where: { $0.id == request.actionID }) else {
            return .blocked(path: "/actionID", message: "Unknown Workspace App action '\(request.actionID)'.")
        }
        return .allowed(action: action)
    }

    private static func webViewWidget(
        id: String,
        in manifest: WorkspaceAppManifest
    ) -> WorkspaceAppWidgetSpec? {
        for view in manifest.views {
            if let widget = view.widgets.first(where: { $0.id == id && $0.type == "webView" }) {
                return widget
            }
        }
        return nil
    }
}
