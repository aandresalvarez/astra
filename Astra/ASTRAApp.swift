import SwiftUI
import SwiftData
import AppKit

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

public struct ASTRAApp: App {
    public let modelContainer: ModelContainer

    public init() {
        UserDefaults.standard.register(defaults: [AppLogger.sensitiveModeKey: true])
        // Rotate logs if needed
        AppLogger.rotateIfNeeded()
        AppLogger.audit(.appStarted, category: "App")
        // Bring app to foreground when launched from terminal via `swift run`
        NSApplication.shared.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        AppLogger.audit(.appActivated, category: "App")

        let schema = Schema(ASTRASchemaV1.models)

        // UI tests need a clean database each run
        let isUITesting = ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") })
        let persistentStoreURL = isUITesting ? nil : WorkspaceRecoveryService.preparePersistentStoreURL()
        let config = persistentStoreURL.map { ModelConfiguration(url: $0) }
            ?? ModelConfiguration(isStoredInMemoryOnly: true)
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
            if !isUITesting {
                WorkspaceRecoveryService.recoverMissingWorkspaces(modelContext: modelContainer.mainContext)
                PluginCatalog().seedBuiltInPlugins()
                Self.migrateDisallowedToolsToBehavior(modelContext: modelContainer.mainContext)
                Self.markBuiltInSkillsAsGlobal(modelContext: modelContainer.mainContext)
            }
        } catch {
            AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                "stage": "model_container_failed",
                "error_type": String(describing: type(of: error))
            ], level: .warning)
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
                if !isUITesting {
                    WorkspaceRecoveryService.recoverMissingWorkspaces(modelContext: modelContainer.mainContext)
                    PluginCatalog().seedBuiltInPlugins()
                    Self.migrateDisallowedToolsToBehavior(modelContext: modelContainer.mainContext)
                    Self.markBuiltInSkillsAsGlobal(modelContext: modelContainer.mainContext)
                }
            } catch {
                AppLogger.audit(.dataStoreRecovered, category: "App", fields: [
                    "stage": "model_container_reset_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }

    /// One-time migration: move disallowedTools into behaviorInstructions, then clear the array.
    private static func migrateDisallowedToolsToBehavior(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Skill>()
        let skills: [Skill]
        do {
            skills = try modelContext.fetch(descriptor)
        } catch {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "disallowed_tools_to_behavior",
                "stage": "fetch_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return
        }
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
            do {
                try modelContext.save()
            } catch {
                AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                    "migration": "disallowed_tools_to_behavior",
                    "stage": "save_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "disallowed_tools_to_behavior",
                "skill_count": String(migrated)
            ])
        }
    }

    /// Mark universal skills as global so they're hidden from workspace skill lists
    private static func markBuiltInSkillsAsGlobal(modelContext: ModelContext) {
        let builtInNames: Set<String> = ["Read-Only", "Safe Bash", "Test Runner",
                                          "Read-Only Explorer", "Safe Executor"]
        let descriptor = FetchDescriptor<Skill>()
        let skills: [Skill]
        do {
            skills = try modelContext.fetch(descriptor)
        } catch {
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "builtin_skills_global",
                "stage": "fetch_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return
        }
        var updated = 0
        for skill in skills where builtInNames.contains(skill.name) && !skill.isBuiltIn {
            skill.isGlobal = true
            skill.isBuiltIn = true
            updated += 1
        }
        if updated > 0 {
            do {
                try modelContext.save()
            } catch {
                AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                    "migration": "builtin_skills_global",
                    "stage": "save_failed",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
            }
            AppLogger.audit(.skillToolPermissionChanged, category: "App", fields: [
                "migration": "builtin_skills_global",
                "skill_count": String(updated)
            ])
        }
    }

    @AppStorage(AppearancePreference.storageKey) private var appearanceRaw = AppearancePreference.system.rawValue

    private var resolvedAppearance: AppearancePreference {
        AppearancePreference(rawValue: appearanceRaw) ?? .system
    }

    public var body: some Scene {
        WindowGroup("ASTRA") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .tint(Stanford.cardinalRed)
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1200, height: 750)
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

        Settings {
            SettingsView()
                .modelContainer(modelContainer)
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
    }
}
