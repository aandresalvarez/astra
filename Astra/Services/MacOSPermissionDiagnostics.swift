import AppKit
import Foundation

enum MacOSPermissionKind: String {
    case appManagement = "app_management"

    var settingsName: String {
        switch self {
        case .appManagement: "App Management"
        }
    }

    var systemImage: String {
        switch self {
        case .appManagement: "slider.horizontal.3"
        }
    }

    var settingsURLs: [URL] {
        let rawURLs: [String]
        switch self {
        case .appManagement:
            rawURLs = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement",
                "x-apple.systempreferences:com.apple.preference.security"
            ]
        }
        return rawURLs.compactMap(URL.init(string:))
    }
}

struct MacOSPermissionIssue: Equatable, Identifiable {
    let kind: MacOSPermissionKind
    let title: String
    let message: String
    let actionTitle: String
    let systemImage: String

    var id: String { kind.rawValue }
}

enum MacOSPermissionDiagnostics {
    static func controlledBrowserAgentControlIssue(
        appDisplayName: String,
        browserName: String?,
        isRunning: Bool,
        runState: ControlledBrowserRunState,
        lastErrorMessage: String?
    ) -> MacOSPermissionIssue? {
        guard !isRunning else { return nil }
        guard runState == .failed,
              let lastErrorMessage,
              isLikelyAppManagementDenial(lastErrorMessage) else {
            return nil
        }

        let browser = browserName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = browser?.isEmpty == false ? browser! : "Chrome"
        return appManagementIssue(appDisplayName: appDisplayName, targetAppName: target)
    }

    static func appManagementIssue(appDisplayName: String, targetAppName: String) -> MacOSPermissionIssue {
        let kind = MacOSPermissionKind.appManagement
        return MacOSPermissionIssue(
            kind: kind,
            title: "Allow \(appDisplayName) in \(kind.settingsName)",
            message: "macOS blocked \(appDisplayName) from opening \(targetAppName). Turn on \(appDisplayName) in \(kind.settingsName), then check again.",
            actionTitle: "Open \(kind.settingsName)",
            systemImage: kind.systemImage
        )
    }

    static func isLikelyAppManagementDenial(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let directMatches = [
            "app management",
            "privacy_appmanagement",
            "systempolicyappbundles"
        ]
        if directMatches.contains(where: normalized.contains) {
            return true
        }

        let denialMatches = [
            "operation not permitted",
            "not authorized",
            "not authorised",
            "authorization denied",
            "permission denied",
            "privacy settings",
            "tcc"
        ]
        let appMatches = [
            ".app/contents/macos",
            "google chrome",
            "microsoft edge",
            "brave browser",
            "chromium",
            "controlled browser"
        ]
        return denialMatches.contains(where: normalized.contains)
            && appMatches.contains(where: normalized.contains)
    }

    @discardableResult
    static func openSettings(for kind: MacOSPermissionKind) -> Bool {
        kind.settingsURLs.contains { NSWorkspace.shared.open($0) }
    }
}
