import Foundation
import ASTRACore

public enum AppStorageKeys {
    public static let hasCompletedOnboarding = "astra.hasCompletedOnboarding"
    public static let hasPresentedOnboarding = "astra.hasPresentedOnboarding"
    public static let onboardingReplayRequested = "astra.onboardingReplayRequested.v1"
    public static let onboardingEnabledCapabilityIDs = "astra.onboardingEnabledCapabilityIDs"
    public static let skipPermissions = "skipPermissions"
    public static let securityGateDefaultedToReview = "astra.securityGateDefaultedToReview.v1"
    // Build number for which the one-time startup Skill migrations last ran.
    // Re-runs once after each app update as a self-healing legacy backfill.
    public static let completedStartupSkillMigrationsBuild = "astra.startup.completedSkillMigrationsBuild.v1"
    // Build number for which the legacy SQLite enum-raw-value repair last ran.
    // The repair is idempotent, so re-running it once after each app update
    // (e.g. when a schema/store change reintroduces stale enum values) is the
    // intended self-healing behavior; gating skips it on unchanged launches.
    public static let completedLegacyStoreRepairBuild = "astra.startup.completedLegacyStoreRepairBuild.v1"
    public static let hasSeenNewTaskNudge = "astra.hasSeenNewTaskNudge.v1"
    // Set when the user dismisses the first-launch "move to Applications"
    // prompt without moving. Prevents re-asking on every subsequent launch;
    // see ApplicationsFolderMover.
    public static let declinedMoveToApplications = "astra.install.declinedMoveToApplications.v1"
    public static let showStarredWorkspacesOnly = "astra.sidebar.showStarredWorkspacesOnly.v1"
    public static let workspaceSidebarSortMode = "astra.sidebar.workspaceSortMode.v1"
    public static let workspaceSidebarOrderingState = "astra.sidebar.workspaceOrderingState.v1"
    public static let diagnosticsScope = "astra.diagnostics.scope.v1"
    public static let feedbackInstallationID = "astra.feedback.installationID.v1"
    public static let feedbackCrashOfferLedger = "astra.feedback.crashOfferLedger.v1"
    public static let feedbackCrashScanWatermarkPrefix = "astra.feedback.crashScanWatermark.v1"
    public static let appUIScale = "appUIScale"
    public static let defaultRuntimeID = "defaultRuntimeID"
    public static let defaultModel = "defaultModel"
    public static let defaultAgentPolicyLevel = "astra.policy.defaultLevel.v1"
    public static let workspacesRoot = "workspacesRoot"
    public static let timeoutSeconds = "timeoutSeconds"
    public static let validationModel = "validationModel"
    public static let planShelfWidth = "astra.planShelf.width.v1"
    public static let browserShelfWidth = "astra.browserShelf.width.v1"
    public static let markdownShelfWidth = "astra.markdownShelf.width.v1"
    public static let queryShelfWidth = "astra.queryShelf.width.v1"
    public static let appPreviewShelfWidth = "astra.appPreviewShelf.width.v1"
    public static let managedShelfVisibilityOverrides = "astra.packs.managedShelfVisibilityOverrides.v1"
    public static let activeWorkspaceCanvasItemsByConversation = "astra.workspaceCanvas.activeItemsByConversation.v1"
    public static let rightRailWidth = "astra.rightRail.width.v1"
    public static let markdownShelfShowHiddenPaths = "astra.markdownShelf.showHiddenPaths.v1"
    public static let markdownShelfFileNavigatorPinned = "astra.markdownShelf.fileNavigatorPinned.v1"
    public static let markdownShelfFileNavigatorDiscovered = "astra.markdownShelf.fileNavigatorDiscovered.v1"
    public static let browserPinnedToTask = "astra.browser.pinnedToTask.v1"
    public static let markdownPinnedToTask = "astra.markdown.pinnedToTask.v1"
    public static let browserDebugCapture = "astra.browser.debugCapture.v1"
    public static let runtimeStreamDebugCapture = "astra.runtime.streamDebugCapture.v1"
    // OS-level execution sandbox enforcement: off | best_effort | strict.
    // See ExecutionSandbox and docs/specs/2026-06-06-seatbelt-execution-sandbox-plan.md.
    public static let sandboxEnforcement = "astra.runtime.sandboxEnforcement.v1"
    // When false, the Seatbelt profile denies outbound network (offline runs).
    public static let sandboxAllowNetwork = "astra.runtime.sandboxAllowNetwork.v1"
    // When true, ASTRA also wraps providers that ship their own OS sandbox
    // (Codex, Cursor, Antigravity) for defense-in-depth.
    public static let sandboxLayerNativeProviders = "astra.runtime.sandboxLayerNativeProviders.v1"
    // Runtime read-scope mode: open | audit | enforce. Strict enforcement always
    // resolves to enforce even if this preference is broader.
    public static let sandboxReadScope = "astra.runtime.sandboxReadScope.v1"
    public static let logRetentionDays = "astra.logging.retentionDays.v1"
    public static let browserAutoPromoteGoogleWorkspace = "astra.browser.autoPromoteGoogleWorkspace.v1"
    // Opt-in Tier 2 (utility-model) objective drift detection. Default OFF --
    // this is new/unproven; see ObjectiveAssessmentService.
    public static let objectiveDriftDetectionEnabled = "astra.objectiveAssessment.driftDetectionEnabled.v1"
    public static let defaultTokenBudget = "defaultTokenBudget"
    public static let budgetEnforcementMode = "astra.budget.enforcementMode.v1"
    public static let claudePath = "claudePath"
    public static let copilotPath = "copilotPath"
    public static let claudeProvider = "astra.claudeProvider.v1"
    public static let claudeVertexProjectID = "astra.claudeVertexProjectID.v1"
    public static let claudeVertexRegion = "astra.claudeVertexRegion.v1"
    public static let claudeVertexOpusModel = "astra.claudeVertexOpusModel.v1"
    public static let claudeVertexSonnetModel = "astra.claudeVertexSonnetModel.v1"
    public static let claudeVertexHaikuModel = "astra.claudeVertexHaikuModel.v1"
    public static let claudeAvailableModels = "astra.claude.availableModels.v1"
    public static let claudeModelsCheckedAt = "astra.claude.modelsCheckedAt.v1"
    public static let copilotAvailableModels = "astra.copilot.availableModels.v1"
    public static let copilotModelsCheckedAt = "astra.copilot.modelsCheckedAt.v1"
    public static let runtimeModelCacheRevision = "astra.runtime.modelCacheRevision.v1"
    public static let runtimeProviderSettingsRevision = "astra.runtime.providerSettingsRevision.v1"
    public static let roleProfileRevision = "astra.roleProfile.revision.v1"

