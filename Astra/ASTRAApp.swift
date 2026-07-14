import SwiftUI
import SwiftData
import AppKit
import ASTRAModels
import ASTRAPersistence
import ASTRACore

private let aboutAstraWindowID = "about-astra"

enum AppWindowLayout {
    static let mainMinimumWidth: CGFloat = 900
    static let mainMinimumHeight: CGFloat = 600
    static let mainDefaultWidth: CGFloat = PanelLayoutGeometry.compactPanelMutualExclusionWidth + 80
    static let mainDefaultHeight: CGFloat = 750
}

// MARK: - Window-scoped actions exposed to app menu commands
//
// @FocusedValue is SwiftUI's way for a view inside the focused window to
// publish a closure that app-scene commands (in .commands {}) can call.
// We use it for menu items whose implementation lives on ContentView —
// avoids reaching into NotificationCenter or singletons.

struct NewWorkspaceActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ImportWorkspaceActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ReportProblemActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newWorkspaceAction: NewWorkspaceActionKey.Value? {
        get { self[NewWorkspaceActionKey.self] }
        set { self[NewWorkspaceActionKey.self] = newValue }
    }

    var importWorkspaceAction: ImportWorkspaceActionKey.Value? {
        get { self[ImportWorkspaceActionKey.self] }
        set { self[ImportWorkspaceActionKey.self] = newValue }
    }

    var reportProblemAction: ReportProblemActionKey.Value? {
        get { self[ReportProblemActionKey.self] }
        set { self[ReportProblemActionKey.self] = newValue }
    }
}

private struct ReportProblemMenuItem: View {
    @FocusedValue(\.reportProblemAction) private var action

    var body: some View {
        Button("Report a Problem…") { action?() }
            .disabled(action == nil)
            .accessibilityIdentifier(FeedbackReportAccessibilityID.reportProblem)
    }
}

/// File-menu item that invokes the focused window's New Workspace action.
/// Grays out when no ContentView is key (e.g. during Settings window
/// focus).
private struct NewWorkspaceMenuItem: View {
    @FocusedValue(\.newWorkspaceAction) private var action

    var body: some View {
        Button("New Workspace…") { action?() }
            .disabled(action == nil)
            .keyboardShortcut("n", modifiers: [.command, .shift])
    }
}

/// File-menu item that invokes the focused window's Import Workspace
/// action. Same pattern as NewWorkspaceMenuItem.
private struct ImportWorkspaceMenuItem: View {
    @FocusedValue(\.importWorkspaceAction) private var action

    var body: some View {
        Button("Import Workspace…") { action?() }
            .disabled(action == nil)
            .keyboardShortcut("i", modifiers: [.command, .shift])
    }
}

/// Owns the main-window command instead of relying on SwiftUI's synthesized
/// `NewItemCommands`. On macOS 26.5 that synthesized command can recursively
/// invalidate the scene graph while restored windows are ordered on screen.
private struct NewMainWindowMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New \(AppChannel.current.displayName) Window") {
            openWindow(id: AppWindowIDs.main)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

private struct CheckForUpdatesMenuItem: View {
    @ObservedObject var appUpdateController: AppUpdateController

    var body: some View {
        Button("Check for Updates…") {
            appUpdateController.checkForUpdates()
        }
        .disabled(!appUpdateController.canCheckForUpdates)
    }
}

private struct AboutAstraMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(AppChannel.current.displayName)") {
            openWindow(id: aboutAstraWindowID)
        }
    }
}

