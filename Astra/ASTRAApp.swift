import SwiftUI
import SwiftData
import AppKit
import AppIntents

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

extension FocusedValues {
    var newWorkspaceAction: NewWorkspaceActionKey.Value? {
        get { self[NewWorkspaceActionKey.self] }
        set { self[NewWorkspaceActionKey.self] = newValue }
    }

    var importWorkspaceAction: ImportWorkspaceActionKey.Value? {
        get { self[ImportWorkspaceActionKey.self] }
        set { self[ImportWorkspaceActionKey.self] = newValue }
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
        AppLogger.audit(.appActivated, category: "App")
        AstraAppShortcuts.updateAppShortcutParameters()
    }
}

public struct ASTRAApp: App {
    public let modelContainer: ModelContainer
    @NSApplicationDelegateAdaptor(ASTRAAppDelegate.self) private var appDelegate
    @StateObject private var appUpdateController = AppUpdateController()
    @StateObject private var appSettings = AppSettingsSnapshotStore()
    @State private var runtime = AppRuntimeController()

    public init() {
        var defaults = LoggingPreferences.registeredDefaults
        defaults[AppLogger.sensitiveModeKey] = true
        UserDefaults.standard.register(defaults: defaults)
        // Rotate logs if needed
        AppLogger.rotateIfNeeded()
        AppLogger.audit(.appStarted, category: "App")
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

        let schema = ASTRASchema.current
        BundledToolInstaller.installBundledTools(bundle: resourceBundle)

        // UI tests need a clean database each run
        let isUITesting = ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") })
        let skipWorkspaceRecovery = ProcessInfo.processInfo.arguments.contains("--skip-workspace-recovery") ||
            ["1", "true", "yes"].contains(
                ProcessInfo.processInfo.environment["ASTRA_SKIP_WORKSPACE_RECOVERY"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        let persistentStoreURL = isUITesting ? nil : WorkspaceRecoveryService.preparePersistentStoreURL()
        if let persistentStoreURL, !isUITesting {
            // The legacy enum repair is idempotent and only matters once per
            // build (it backfills stale enum raw values written by older
            // schemas). Gate it on the build number so we don't open a 2nd
            // SQLite connection and run ~7 full-table UPDATE scans on every
            // launch. Re-runs once after each app update — mirrors the
            // one-time Skill migration gate. AppBuildInfo.current.build only
            // reads Bundle.main.infoDictionary and UserDefaults is already
            // safe here, so this is fine before ModelContainer creation.
            let currentBuild = AppBuildInfo.current.build
            if UserDefaults.standard.string(forKey: AppStorageKeys.completedLegacyStoreRepairBuild) != currentBuild {
                WorkspaceRecoveryService.repairLegacyStoreValues(at: persistentStoreURL)
                UserDefaults.standard.set(currentBuild, forKey: AppStorageKeys.completedLegacyStoreRepairBuild)
            }
        }
        let config = persistentStoreURL.map { ModelConfiguration(url: $0) }
            ?? ModelConfiguration(isStoredInMemoryOnly: true)
        // Telemetry only — nobody awaits it, and its default `crashReports`
        // argument scans the system crash-report directories. Run it off the
        // launch critical path so that I/O doesn't delay the first frame.
        Task.detached(priority: .utility) {
            StartupDiagnosticsService.record(
                stage: "pre_model_container",
                isUITesting: isUITesting,
                skipWorkspaceRecovery: skipWorkspaceRecovery,
                persistentStoreURL: persistentStoreURL
            )
        }
        if isUITesting {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: ["mode": "ui-testing"])
        } else if let persistentStoreURL {
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "mode": "persistent",
                "store": persistentStoreURL.lastPathComponent
            ])
        }
        do {
            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [config]
            )
            AppLogger.audit(.dataStoreSelected, category: "App", fields: [
                "result": "model_container_created"
            ])
            Task.detached(priority: .utility) {
                StartupDiagnosticsService.record(
                    stage: "model_container_ready",
                    isUITesting: isUITesting,
                    skipWorkspaceRecovery: skipWorkspaceRecovery,
                    persistentStoreURL: persistentStoreURL,
                    modelContainerResult: "created"
                )
            }
            // Post-container chores (workspace recovery, capability sync +
            // definition repair, one-time Skill migrations, orphaned-run
            // recovery) are deferred to runDeferredStartupWork(), invoked from
            // ContentView after the first frame, so none of this DB/JSON/FS
            // work blocks launch. See runDeferredStartupWork below.
        } catch {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "stage": "model_container_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
            StartupDiagnosticsService.record(
                stage: "model_container_failed",
                isUITesting: isUITesting,
                skipWorkspaceRecovery: skipWorkspaceRecovery,
                persistentStoreURL: persistentStoreURL,
                modelContainerResult: "initial_failed",
                level: .warning
            )
            WorkspaceRecoveryService.backupStore(at: config.url)
            do {
                modelContainer = try ModelContainer(
                    for: schema,
                    migrationPlan: ASTRAMigrationPlan.self,
                    configurations: [config]
                )
                AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                    "result": "model_container_recreated"
                ])
                StartupDiagnosticsService.record(
                    stage: "model_container_recovered",
                    isUITesting: isUITesting,
                    skipWorkspaceRecovery: skipWorkspaceRecovery,
                    persistentStoreURL: persistentStoreURL,
                    modelContainerResult: "recreated"
                )
                // Post-container chores are deferred to runDeferredStartupWork()
                // (invoked from ContentView after first frame). See above.
            } catch {
                AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                    "stage": "model_container_reset_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
                StartupDiagnosticsService.record(
                    stage: "model_container_reset_failed",
                    isUITesting: isUITesting,
                    skipWorkspaceRecovery: skipWorkspaceRecovery,
                    persistentStoreURL: persistentStoreURL,
                    modelContainerResult: "reset_failed",
                    level: .error
                )
                fatalError("Failed to create ModelContainer: \(error)")
            }
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
                try modelContext.save()
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
        WindowGroup(AppChannel.current.displayName) {
            ContentView(appUpdateController: appUpdateController, runtime: runtime)
                .frame(minWidth: AppWindowLayout.mainMinimumWidth, minHeight: AppWindowLayout.mainMinimumHeight)
                .environmentObject(appSettings)
                .tint(Stanford.interactive)
                .preferredColorScheme(resolvedAppearance.colorScheme)
                .onOpenURL { url in
                    guard let route = AstraExternalRouteCodec.route(from: url) else { return }
                    AstraExternalRouteStore.shared.submit(route)
                }
        }
        .modelContainer(modelContainer)
        .defaultSize(width: AppWindowLayout.mainDefaultWidth, height: AppWindowLayout.mainDefaultHeight)
        .commands {
            // Lives in the File menu (after "New ASTRA Window"). Manual
            // re-entry for the first-run wizard — the normal path is
            // automatic (auto-shown once on first launch, then
            // `hasCompletedOnboarding` flips true). This item re-opens
            // the wizard on demand without touching any other app state.
            CommandGroup(after: .newItem) {
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
                    UserDefaults.standard.set(false, forKey: AppStorageKeys.hasCompletedOnboarding)
                }
            }

            CommandGroup(replacing: .appInfo) {
                AboutAstraMenuItem()
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(appUpdateController: appUpdateController)
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
