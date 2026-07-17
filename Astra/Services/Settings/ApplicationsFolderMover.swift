import AppKit
import SwiftUI
import ASTRACore

/// Owns the production-only guided install window. The planner and copy logic
/// live in `ApplicationInstallationService.swift`; this type is intentionally
/// limited to AppKit lifecycle and presentation concerns.
enum ApplicationInstallationCoordinator {
    static var userApplicationsDirectory: URL? {
        FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first
    }

    static var defaultApplicationsDirectories: [URL] {
        var directories: [URL] = []
        if let systemApplications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first {
            directories.append(systemApplications)
        }
        if let userApplications = userApplicationsDirectory {
            directories.append(userApplications)
        }
        return directories
    }

    static var isInstallerOnlyLaunch: Bool {
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") }) else {
            return false
        }
        return ApplicationInstallationPlanner.requiresInstallation(
            channel: .current,
            currentBundleURL: Bundle.main.bundleURL,
            applicationsDirectories: defaultApplicationsDirectories
        )
    }

    /// Called from `applicationDidFinishLaunching`, after AppKit has completed
    /// its normal bootstrap. A modal window keeps the not-yet-installed copy
    /// from opening ASTRA's workspace UI behind the installer.
    @MainActor
    static func presentIfNeeded() {
        guard isInstallerOnlyLaunch else { return }

        let source = Bundle.main.bundleURL
        let sourceMetadata: ApplicationBundleMetadata
        do {
            sourceMetadata = try ApplicationBundleMetadata.read(from: source)
        } catch {
            AppLogger.audit(
                .appInstallationFailed,
                category: "App",
                fields: ["stage": "read_source", "error": String(describing: error)]
            )
            presentUnavailableAlert(message: error.localizedDescription)
            return
        }

        let decision = ApplicationInstallationPlanner.decide(
            channel: .current,
            currentBundleURL: source,
            sourceMetadata: sourceMetadata,
            applicationsDirectories: defaultApplicationsDirectories,
            creatableApplicationsDirectories: Set([userApplicationsDirectory].compactMap { $0 }),
            fileManager: .default
        )

        switch decision {
        case .doNothing:
            return
        case .unavailable:
            AppLogger.audit(
                .appInstallationFailed,
                category: "App",
                fields: ["stage": "plan", "error": "no_writable_applications_directory"]
            )
            presentUnavailableAlert(
                message: "ASTRA couldn’t find an Applications folder it can write to. Check the folder permissions and try again."
            )
        case .present(let plan):
            presentInstaller(for: plan)
        }
    }

    @MainActor
    private static func presentInstaller(for plan: ApplicationInstallationPlan) {
        AppLogger.audit(
            .appInstallationPresented,
            category: "App",
            fields: ApplicationInstallationAuditFields.presented(plan: plan)
        )

        let appIcon = loadAppIcon()
        let presentation = ApplicationInstallerPresentation(plan: plan)
        let processID = ProcessInfo.processInfo.processIdentifier

        let viewModel = ApplicationInstallerViewModel(
            presentation: presentation,
            installOperation: {
                AppLogger.audit(
                    .appInstallationStarted,
                    category: "App",
                    fields: ["destination": plan.destination.path]
                )
                do {
                    try ApplicationInstallationService.install(plan)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            prepareRelaunch: {
                try ApplicationRelauncher.schedule(processID: processID, destination: plan.destination)
            },
            onCompleted: {
                NSApp.stopModal(withCode: .OK)
            },
            onCancel: {
                NSApp.stopModal(withCode: .cancel)
            },
            onFailure: { message in
                AppLogger.audit(
                    .appInstallationFailed,
                    category: "App",
                    fields: ["stage": "install", "error": message]
                )
            }
        )

        // The SwiftUI scene exists only to satisfy the App protocol during an
        // installer-only launch. Keep that inert window out of sight before
        // presenting the single guided-install surface.
        NSApp.windows.forEach { $0.orderOut(nil) }

        let rootView = ApplicationInstallerView(model: viewModel, appIcon: appIcon)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = presentation.title
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let windowDelegate = ApplicationInstallationModalWindowDelegate(
            canClose: {
                ApplicationInstallerModalClosePolicy.allowsClose(phase: viewModel.phase)
            }
        )
        window.delegate = windowDelegate
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)

        if response == .OK {
            AppLogger.audit(
                .appInstallationCompleted,
                category: "App",
                fields: [
                    "destination": plan.destination.path,
                    "replaced_existing": String(plan.replacesExistingCopy),
                    "version": plan.sourceMetadata.version
                ]
            )
        } else {
            AppLogger.audit(
                .appInstallationCancelled,
                category: "App",
                fields: ["destination": plan.destination.path]
            )
        }

        // Production copies outside Applications are installer launchers, not
        // portable app sessions. Closing or cancelling exits cleanly; success
        // relaunches the verified destination via ApplicationRelauncher.
        NSApp.terminate(nil)
    }

    @MainActor
    private static func presentUnavailableAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "ASTRA couldn’t start installation"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit ASTRA")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private static func loadAppIcon() -> NSImage {
        let resourceBundle = AstraResourceBundle.current
        if let url = resourceBundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }
}

enum ApplicationInstallationAuditFields {
    static func presented(plan: ApplicationInstallationPlan) -> [String: String] {
        var fields = [
            "destination": plan.destination.path,
            "replaces_existing": String(plan.replacesExistingCopy),
            "source_version": plan.sourceMetadata.version
        ]
        if let existingVersion = plan.existingVersion {
            fields["existing_version"] = existingVersion
        }
        return fields
    }
}

enum ApplicationLaunchRoot: Equatable, Sendable {
    case installerPlaceholder
    case startupBlocked
    case main

    static func resolve(isInstallerOnlyLaunch: Bool, hasStartupBlocker: Bool) -> ApplicationLaunchRoot {
        if isInstallerOnlyLaunch { return .installerPlaceholder }
        if hasStartupBlocker { return .startupBlocked }
        return .main
    }
}

struct ApplicationInstallerLaunchPlaceholder: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
    }
}

@MainActor
private final class ApplicationInstallationModalWindowDelegate: NSObject, NSWindowDelegate {
    private let canClose: () -> Bool

    init(canClose: @escaping () -> Bool) {
        self.canClose = canClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard canClose() else {
            NSSound.beep()
            return false
        }
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}