private struct AboutAstraView: View {
    private let appInfo = AppBuildInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 24)

            Divider()

            VStack(alignment: .leading, spacing: 22) {
                Text(AstraAboutInfo.tagline)
                    .font(Stanford.body(18).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                    .fixedSize(horizontal: false, vertical: true)

                Text(AstraAboutInfo.summary)
                    .font(Stanford.body(15))
                    .foregroundStyle(Stanford.coolGrey)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("What ASTRA helps with")
                        .font(Stanford.caption(12).weight(.bold))
                        .foregroundStyle(Stanford.lagunita)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(AstraAboutInfo.highlights, id: \.self) { highlight in
                            Label(highlight, systemImage: "checkmark.circle.fill")
                                .font(Stanford.body(14))
                                .foregroundStyle(Stanford.coolGrey)
                                .labelStyle(AboutHighlightLabelStyle())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Stanford.lagunita.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(AstraAboutInfo.supervisionPrinciple)
                    .font(Stanford.body(15).weight(.semibold))
                    .foregroundStyle(Stanford.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Stanford.paloAltoGreen.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Link(destination: URL(string: AstraAboutInfo.repositoryURLString)!) {
                    Text(AstraAboutInfo.repositoryURLString)
                        .font(Stanford.body(13).weight(.medium))
                        .foregroundStyle(Stanford.lagunita)
                }
            }
            .padding(.vertical, 24)

            HStack {
                Text("Version \(appInfo.version) (\(appInfo.build))")
                    .font(Stanford.caption(12))
                    .foregroundStyle(Stanford.coolGrey)

                Spacer()

                Button("Done") {
                    NSApplication.shared.keyWindow?.close()
                }
                    .buttonStyle(StanfordButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 620)
        .background(Stanford.panelBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            AstraAppIconTile(size: 76)
                .shadow(color: Stanford.black.opacity(0.12), radius: 10, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 7) {
                Text(appInfo.displayName)
                    .font(Stanford.heading(30))
                    .foregroundStyle(Stanford.black)

                Text(AstraAboutInfo.fullName)
                    .font(Stanford.body(14).weight(.medium))
                    .foregroundStyle(Stanford.coolGrey)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AboutHighlightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        // `.top` (not `.firstTextBaseline`): a baseline-aligned HStack that can hold selectable
        // `Text` live-locks SwiftUI's layout engine. Keep `.top`. See MarkdownTextView in TaskMainView.
        HStack(alignment: .top, spacing: 8) {
            configuration.icon
                .font(Stanford.ui(12, weight: .semibold))
                .foregroundStyle(Stanford.lagunita)
                .frame(width: 14)

            configuration.title
        }
    }
}

/// Runs the app's AppKit/NSApplication setup at the correct lifecycle point.
/// These calls must NOT run in `ASTRAApp.init()`: accessing
/// `NSApplication.shared` from the SwiftUI App initializer forces AppKit to
/// bootstrap before the normal launch sequence, and that premature subsystem
/// init (menu bar → NSWorkspace → WindowServer) probes TCC services — which
/// surfaced spurious Photos / Music / Input-Monitoring prompts at launch. By
/// the time `applicationDidFinishLaunching` fires, SwiftUI has already
/// bootstrapped NSApplication through the normal path, so these are
/// side-effect-free.
final class ASTRAAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Foreground the app (matters when launched from a terminal via
        // `swift run`; a no-op for a normally-activated .app bundle).
        NSApp.setActivationPolicy(.regular)
        let resourceBundle = AstraResourceBundle.current
        let iconResourceName = AppChannel.current == .development ? "AppIconDev" : "AppIcon"
        if let iconURL = resourceBundle.url(forResource: iconResourceName, withExtension: "icns")
            ?? resourceBundle.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.main.url(forResource: iconResourceName, withExtension: "icns")
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        // Runs before the rest of this function's bookkeeping: if the user
        // accepts, this process relaunches from /Applications and quits
        // shortly after, making the log/shortcuts calls below moot for it.
        // Placed after activation (not before) so the alert -- if shown --
        // is correctly foregrounded with the app's real icon already set.
        ApplicationsFolderMover.promptAndMoveIfNeeded()
        AppLogger.audit(.appActivated, category: "App")
    }
}

private final class StoreLeaseHolder: ObservableObject {
    let lease: PersistentStoreLease?

    init(lease: PersistentStoreLease?) {
        self.lease = lease
    }
}

enum AstraStoreStartupCoordinator {
    struct Result {
        let modelContainer: ModelContainer
        let lease: PersistentStoreLease?
        let blocker: PersistentStoreRecoveryBlocker?
    }

    static func start(isUITesting: Bool, appInfo: AppBuildInfo) -> Result {
        guard !isUITesting else {
            return Result(modelContainer: inMemoryContainer(), lease: nil, blocker: nil)
        }

        let effectiveChannel = AppChannel.current
        guard LinkedAppChannelIdentity.matches(effectiveChannel: effectiveChannel) else {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "blocked_linked_channel_mismatch",
                "bundle_channel": appInfo.channelRawValue,
                "effective_channel": effectiveChannel.rawValue,
                "linked_channel": LinkedAppChannelIdentity.marker
            ], level: .error)
            return blocked(
                title: "ASTRA build channel mismatch",
                message: "This executable was linked for a different app channel, so ASTRA did not open either channel's data."
            )
        }

        do {
            try WorkspaceRecoveryService.preparePersistentStoreDirectory()
        } catch {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "blocked_store_directory_preparation_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return blocked(
                title: "ASTRA could not prepare its store",
                message: "The persistent-store directory could not be prepared, so ASTRA left existing data unchanged."
            )
        }
        let owner = PersistentStoreLease.OwnerMetadata(
            channel: appInfo.channelRawValue,
            version: appInfo.version,
            build: appInfo.build
        )
        let lease: PersistentStoreLease
        do {
            lease = try PersistentStoreLease.acquire(
                at: WorkspaceRecoveryService.storeLeaseURL,
                owner: owner
            )
        } catch PersistentStoreLease.AcquisitionError.alreadyOwned {
            let recordedOwner = PersistentStoreLease.recordedOwner(at: WorkspaceRecoveryService.storeLeaseURL)
            let detail: String
            if let recordedOwner {
                detail = "The store is already owned by PID \(recordedOwner.processID), \(recordedOwner.executablePath), version \(recordedOwner.version) (\(recordedOwner.build))."
            } else {
                detail = "Another ASTRA process already owns this channel's store."
            }
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "blocked_store_lease_held"
            ], level: .warning)
            return blocked(title: "ASTRA is already using this store", message: detail)
        } catch {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "blocked_store_lease_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return blocked(
                title: "ASTRA could not secure its store",
                message: "The persistent-store ownership lease could not be acquired."
            )
        }

        var storeURL: URL
        do {
            storeURL = try WorkspaceRecoveryService.preparePersistentStoreURL()
        } catch {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "blocked_store_preparation_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return blocked(
                title: "ASTRA could not safely prepare its store",
                message: "The active store pointer or legacy-store migration was invalid, incomplete, or unavailable. ASTRA left existing data unchanged."
            )
        }

        switch migrateOrphanedV12IfNeeded(storeURL: storeURL, appInfo: appInfo) {
        case .continueOpening(let selectedStoreURL):
            storeURL = selectedStoreURL
        case .blocked:
            return blocked(
                title: "ASTRA preserved an incompatible V12 store",
                message: "ASTRA could not validate a migrated copy, so it left the original store selected and unchanged."
            )
        }
        let hasPendingLegacyStoreMigration = WorkspaceRecoveryService.hasPendingLegacyStoreMigration
        let compatibility = PersistentStoreCompatibilityService.assess(
            storeURL: storeURL,
            latestSupportedSchemaVersion: appInfo.schemaVersion
        )
        if case .requiresNewerReader(let requiredSchemaVersion) = compatibility {
            let candidate = appInfo.channelRawValue == "dev" ? CompatibleASTRABuildRegistry.compatibleBuild(
                requiredSchemaVersion: requiredSchemaVersion,
                channel: appInfo.channelRawValue,
                excludingBundlePath: Bundle.main.bundleURL.standardizedFileURL.path
            ) : nil
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "stage": "compatibility_preflight",
                "decision": "requires_newer_reader",
                "required_schema": String(requiredSchemaVersion),
                "supported_schema": String(appInfo.schemaVersion),
                "compatible_build_found": String(candidate != nil)
            ], level: .warning)
            return Result(
                modelContainer: inMemoryContainer(),
                lease: lease,
                blocker: PersistentStoreRecoveryPolicy.incompatibleBlocker(
                    requiredSchemaVersion: requiredSchemaVersion,
                    supportedSchemaVersion: appInfo.schemaVersion,
                    channel: appInfo.channelRawValue,
                    compatibleBundlePath: candidate?.bundlePath
                )
            )
        }
        let configuration = ModelConfiguration(url: storeURL)
        do {
            let container = try makePersistentContainerWithContentionRetry(configuration: configuration)
            repairLegacyValuesIfNeeded(at: storeURL, build: appInfo.build)
            let metadata = compatibilityMetadata(appInfo: appInfo)
            do {
                try PersistentStoreCompatibilityService.writeMetadata(metadata, for: storeURL)
                try CompatibleASTRABuildRegistry.registerCurrentBuild(appInfo: appInfo)
            } catch {
                AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                    "result": "compatibility_metadata_write_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .warning)
            }
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "model_container_created",
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ])
            WorkspaceRecoveryService.markStoreGenerationEstablished()
            return Result(modelContainer: container, lease: lease, blocker: nil)
        } catch {
            return recoverOrBlock(
                from: error,
                sourceStoreURL: storeURL,
                lease: lease,
                canRecoverLegacyMigration: hasPendingLegacyStoreMigration,
                appInfo: appInfo
            )
        }
    }

    private static func repairLegacyValuesIfNeeded(at storeURL: URL, build: String) {
        guard UserDefaults.standard.string(forKey: AppStorageKeys.completedLegacyStoreRepairBuild) != build else {
            return
        }
        WorkspaceRecoveryService.repairLegacyStoreValues(at: storeURL)
        UserDefaults.standard.set(build, forKey: AppStorageKeys.completedLegacyStoreRepairBuild)
    }

    private enum OrphanedV12StartupOutcome {
        case continueOpening(URL)
        case blocked
    }

    private static func migrateOrphanedV12IfNeeded(
        storeURL: URL,
        appInfo: AppBuildInfo,
        fileManager: FileManager = .default
    ) -> OrphanedV12StartupOutcome {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return .continueOpening(storeURL)
        }

        switch OrphanedV12StoreMigrator.migrationProbe(storeURL: storeURL) {
        case .notRequired:
            return .continueOpening(storeURL)
        case .unavailable(let errorType):
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "result": "orphaned_v12_probe_unavailable",
                "error_type": errorType,
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ], level: .warning)
            return .continueOpening(storeURL)
        case .required:
            break
        }

        do {
            let recoveryURL = try WorkspaceRecoveryService.makeRecoveryStoreURL()
            let report = try OrphanedV12StoreMigrator.migrateCopy(
                from: storeURL,
                to: recoveryURL
            )
            let metadata = compatibilityMetadata(appInfo: appInfo)
            try WorkspaceRecoveryService.activateRecoveryStore(
                at: report.destinationStoreURL,
                compatibility: metadata
            )
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "result": "orphaned_v12_migrated",
                "source_schema": "12",
                "destination_schema": String(ASTRASchema.currentVersion),
                "preserved_rows": String(report.preservedRowCounts.values.reduce(0, +)),
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ])
            return .continueOpening(report.destinationStoreURL)
        } catch {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "result": "orphaned_v12_migration_blocked",
                "error_type": String(describing: type(of: error)),
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ], level: .error)
            return .blocked
        }
    }

    private static func recoverOrBlock(
        from error: Error,
        sourceStoreURL: URL,
        lease: PersistentStoreLease,
        canRecoverLegacyMigration: Bool,
        appInfo: AppBuildInfo
    ) -> Result {
        let decision = PersistentStoreOpenFailurePolicy.decision(for: error)
        var failureFields = PersistentStoreOpenFailurePolicy.diagnosticFields(for: error)
        failureFields.merge([
            "stage": "model_container_failed",
            "decision": String(describing: decision),
            "error_type": String(describing: type(of: error))
        ]) { _, new in new }
        AppLogger.audit(.dataStoreRecovered, category: "App", fields: failureFields, level: .warning)

        if canRecoverLegacyMigration,
           PersistentStoreOpenFailurePolicy.permitsFreshStoreForLegacyMigration(decision) {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "result": "legacy_store_recovery_authorized",
                "open_decision": String(describing: decision),
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ], level: .warning)
        }

        guard decision == .verifiedCorruption else {
            let blocker: PersistentStoreRecoveryBlocker
            switch decision {
            case .incompatibleNewerSchema:
                // SwiftData can erase Core Data's model-version detail while
                // wrapping the open error. Re-read the store metadata through
                // the non-attaching compatibility boundary before falling back
                // to the next schema version.
                let compatibility = PersistentStoreCompatibilityService.assess(
                    storeURL: sourceStoreURL,
                    latestSupportedSchemaVersion: appInfo.schemaVersion
                )
                let requiredSchemaVersion = PersistentStoreRecoveryPolicy.requiredSchemaVersion(
                    afterOpenFailure: compatibility,
                    supportedSchemaVersion: appInfo.schemaVersion
                )
                let candidate = appInfo.channelRawValue == "dev" ? CompatibleASTRABuildRegistry.compatibleBuild(
                    requiredSchemaVersion: requiredSchemaVersion,
                    channel: appInfo.channelRawValue,
                    excludingBundlePath: Bundle.main.bundleURL.standardizedFileURL.path
                ) : nil
                blocker = PersistentStoreRecoveryPolicy.incompatibleBlocker(
                    requiredSchemaVersion: requiredSchemaVersion,
                    supportedSchemaVersion: appInfo.schemaVersion,
                    channel: appInfo.channelRawValue,
                    compatibleBundlePath: candidate?.bundlePath
                )
            case .transientContention:
                blocker = PersistentStoreRecoveryBlocker(
                    kind: .contention,
                    title: "The ASTRA store is temporarily unavailable",
                    message: "SQLite remained busy after \(PersistentStoreRetryPolicy.contentionDelays.count) automatic retries. Wait for the other operation to finish, then relaunch.",
                    technicalDetail: "retry_count=\(PersistentStoreRetryPolicy.contentionDelays.count)",
                    actions: [.revealStore, .quit]
                )
            case .blockedUnknown, .verifiedCorruption:
                blocker = PersistentStoreRecoveryBlocker(
                    title: "ASTRA could not safely open its store",
                    message: "The failure was not proven to be recoverable, so ASTRA left the store unchanged."
                )
            }
            return Result(modelContainer: inMemoryContainer(), lease: lease, blocker: blocker)
        }

        do {
            _ = try WorkspaceRecoveryService.preserveReadableStoreBeforeRecovery(at: sourceStoreURL)
            return createFreshRecoveryStore(lease: lease, appInfo: appInfo)
        } catch {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "stage": "recovery_store_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return Result(
                modelContainer: inMemoryContainer(),
                lease: lease,
                blocker: PersistentStoreRecoveryBlocker(
                    title: "ASTRA could not recover its store",
                    message: "The original store was left in place. Review the preserved backup before trying recovery again."
                )
            )
        }
    }

    private static func createFreshRecoveryStore(lease: PersistentStoreLease, appInfo: AppBuildInfo) -> Result {
        do {
            let recoveryStoreURL = try WorkspaceRecoveryService.makeRecoveryStoreURL()
            let recoveryContainer = try makePersistentContainer(
                configuration: ModelConfiguration(url: recoveryStoreURL)
            )
            guard WorkspaceRecoveryService.sqliteIntegrityIsValid(at: recoveryStoreURL) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let metadata = compatibilityMetadata(appInfo: appInfo)
            try WorkspaceRecoveryService.activateRecoveryStore(at: recoveryStoreURL, compatibility: metadata)
            try? CompatibleASTRABuildRegistry.registerCurrentBuild(appInfo: appInfo)
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "result": "recovery_store_created",
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ])
            return Result(modelContainer: recoveryContainer, lease: lease, blocker: nil)
        } catch {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "stage": "recovery_store_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return Result(
                modelContainer: inMemoryContainer(),
                lease: lease,
                blocker: PersistentStoreRecoveryBlocker(
                    title: "ASTRA could not recover its store",
                    message: "The original store was left in place. Review the preserved backup before trying recovery again."
                )
            )
        }
    }

    private static func makePersistentContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static func makePersistentContainerWithContentionRetry(
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        var retryIndex = 0
        while true {
            do {
                return try makePersistentContainer(configuration: configuration)
            } catch {
                guard PersistentStoreOpenFailurePolicy.decision(for: error) == .transientContention,
                      retryIndex < PersistentStoreRetryPolicy.contentionDelays.count else {
                    throw error
                }
                let delay = PersistentStoreRetryPolicy.contentionDelays[retryIndex]
                retryIndex += 1
                AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                    "stage": "contention_retry",
                    "attempt": String(retryIndex),
                    "delay_ms": String(Int(delay * 1_000))
                ], level: .warning)
                Thread.sleep(forTimeInterval: delay)
            }
        }
    }

    static func compatibilityMetadata(appInfo: AppBuildInfo) -> PersistentStoreCompatibilityMetadata {
        PersistentStoreCompatibilityMetadata(
            schemaVersion: appInfo.schemaVersion,
            minimumReaderSchemaVersion: appInfo.schemaVersion,
            channel: appInfo.channelRawValue,
            appVersion: appInfo.version,
            appBuild: appInfo.build,
            gitCommit: appInfo.gitCommit,
            bundlePath: Bundle.main.bundleURL.standardizedFileURL.path
        )
    }

    private static func inMemoryContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        } catch {
            fatalError("Could not create ASTRA's in-memory blocked-startup container: \(error)")
        }
    }

    private static func blocked(title: String, message: String) -> Result {
        Result(
            modelContainer: inMemoryContainer(),
            lease: nil,
            blocker: PersistentStoreRecoveryBlocker(title: title, message: message)
        )
    }
}