    public static func runtimeExecutablePathKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return claudePath
        case .copilotCLI:
            return copilotPath
        default:
            return "astra.runtime.\(storageComponent(for: runtime)).executablePath.v1"
        }
    }

    public static func runtimeHomeDirectoryKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .copilotCLI:
            return "astra.copilot.homeDirectory.v1"
        default:
            return "astra.runtime.\(storageComponent(for: runtime)).homeDirectory.v1"
        }
    }

    public static func runtimeAvailableModelsKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return claudeAvailableModels
        case .copilotCLI:
            return copilotAvailableModels
        default:
            return "astra.runtime.\(storageComponent(for: runtime)).availableModels.v1"
        }
    }

    public static func runtimeModelsCheckedAtKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return claudeModelsCheckedAt
        case .copilotCLI:
            return copilotModelsCheckedAt
        default:
            return "astra.runtime.\(storageComponent(for: runtime)).modelsCheckedAt.v1"
        }
    }

    public static func storageComponent(for runtime: AgentRuntimeID) -> String {
        runtime.rawValue
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "_" || character == "-"
                    ? character
                    : "_"
            }
            .reduce(into: "") { $0.append($1) }
    }

    public static func roleProfileRuntimeKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).runtime.v1"
    }

    public static func roleProfileModelKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).model.v1"
    }

    public static func roleProfileBudgetKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).budget.v1"
    }

    public static func roleProfilePolicyKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).policy.v1"
    }
}
