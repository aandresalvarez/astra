import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import ASTRAModels
import ASTRAPersistence

struct StoreStartupBlockedView: View {
    let blocker: PersistentStoreRecoveryBlocker
    @ObservedObject var appUpdateController: AppUpdateController
    @State private var showsTechnicalDetails = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(blocker.title, systemImage: "externaldrive.badge.exclamationmark")
                    .font(Stanford.heading(24))
                    .foregroundStyle(Stanford.black)

                Text(blocker.message)
                    .font(Stanford.body(15))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)

                Text("ASTRA left the persistent store unchanged. Recovery actions operate on the reader or a verified copy, never by downgrading this store.")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)

                if showsTechnicalDetails, !blocker.technicalDetail.isEmpty {
                    Text(blocker.technicalDetail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(Stanford.coolGrey)
                }

                if blocker.actions.contains(.checkForUpdates),
                   let status = appUpdateController.statusMessage {
                    Text(status)
                        .font(Stanford.caption(12))
                        .foregroundStyle(Stanford.coolGrey)
                }

                if let actionError {
                    Text(actionError)
                        .font(Stanford.caption(12))
                        .foregroundStyle(.red)
                }

                HStack {
                    if !blocker.technicalDetail.isEmpty {
                        Button(showsTechnicalDetails ? "Hide Details" : "Technical Details") {
                            showsTechnicalDetails.toggle()
                        }
                    }
                    Spacer()
                    if blocker.actions.count > 1 {
                        Menu("Recovery Options") {
                            ForEach(Array(blocker.actions.dropFirst().enumerated()), id: \.offset) { _, action in
                                Button(actionTitle(action)) {
                                    perform(action)
                                }
                            }
                        }
                    }
                    if let action = blocker.actions.first {
                        Button(actionTitle(action)) {
                            perform(action)
                        }
                        .buttonStyle(StanfordButtonStyle())
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: StoreStartupBlockedWindowLayout.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(
            minWidth: StoreStartupBlockedWindowLayout.minimumContentSize.width,
            minHeight: StoreStartupBlockedWindowLayout.minimumContentSize.height
        )
        .background(Stanford.panelBackground)
        .background {
            StoreStartupBlockedWindowConfigurator()
                .frame(width: 0, height: 0)
        }
    }

    private func actionTitle(_ action: PersistentStoreRecoveryAction) -> String {
        switch action {
        case .createFreshDevelopmentStore: "Start Fresh Dev Store"
        case .openCompatibleBuild: "Restart with Compatible Build"
        case .locateCompatibleBuild: "Locate Compatible Build…"
        case .checkForUpdates: "Update ASTRA"
        case .chooseStore: "Choose Another Store…"
        case .revealStore: "Show Store"
        case .quit: "Quit ASTRA"
        }
    }

    private func perform(_ action: PersistentStoreRecoveryAction) {
        switch action {
        case .createFreshDevelopmentStore:
            createFreshDevelopmentStore()
        case .openCompatibleBuild(let bundlePath):
            relaunch(bundleURL: URL(fileURLWithPath: bundlePath), auditResult: "compatible_build_relaunch_scheduled")
        case .locateCompatibleBuild(let requiredSchemaVersion):
            locateCompatibleBuild(requiredSchemaVersion: requiredSchemaVersion)
        case .checkForUpdates:
            appUpdateController.checkForUpdatesFromButton()
        case .chooseStore:
            chooseStore()
        case .revealStore:
            NSWorkspace.shared.activateFileViewerSelecting([WorkspaceRecoveryService.storeURL])
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func createFreshDevelopmentStore() {
        do {
            _ = try DevelopmentStoreRecoveryService.createAndActivateFreshStore()
            relaunch(bundleURL: Bundle.main.bundleURL, auditResult: "fresh_development_store_relaunch_scheduled")
        } catch {
            actionError = "ASTRA could not create a fresh development store: \(error.localizedDescription)"
        }
    }

    private func locateCompatibleBuild(requiredSchemaVersion: Int) {
        let panel = NSOpenPanel()
        Self.configureCompatibleBuildPanel(panel, requiredSchemaVersion: requiredSchemaVersion)
        guard panel.runModal() == .OK, let bundleURL = panel.url else { return }
        guard let candidate = CompatibleASTRABuildRegistry.compatibleBuild(
            at: bundleURL,
            requiredSchemaVersion: requiredSchemaVersion,
            channel: AppBuildInfo.current.channelRawValue
        ) else {
            actionError = "That app is not a compatible ASTRA Dev build for schema V\(requiredSchemaVersion)."
            return
        }
        relaunch(
            bundleURL: URL(fileURLWithPath: candidate.bundlePath),
            auditResult: "located_compatible_build_relaunch_scheduled"
        )
    }

    static func configureCompatibleBuildPanel(
        _ panel: NSOpenPanel,
        requiredSchemaVersion: Int
    ) {
        // Application bundles are packages presented as selectable files by
        // NSOpenPanel. Treating them as directories leaves the requested
        // ASTRA.app bundle disabled in the picker.
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = "Choose an ASTRA Dev build that supports schema V\(requiredSchemaVersion) or newer."
    }

    private func chooseStore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an ASTRA store. ASTRA will validate and copy it before activation."
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        if let channelFailure = PersistentStoreRecoveryPolicy.storeSelectionChannelFailureMessage(
            metadata: PersistentStoreCompatibilityService.readMetadata(for: sourceURL),
            currentChannel: AppBuildInfo.current.channelRawValue
        ) {
            actionError = channelFailure
            return
        }
        do {
            let recoveryURL = try WorkspaceRecoveryService.makeRecoveryStoreURL()
            try WorkspaceRecoveryService.copyStoreSnapshot(from: sourceURL, to: recoveryURL)
            let assessment = PersistentStoreCompatibilityService.assess(
                storeURL: recoveryURL,
                latestSupportedSchemaVersion: ASTRASchema.currentVersion
            )
            if let validationFailure = PersistentStoreRecoveryPolicy.storeSelectionFailureMessage(
                assessment: assessment,
                supportedSchemaVersion: ASTRASchema.currentVersion
            ) {
                actionError = validationFailure
                return
            }
            _ = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(url: recoveryURL)]
            )
            let metadata = AstraStoreStartupCoordinator.compatibilityMetadata(appInfo: .current)
            try WorkspaceRecoveryService.activateRecoveryStore(at: recoveryURL, compatibility: metadata)
            relaunch(bundleURL: Bundle.main.bundleURL, auditResult: "selected_store_relaunch_scheduled")
        } catch {
            actionError = "The selected store could not be safely activated: \(error.localizedDescription)"
        }
    }

    private func relaunch(bundleURL: URL, auditResult: String) {
        do {
            let command = ApplicationRelauncher.command(
                processID: ProcessInfo.processInfo.processIdentifier,
                destination: bundleURL
            )
            let relauncher = Process()
            relauncher.executableURL = command.executableURL
            relauncher.arguments = command.arguments
            try relauncher.run()
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: ["result": auditResult])
            NSApplication.shared.terminate(nil)
        } catch {
            actionError = "ASTRA could not relaunch: \(error.localizedDescription)"
        }
    }
}