public struct ASTRAApp: App {
    public let modelContainer: ModelContainer
    @NSApplicationDelegateAdaptor(ASTRAAppDelegate.self) private var appDelegate
    @StateObject private var storeLeaseHolder: StoreLeaseHolder
    @StateObject private var appUpdateController = AppUpdateController()
    @StateObject private var appSettings = AppSettingsSnapshotStore()
    @StateObject private var feedbackRouter = FeedbackReportRouter()
    @StateObject private var feedbackCrashOfferService = FeedbackCrashOfferService()
    @State private var runtime = AppRuntimeController()
    private let startupBlocker: PersistentStoreRecoveryBlocker?

    public init() {
        // Must run before any code constructs a WorkspaceExecutionEnvironment
        // with credential projections or reads TaskRoleProfile.runtime — see
        // RuntimeSeamRegistration.swift.
        RuntimeSeamRegistration.registerAll()
        var defaults = LoggingPreferences.registeredDefaults
        defaults[AppLogger.sensitiveModeKey] = true
        UserDefaults.standard.register(defaults: defaults)
        // Rotate logs if needed
        AppLogger.rotateIfNeeded()
        let appInfo = AppBuildInfo.current
        AppLogger.audit(.appStarted, category: "App", fields: [
            "channel": appInfo.channelRawValue,
            "version": appInfo.version,
            "build": appInfo.build,
            "git_commit": appInfo.gitCommit,
            "build_date": appInfo.buildDate,
            "bundle_path": appInfo.bundlePath,
            "executable_path": appInfo.executablePath,
            "linked_channel": LinkedAppChannelIdentity.marker,
            "app_intents": AstraAppShortcutRegistration.binaryMarker
        ], fieldMaxLength: 120)
        // AppKit/NSApplication setup (activation policy, dock icon, foreground
        // activation, App Shortcuts) is deferred to ASTRAAppDelegate's
        // applicationDidFinishLaunching. Touching NSApplication.shared *here*,
        // inside the SwiftUI App initializer, forces AppKit to bootstrap
        // prematurely — before the normal launch sequence — and that early
        // subsystem init (menu bar → NSWorkspace → WindowServer) probes TCC
        // services, which surfaced spurious Photos / Music / Input-Monitoring
        // permission prompts at launch. Fonts are CoreText-only, so they stay.
        let resourceBundle = AstraResourceBundle.current
        StanfordFontRegistrar.registerBundledFonts(bundle: resourceBundle)

        BundledToolInstaller.installBundledTools(bundle: resourceBundle)

        let isUITesting = ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") })
        let skipWorkspaceRecovery = ProcessInfo.processInfo.arguments.contains("--skip-workspace-recovery") ||
            ["1", "true", "yes"].contains(
                ProcessInfo.processInfo.environment["ASTRA_SKIP_WORKSPACE_RECOVERY"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        let startup = AstraStoreStartupCoordinator.start(isUITesting: isUITesting, appInfo: appInfo)
        modelContainer = startup.modelContainer
        startupBlocker = startup.blocker
        _storeLeaseHolder = StateObject(wrappedValue: StoreLeaseHolder(lease: startup.lease))

        Task.detached(priority: .utility) {
            StartupDiagnosticsService.record(
                stage: startup.blocker == nil ? "model_container_ready" : "model_container_blocked",
                isUITesting: isUITesting,
                skipWorkspaceRecovery: skipWorkspaceRecovery,
                persistentStoreURL: isUITesting ? nil : WorkspaceRecoveryService.existingPersistentStoreURL(),
                modelContainerResult: startup.blocker == nil ? "created" : "blocked"
            )
        }
        if isUITesting {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: ["mode": "ui-testing"])
        } else if let persistentStoreURL = WorkspaceRecoveryService.existingPersistentStoreURL() {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "mode": "persistent",
                "store": persistentStoreURL.lastPathComponent,
                "store_generation": WorkspaceRecoveryService.storeGeneration
            ])
        }
        if startupBlocker == nil {
            StartupCredentialMigrationService.schedule(modelContainer: modelContainer)
        }
    }

    /// Guards `runDeferredStartupWork` so post-launch chores run once per
    /// process even though `ContentView` (the WindowGroup root) can appear
    /// more than once. MainActor-isolated; only touched from that method.
    @MainActor private static var hasRunDeferredStartupWork = false

    /// Post-launch chores that used to run synchronously inside `init()` before
    /// the first frame. Invoked from `ContentView` once the window is on screen
    /// so capability sync, definition repair, the one-time Skill migrations, and
    /// orphaned-run recovery never delay launch. Idempotent and run-once.
    @MainActor
    public static func runDeferredStartupWork(modelContext: ModelContext) {
        guard !hasRunDeferredStartupWork else { return }
        hasRunDeferredStartupWork = true

        let isUITesting = ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") })
        guard !isUITesting else { return }
        let skipWorkspaceRecovery = ProcessInfo.processInfo.arguments.contains("--skip-workspace-recovery") ||
            ["1", "true", "yes"].contains(
                ProcessInfo.processInfo.environment["ASTRA_SKIP_WORKSPACE_RECOVERY"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )

        do {
            let result = try FeedbackPreparationStagingReconciler().reconcileAbandonedPackages()
            if result.removedPackageCount > 0 {
                AppLogger.info(
                    "Removed \(result.removedPackageCount) abandoned feedback staging package(s)",
                    category: "Diagnostics"
                )
            }
            if result.unsafePackageCount > 0 || result.failedPackageCount > 0 {
                AppLogger.error(
                    "Feedback staging reconciliation incomplete unsafe=\(result.unsafePackageCount) failed=\(result.failedPackageCount)",
                    category: "Diagnostics"
                )
            }
        } catch {
            AppLogger.error("Feedback staging reconciliation could not inspect its trusted root", category: "Diagnostics")
        }

        do {
            let recovered = try FeedbackOutboxService(
                modelContainer: modelContext.container,
                storageRoot: FeedbackReportStoragePaths.root
            ).recoverInterruptedAdoptions()
            if recovered > 0 {
                AppLogger.info(
                    "Recovered \(recovered) interrupted feedback package adoption(s)",
                    category: "Diagnostics"
                )
            }
        } catch {
            AppLogger.error(
                "Interrupted feedback package adoption recovery failed safely",
                category: "Diagnostics"
            )
        }

        if !skipWorkspaceRecovery {
            WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(modelContext: modelContext)
        }
        // Approved-package disk sync is owned by PluginCatalog.loadApprovedCapabilities()
        // (runtime.loadPluginCatalog()), which runs synchronously in
        // ContentView.handleAppear BEFORE this deferred Task. By the time we get
        // here the Capabilities directory is already seeded/pruned, so the repair
        // pass below sees a populated directory and its installedIDs early-out works.
        // Re-syncing here would just rewrite every built-in JSON a second time.
        let capabilityLibrary = CapabilityLibrary()
        CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions(
            modelContext: modelContext,
            library: capabilityLibrary,
            approvedPackages: PluginCatalog.builtInPackages
        )
        runOneTimeSkillMigrationsIfNeeded(modelContext: modelContext)
        TaskRunLifecycleService.recoverOrphanedRunningRuns(
            modelContext: modelContext,
            autoExportWorkspaces: !skipWorkspaceRecovery
        )
    }

    /// Legacy Skill data backfills, gated on the build number so they run once
    /// per app update instead of fetching the whole Skill table three times on
    /// every launch. The two migrations share a single fetch and a single save.
    @MainActor
    private static func runOneTimeSkillMigrationsIfNeeded(modelContext: ModelContext) {
        let currentBuild = AppBuildInfo.current.build
        if UserDefaults.standard.string(forKey: AppStorageKeys.completedStartupSkillMigrationsBuild) == currentBuild {
            return
        }

        let skills: [Skill]
        do {
            skills = try modelContext.fetch(FetchDescriptor<Skill>())
        } catch {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "startup_skill_migrations",
                "stage": "fetch_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return
        }

        let disallowedMigrated = migrateDisallowedToolsToBehavior(in: skills)
        let globalMarked = markBuiltInSkillsAsGlobal(in: skills)

        if disallowedMigrated > 0 || globalMarked > 0 {
            do {
                // Skills are global (not workspace-scoped), so there is no
                // workspace JSON mirror to refresh. The throwing coordinator
                // path (not synchronicity — every variant here is synchronous)
                // is what lets the catch below skip setting the build flag on
                // a failed save, so the migration retries next launch.
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                    workspace: nil,
                    modelContext: modelContext
                )
            } catch {
                AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                    "migration": "startup_skill_migrations",
                    "stage": "save_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
                // Leave the build flag unset so the migration retries next launch.
                return
            }
        }
        UserDefaults.standard.set(currentBuild, forKey: AppStorageKeys.completedStartupSkillMigrationsBuild)
    }

    /// One-time migration: move disallowedTools into behaviorInstructions, then clear the array.
    /// Mutates `skills` in place; the caller owns the fetch and the save. Returns the count changed.
    @discardableResult
    private static func migrateDisallowedToolsToBehavior(in skills: [Skill]) -> Int {
        var migrated = 0
        for skill in skills where !skill.disallowedTools.isEmpty {
            let toolList = skill.disallowedTools.joined(separator: ", ")
            let rule = "\nDo NOT use these tools: \(toolList)."
            if !skill.behaviorInstructions.contains(rule) {
                skill.behaviorInstructions += rule
            }
            skill.disallowedTools = []
            migrated += 1
        }
        if migrated > 0 {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "disallowed_tools_to_behavior",
                "skill_count": String(migrated)
            ])
        }
        return migrated
    }

    /// Mark universal skills as global so they're hidden from workspace skill lists.
    /// Mutates `skills` in place; the caller owns the fetch and the save. Returns the count changed.
    @discardableResult
    private static func markBuiltInSkillsAsGlobal(in skills: [Skill]) -> Int {
        var updated = 0
        for skill in skills where Skill.isBuiltInName(skill.name) && !skill.isBuiltIn {
            skill.isGlobal = true
            skill.isBuiltIn = true
            updated += 1
        }
        if updated > 0 {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "builtin_skills_global",
                "skill_count": String(updated)
            ])
        }
        return updated
    }

    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue

    private var resolvedAppearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    public var body: some Scene {
        WindowGroup(AppChannel.current.displayName, id: AppWindowIDs.main) {
            if let startupBlocker {
                StoreStartupBlockedView(
                    blocker: startupBlocker,
                    appUpdateController: appUpdateController
                )
            } else {
                ContentView(appUpdateController: appUpdateController, runtime: runtime)
                    .frame(minWidth: AppWindowLayout.mainMinimumWidth, minHeight: AppWindowLayout.mainMinimumHeight)
                    .environmentObject(appSettings)
                    .environmentObject(feedbackRouter)
                    .environmentObject(feedbackCrashOfferService)
                    .tint(Stanford.interactive)
                    .preferredColorScheme(resolvedAppearance.colorScheme)
                    .onOpenURL { url in
                        guard let route = AstraExternalRouteCodec.route(from: url) else { return }
                        AstraExternalRouteStore.shared.submit(route)
                    }
            }
        }
        .modelContainer(modelContainer)
        .defaultSize(width: AppWindowLayout.mainDefaultWidth, height: AppWindowLayout.mainDefaultHeight)
        .commands {
            // Replace SwiftUI's synthesized NewItemCommands. Besides giving
            // ASTRA deterministic ownership of this menu, this avoids a
            // macOS 26.5 restored-window recursion in scene command discovery.
            // The first item preserves the standard Command-N behavior. Manual
            // re-entry for the first-run wizard remains available; the normal path is
            // automatic (auto-shown once on first launch, then
            // `hasCompletedOnboarding` flips true). This item re-opens
            // the wizard on demand without touching any other app state.
            CommandGroup(replacing: .newItem) {
                NewMainWindowMenuItem()
                Divider()
                // Workspace creation via the File menu. The sidebar's
                // + button in the WORKSPACES header calls the same
                // closure. Import used to live next to New in a Menu
                // inside the sidebar header; it graduated here so the
                // sidebar + button could be a single direct action.
                NewWorkspaceMenuItem()
                ImportWorkspaceMenuItem()
                Divider()
                Button("Show Onboarding Wizard…") {
                    OnboardingReplayRequestService.request()
                }
            }

            CommandGroup(replacing: .appInfo) {
                AboutAstraMenuItem()
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(appUpdateController: appUpdateController)
            }

            CommandGroup(after: .help) {
                ReportProblemMenuItem()
            }

            CommandGroup(after: .toolbar) {
                Button("Increase Size") {
                    Stanford.uiScale = min(Stanford.uiScale + 0.1, 1.5)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Size") {
                    Stanford.uiScale = max(Stanford.uiScale - 0.1, 0.7)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Size") {
                    Stanford.uiScale = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Window("About \(AppChannel.current.displayName)", id: aboutAstraWindowID) {
            AboutAstraView()
                .tint(Stanford.interactive)
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentSize)

        Window("Logs", id: AppWindowIDs.logs) {
            LogViewerView()
                .frame(minWidth: 760, minHeight: 460)
                .tint(Stanford.interactive)
                .preferredColorScheme(resolvedAppearance.colorScheme)
                .environmentObject(feedbackRouter)
                .environmentObject(feedbackCrashOfferService)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 980, height: 620)
        .keyboardShortcut("l", modifiers: [.command, .option])

        Window("Usage", id: AppWindowIDs.usage) {
            UsageDashboardView()
                .frame(minWidth: 600, minHeight: 500)
                .tint(Stanford.interactive)
                .preferredColorScheme(resolvedAppearance.colorScheme)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 760, height: 620)
        .keyboardShortcut("u", modifiers: [.command, .option])

        Settings {
            SettingsView(appUpdateController: appUpdateController)
                .modelContainer(modelContainer)
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
    }
}
