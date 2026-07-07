import Testing
@testable import ASTRA

@Suite("macOS Permission Diagnostics")
struct MacOSPermissionDiagnosticsTests {
    @Test("Controlled browser shows no permission issue when it is already reachable")
    func runningControlledBrowserHasNoPermissionIssue() {
        let issue = MacOSPermissionDiagnostics.controlledBrowserAgentControlIssue(
            appDisplayName: "ASTRA Dev",
            browserName: "Google Chrome",
            isRunning: true,
            runState: .running,
            lastErrorMessage: "operation not permitted for Google Chrome.app/Contents/MacOS/Google Chrome"
        )

        #expect(issue == nil)
    }

    @Test("Controlled browser App Management denial maps to exact settings action")
    func appManagementDenialMapsToIssue() throws {
        let issue = try #require(MacOSPermissionDiagnostics.controlledBrowserAgentControlIssue(
            appDisplayName: "ASTRA Dev",
            browserName: "Google Chrome",
            isRunning: false,
            runState: .failed,
            lastErrorMessage: "operation not permitted for /Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ))

        #expect(issue.kind == .appManagement)
        #expect(issue.title == "Allow ASTRA Dev in App Management")
        #expect(issue.actionTitle == "Open App Management")
        #expect(issue.message.contains("ASTRA Dev"))
        #expect(issue.message.contains("Google Chrome"))
    }

    @Test("Non-permission controlled browser failures do not show App Management guidance")
    func nonPermissionFailureDoesNotMapToIssue() {
        let issue = MacOSPermissionDiagnostics.controlledBrowserAgentControlIssue(
            appDisplayName: "ASTRA Dev",
            browserName: nil,
            isRunning: false,
            runState: .failed,
            lastErrorMessage: "No supported Chromium browser was found."
        )

        #expect(issue == nil)
    }

    @Test("Keychain issue points to an ASTRA retry flow")
    func keychainIssueMapsToAction() {
        let issue = MacOSPermissionDiagnostics.keychainIssue(
            appDisplayName: "ASTRA Dev",
            detail: "User interaction is not allowed."
        )

        #expect(issue.kind == .keychain)
        #expect(issue.title == "Allow ASTRA Dev to use Keychain")
        #expect(issue.actionTitle == "Retry Keychain Check")
        #expect(issue.setupSteps.contains { $0.contains("macOS asks") })
        #expect(issue.message.contains("Keychain"))
    }

    @Test("Keychain Access opener resolves current macOS app location")
    func keychainAccessOpenerIncludesCurrentMacOSLocation() {
        #expect(MacOSPermissionDiagnostics.keychainAccessBundleIdentifier == "com.apple.keychainaccess")
        #expect(MacOSPermissionDiagnostics.keychainAccessFallbackPaths.contains(
            "/System/Library/CoreServices/Applications/Keychain Access.app"
        ))
    }

    @Test("Workspace issue points to Files and Folders")
    func workspaceIssueMapsToAction() {
        let issue = MacOSPermissionDiagnostics.workspaceAccessIssue(
            appDisplayName: "ASTRA Dev",
            path: "/tmp/astra-workspaces",
            detail: "Operation not permitted."
        )

        #expect(issue.kind == .filesAndFolders)
        #expect(issue.actionTitle == "Open Files & Folders")
        #expect(issue.message.contains("/tmp/astra-workspaces"))
    }
}
