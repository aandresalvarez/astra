#if ASTRA_ENABLE_APP_INTENTS
import AppIntents
import Foundation

private enum AstraIntentRouter {
    @MainActor
    static func submit(_ route: AstraExternalRoute) {
        AstraExternalRouteStore.shared.submit(route)
    }
}

struct OpenAstraWorkspaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open ASTRA Workspace"
    static var description = IntentDescription("Open ASTRA to a selected workspace.")
    static var openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: AstraWorkspaceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AstraIntentRouter.submit(
            AstraExternalRoute(destination: .workspace(workspace.id))
        )
        return .result(dialog: "Opening \(workspace.name) in ASTRA.")
    }
}

struct OpenAstraTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Open ASTRA Task"
    static var description = IntentDescription("Open ASTRA to a selected task.")
    static var openAppWhenRun = true

    @Parameter(title: "Task")
    var task: AstraTaskEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AstraIntentRouter.submit(
            AstraExternalRoute(destination: .task(task.id))
        )
        return .result(dialog: "Opening \(task.title) in ASTRA.")
    }
}

struct ContinueAstraTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue ASTRA Task"
    static var description = IntentDescription("Open the latest unfinished ASTRA task in a workspace.")
    static var openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: AstraWorkspaceEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AstraIntentRouter.submit(
            AstraExternalRoute(destination: .continueLatestUnfinishedTask(workspaceID: workspace.id))
        )
        return .result(dialog: "Opening the latest unfinished task in \(workspace.name).")
    }
}

struct CreateAstraDraftTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Create ASTRA Task"
    static var description = IntentDescription("Create a draft ASTRA task in a workspace.")
    static var openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: AstraWorkspaceEntity

    @Parameter(
        title: "Goal",
        requestValueDialog: "What should ASTRA do?"
    )
    var goal: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AstraIntentRouter.submit(
            AstraExternalRoute(
                destination: .createTask(
                    workspaceID: workspace.id,
                    goal: goal,
                    shouldRun: false
                )
            )
        )
        return .result(dialog: "Creating a draft ASTRA task in \(workspace.name).")
    }
}

struct CreateAndRunAstraTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Create and Run ASTRA Task"
    static var description = IntentDescription("Create an ASTRA task in a workspace and start it immediately.")
    static var openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: AstraWorkspaceEntity

    @Parameter(
        title: "Goal",
        requestValueDialog: "What should ASTRA do?"
    )
    var goal: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AstraIntentRouter.submit(
            AstraExternalRoute(
                destination: .createTask(
                    workspaceID: workspace.id,
                    goal: goal,
                    shouldRun: true
                )
            )
        )
        return .result(dialog: "Creating and running an ASTRA task in \(workspace.name).")
    }
}

struct AstraAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .red

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAstraWorkspaceIntent(),
            phrases: [
                "Open \(\.$workspace) in \(.applicationName)",
                "Open my \(.applicationName) workspace"
            ],
            shortTitle: "Open Workspace",
            systemImageName: "folder"
        )

        AppShortcut(
            intent: OpenAstraTaskIntent(),
            phrases: [
                "Open \(\.$task) in \(.applicationName)",
                "Open my \(.applicationName) task"
            ],
            shortTitle: "Open Task",
            systemImageName: "text.bubble"
        )

        AppShortcut(
            intent: ContinueAstraTaskIntent(),
            phrases: [
                "Continue my unfinished \(.applicationName) task in \(\.$workspace)",
                "Continue \(.applicationName) in \(\.$workspace)"
            ],
            shortTitle: "Continue Task",
            systemImageName: "arrow.clockwise"
        )

        AppShortcut(
            intent: CreateAstraDraftTaskIntent(),
            phrases: [
                "Create an \(.applicationName) task in \(\.$workspace)",
                "Create a draft \(.applicationName) task in \(\.$workspace)"
            ],
            shortTitle: "Create Task",
            systemImageName: "plus.message"
        )

        AppShortcut(
            intent: CreateAndRunAstraTaskIntent(),
            phrases: [
                "Create and run an \(.applicationName) task in \(\.$workspace)",
                "Run a new \(.applicationName) task in \(\.$workspace)"
            ],
            shortTitle: "Create and Run",
            systemImageName: "bolt.fill"
        )
    }
}
#endif
