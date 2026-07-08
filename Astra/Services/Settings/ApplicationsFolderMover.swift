import AppKit
import Foundation
import ASTRACore
import ASTRAModels

/// First-launch "move to Applications" prompt (the classic LetsMove
/// pattern). Two problems this solves: (1) a user who launches straight
/// from ~/Downloads or a mounted DMG can get App Translocation'd into a
/// randomized, read-only mount -- Sparkle can never self-update the app
/// from a location it doesn't control, so auto-updates silently stop
/// working. (2) general install polish: users expect apps to live in
/// /Applications.
enum ApplicationsFolderMover {
    struct Decision: Equatable {
        enum Action: Equatable {
            case offerMove(destination: URL)
            case doNothing
        }

        let action: Action
    }

    /// Pure decision logic -- no AppKit or live-filesystem side effects, so
    /// it's fully testable with an injected `FileManager` and directory
    /// list. `applicationsDirectories` is tried in order: typically
    /// /Applications, then ~/Applications as the fallback for a standard
    /// (non-admin) user who can't write to the system one.
    static func decide(
        channel: AppChannel,
        currentBundlePath: String,
        applicationsDirectories: [URL],
        hasDeclinedBefore: Bool,
        fileManager: FileManager
    ) -> Decision {
        guard channel != .development else { return Decision(action: .doNothing) }
        guard !hasDeclinedBefore else { return Decision(action: .doNothing) }

        let bundleName = "\(channel.displayName).app"
        let currentStandardized = URL(fileURLWithPath: currentBundlePath).standardizedFileURL.path

        for appsDir in applicationsDirectories {
            let candidatePath = appsDir.appendingPathComponent(bundleName).standardizedFileURL.path
            if candidatePath == currentStandardized {
                // Already correctly placed.
                return Decision(action: .doNothing)
            }
        }

        for appsDir in applicationsDirectories {
            let destination = appsDir.appendingPathComponent(bundleName)
            if fileManager.fileExists(atPath: destination.path) {
                // Something's already there -- don't silently clobber a
                // possibly-intentional second copy; don't nag either.
                continue
            }
            var isDirectory: ObjCBool = false
            let dirExists = fileManager.fileExists(atPath: appsDir.path, isDirectory: &isDirectory)
            guard dirExists, isDirectory.boolValue, fileManager.isWritableFile(atPath: appsDir.path) else {
                continue
            }
            return Decision(action: .offerMove(destination: destination))
        }

        return Decision(action: .doNothing)
    }

    static var defaultApplicationsDirectories: [URL] {
        var directories: [URL] = []
        if let systemApplications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first {
            directories.append(systemApplications)
        }
        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            directories.append(userApplications)
        }
        return directories
    }

    /// Runs the full prompt-and-move flow if warranted. Call only from
    /// `applicationDidFinishLaunching` -- this touches NSAlert/NSWorkspace,
    /// which must not run before AppKit's normal bootstrap completes (see
    /// ASTRAAppDelegate's own doc comment on why touching NSApplication.shared
    /// early caused spurious TCC prompts).
    @MainActor
    static func promptAndMoveIfNeeded() {
        // Defense-in-depth alongside the `channel != .development` check in
        // `decide()` below (dev is already the default ASTRA_CHANNEL for
        // every non-release build, including test runs): an alert's
        // `runModal()` blocks synchronously, so if this ever fired during
        // an automated UI test it would hang the run rather than fail it.
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") }) else { return }

        let hasDeclinedBefore = UserDefaults.standard.bool(forKey: AppStorageKeys.declinedMoveToApplications)
        let decision = decide(
            channel: .current,
            currentBundlePath: Bundle.main.bundlePath,
            applicationsDirectories: defaultApplicationsDirectories,
            hasDeclinedBefore: hasDeclinedBefore,
            fileManager: .default
        )

        guard case .offerMove(let destination) = decision.action else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications Folder?"
        alert.informativeText = "\(AppChannel.current.displayName) works best in your Applications folder, and can only auto-update itself from there. Move it now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: AppStorageKeys.declinedMoveToApplications)
            return
        }

        move(to: destination)
    }

    @MainActor
    private static func move(to destination: URL) {
        // Reading Bundle.main's own content works even when translocated --
        // App Translocation only blocks the app from seeing *sibling* files
        // at its original download location; it does not block reading the
        // bundle's own contents, which is all `copyItem` needs here.
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            AppLogger.audit(.appMoveToApplicationsFailed, category: "App", fields: ["error": String(describing: error)])
            presentMoveFailedAlert(error: error)
            return
        }

        NSWorkspace.shared.openApplication(at: destination, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error {
                    AppLogger.audit(.appMoveToApplicationsFailed, category: "App", fields: ["error": String(describing: error)])
                    presentMoveFailedAlert(error: error)
                    return
                }
                AppLogger.audit(.appMovedToApplications, category: "App", fields: ["destination": destination.path])
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    private static func presentMoveFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't Move to Applications"
        alert.informativeText = "\(AppChannel.current.displayName) will keep running from its current location. \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
