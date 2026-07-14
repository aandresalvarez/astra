import Foundation

enum WorkspaceSetupFormMode: Equatable {
    case onboarding
    case standard

    var validationSource: String {
        self == .onboarding ? "onboarding_workspace_validation" : "new_workspace_validation"
    }

    var presentation: WorkspaceCreationPresentation {
        WorkspaceCreationPresentation(
            headerSubtitle: "A focused place for related tasks, shared guidance, and system access.",
            namePlaceholder: "Example: GitHub PRs",
            guidanceDescription: "Shared with every task in this workspace: preferences, conventions, usernames, and boundaries.",
            guidancePlaceholder: "Example: Use alvaro on GitHub. Prefer concise summaries. Ask before release changes.",
            capabilitiesTitle: "Capabilities",
            capabilitiesSummary: "Choose which systems tasks in this workspace can use. You can change this later.",
            capabilitiesExpandedDescription: "Choose only what this work needs now. Setup can be changed later in Workspace Context.",
            showsWorkspacePrimer: self == .onboarding,
            expandsCapabilitiesInitially: false
        )
    }
}

struct WorkspaceCreationPresentation: Equatable {
    let headerSubtitle: String
    let namePlaceholder: String
    let guidanceDescription: String
    let guidancePlaceholder: String
    let capabilitiesTitle: String
    let capabilitiesSummary: String
    let capabilitiesExpandedDescription: String
    let showsWorkspacePrimer: Bool
    let expandsCapabilitiesInitially: Bool

    static let primerTitle = "Keep one body of work together"
    static let primerDescription = "Use a workspace when tasks share a goal and way of working—for example GitHub PRs, Clinical Ops, or Weekly Reporting."
    static let emptyNameRequirement = "Enter a workspace name to continue."
}
