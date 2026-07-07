import AppKit
import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

enum MacOSPermissionKind: String {
    case appManagement = "app_management"
    case keychain = "keychain"
    case filesAndFolders = "files_and_folders"

    var settingsName: String {
        switch self {
        case .appManagement: "App Management"
        case .keychain: "Keychain Access"
        case .filesAndFolders: "Files & Folders"
        }
    }

    var systemImage: String {
        switch self {
        case .appManagement: "slider.horizontal.3"
        case .keychain: "key.fill"
        case .filesAndFolders: "folder.badge.gearshape"
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
        case .keychain:
            rawURLs = []
        case .filesAndFolders:
            rawURLs = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
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
    let setupSteps: [String]

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
            systemImage: kind.systemImage,
            setupSteps: [
                "Open System Settings > Privacy & Security > \(kind.settingsName).",
                "Turn on \(appDisplayName).",
                "Return to ASTRA and click Retry."
            ]
        )
    }

    static func keychainIssue(appDisplayName: String, detail: String) -> MacOSPermissionIssue {
        let kind = MacOSPermissionKind.keychain
        return MacOSPermissionIssue(
            kind: kind,
            title: "Allow \(appDisplayName) to use Keychain",
            message: "ASTRA could not save a test credential in macOS Keychain. \(detail)",
            actionTitle: "Open Keychain Access",
            systemImage: kind.systemImage,
            setupSteps: [
                "Open Keychain Access.",
                "Unlock the login keychain if it is locked.",
                "Return to ASTRA and click Retry."
            ]
        )
    }

    static func workspaceAccessIssue(appDisplayName: String, path: String, detail: String) -> MacOSPermissionIssue {
        let kind = MacOSPermissionKind.filesAndFolders
        return MacOSPermissionIssue(
            kind: kind,
            title: "Allow workspace folder access",
            message: "\(appDisplayName) could not write to the workspace root: \(path). \(detail)",
            actionTitle: "Open Files & Folders",
            systemImage: kind.systemImage,
            setupSteps: [
                "Open System Settings > Privacy & Security > Files & Folders.",
                "Allow \(appDisplayName) to access the workspace folder, or choose another workspace root.",
                "Return to ASTRA and click Retry."
            ]
        )
    }

    static func checkKeychainAccess(appDisplayName: String) -> MacOSPermissionIssue? {
        // Validate ASTRA's *dedicated* keychain — where connector/skill secrets
        // actually live — rather than login.keychain-db. A clean round-trip
        // proves the app can create, unlock, write, read, and delete in its own
        // keychain. The probe item is namespaced and removed immediately.
        let service = "\(AppChannel.current.keychainConnectorPrefix)-permission-check"
        let account = "macos-permission-check"
        let value = "ok-\(UUID().uuidString)"

        guard AstraSecureKeychainStore.save(
            service: service,
            account: account,
            value: value,
            label: "ASTRA permission check"
        ) else {
            return keychainIssue(
                appDisplayName: appDisplayName,
                detail: "ASTRA could not write to its dedicated keychain."
            )
        }

        let readBack = AstraSecureKeychainStore.load(service: service, account: account)
        AstraSecureKeychainStore.delete(service: service, account: account)

        guard readBack == value else {
            return keychainIssue(
                appDisplayName: appDisplayName,
                detail: "ASTRA's dedicated keychain did not return the test value."
            )
        }
        return nil
    }

    static func checkWorkspaceRootAccess(
        appDisplayName: String,
        workspaceRoot: String,
        fileManager: FileManager = .default
    ) -> MacOSPermissionIssue? {
        let expandedPath = NSString(string: workspaceRoot).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        let testURL = rootURL.appendingPathComponent(".astra-permission-check-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: testURL, options: .atomic)
            _ = try Data(contentsOf: testURL)
            try fileManager.removeItem(at: testURL)
            return nil
        } catch {
            try? fileManager.removeItem(at: testURL)
            return workspaceAccessIssue(
                appDisplayName: appDisplayName,
                path: expandedPath,
                detail: error.localizedDescription
            )
        }
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
        if kind == .keychain {
            return openKeychainAccess()
        }
        return kind.settingsURLs.contains { NSWorkspace.shared.open($0) }
    }

    private static func openKeychainAccess() -> Bool {
        let candidates = [
            "/System/Applications/Utilities/Keychain Access.app",
            "/Applications/Utilities/Keychain Access.app"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                return true
            }
        }
        return false
    }

}
