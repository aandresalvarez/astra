import Foundation
import ASTRACore
import ASTRAModels
import SwiftUI

struct OnboardingActionGuidance: Equatable {
    let title: String
    let detail: String
    let systemImage: String
}

struct OnboardingStepPresentation: Equatable {
    let heading: String
    let subtitle: String
    let supportingText: String?
    let primaryActionTitle: String
    let actionGuidance: OnboardingActionGuidance
}

enum OnboardingPresentationPolicy {
    static func shouldPresent(
        hasCompletedOnboarding: Bool,
        isUITestingSeededLaunch: Bool
    ) -> Bool {
        !hasCompletedOnboarding && !isUITestingSeededLaunch
    }

    static func requestReplay(
        hasCompletedOnboarding: inout Bool,
        replayRequested: inout Bool
    ) {
        replayRequested = true
        hasCompletedOnboarding = false
    }

    static func complete(
        hasCompletedOnboarding: inout Bool,
        replayRequested: inout Bool
    ) {
        hasCompletedOnboarding = true
        replayRequested = false
    }
}

enum OnboardingPresentationBindings {
    static func sheet(
        hasCompletedOnboarding: Binding<Bool>,
        replayRequested: Binding<Bool>,
        isUITestingSeededLaunch: Bool
    ) -> Binding<Bool> {
        Binding(
            get: {
                OnboardingPresentationPolicy.shouldPresent(
                    hasCompletedOnboarding: hasCompletedOnboarding.wrappedValue,
                    isUITestingSeededLaunch: isUITestingSeededLaunch
                )
            },
            set: { isPresented in
                guard !isPresented, replayRequested.wrappedValue else { return }
                complete(
                    hasCompletedOnboarding: hasCompletedOnboarding,
                    replayRequested: replayRequested
                )
            }
        )
    }

    static func completion(
        hasCompletedOnboarding: Binding<Bool>,
        replayRequested: Binding<Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { hasCompletedOnboarding.wrappedValue },
            set: { isCompleted in
                guard isCompleted else {
                    hasCompletedOnboarding.wrappedValue = false
                    return
                }
                complete(
                    hasCompletedOnboarding: hasCompletedOnboarding,
                    replayRequested: replayRequested
                )
            }
        )
    }

    static func complete(
        hasCompletedOnboarding: Binding<Bool>,
        replayRequested: Binding<Bool>
    ) {
        var completed = hasCompletedOnboarding.wrappedValue
        var replay = replayRequested.wrappedValue
        OnboardingPresentationPolicy.complete(
            hasCompletedOnboarding: &completed,
            replayRequested: &replay
        )
        hasCompletedOnboarding.wrappedValue = completed
        replayRequested.wrappedValue = replay
    }
}

enum OnboardingReplayRequestService {
    static func request(in defaults: UserDefaults = .standard) {
        var completed = defaults.bool(forKey: AppStorageKeys.hasCompletedOnboarding)
        var replay = defaults.bool(forKey: AppStorageKeys.onboardingReplayRequested)
        OnboardingPresentationPolicy.requestReplay(
            hasCompletedOnboarding: &completed,
            replayRequested: &replay
        )
        defaults.set(replay, forKey: AppStorageKeys.onboardingReplayRequested)
        defaults.set(completed, forKey: AppStorageKeys.hasCompletedOnboarding)
    }
}

enum OnboardingRuntimeListPresentation {
    static let primaryRowLimit = 3

    static func orderedRows(
        _ rows: [RuntimeProviderRowPresentation],
        registryOrder: [AgentRuntimeID]
    ) -> [RuntimeProviderRowPresentation] {
        rows.sorted { lhs, rhs in
            if lhs.isSelected != rhs.isSelected { return lhs.isSelected }

            let lhsRank = RuntimeProviderListPresentation.recommendedOrder.firstIndex(of: lhs.id) ?? Int.max
            let rhsRank = RuntimeProviderListPresentation.recommendedOrder.firstIndex(of: rhs.id) ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            let lhsRegistryIndex = registryOrder.firstIndex(of: lhs.id) ?? Int.max
            let rhsRegistryIndex = registryOrder.firstIndex(of: rhs.id) ?? Int.max
            return lhsRegistryIndex < rhsRegistryIndex
        }
    }

    static func primaryRows(
        from orderedRows: [RuntimeProviderRowPresentation]
    ) -> [RuntimeProviderRowPresentation] {
        Array(orderedRows.prefix(primaryRowLimit))
    }

    static func additionalRows(
        from orderedRows: [RuntimeProviderRowPresentation]
    ) -> [RuntimeProviderRowPresentation] {
        Array(orderedRows.dropFirst(primaryRowLimit))
    }
}

extension OnboardingWizardView.Step {
    func presentation(workspaceName: String? = nil) -> OnboardingStepPresentation {
        switch self {
        case .requiredCLIs:
            return OnboardingStepPresentation(
                heading: "Choose an AI runtime",
                subtitle: "ASTRA runs tasks through a supported agent tool on this Mac. Choose one to begin; you can switch later in Settings.",
                supportingText: "Next, you'll review local access and create your first workspace.",
                primaryActionTitle: "Review access",
                actionGuidance: OnboardingActionGuidance(
                    title: "Next: local access",
                    detail: "Checks Keychain and workspace storage. No workspace is created yet.",
                    systemImage: "checkmark.shield"
                )
            )
        case .permissions:
            return OnboardingStepPresentation(
                heading: "Review local access",
                subtitle: "Check the local permissions ASTRA needs now. Browser control is verified later, when you use it.",
                supportingText: nil,
                primaryActionTitle: "Set up workspace",
                actionGuidance: OnboardingActionGuidance(
                    title: "Next: workspace setup",
                    detail: "Name the workspace, add guidance, and choose capabilities. No workspace is created yet.",
                    systemImage: "folder.badge.plus"
                )
            )
        case .workspaceRoot:
            return OnboardingStepPresentation(
                heading: "Create your first workspace",
                subtitle: WorkspaceSetupFormMode.onboarding.presentation.headerSubtitle,
                supportingText: nil,
                primaryActionTitle: "Create workspace",
                actionGuidance: OnboardingActionGuidance(
                    title: "Creates your workspace",
                    detail: "Saves the workspace and selected capabilities, then shows a final summary.",
                    systemImage: "folder.badge.plus"
                )
            )
        case .ready:
            let resolvedName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let actionTitle = resolvedName.map { !$0.isEmpty ? "Open \($0)" : "Open workspace" } ?? "Open workspace"
            return OnboardingStepPresentation(
                heading: "You're ready",
                subtitle: "Your workspace is ready. Open it and start asking tasks that use its enabled capabilities.",
                supportingText: nil,
                primaryActionTitle: actionTitle,
                actionGuidance: OnboardingActionGuidance(
                    title: "Opens your workspace",
                    detail: "Closes setup and opens the configured workspace.",
                    systemImage: "arrow.up.forward.app"
                )
            )
        }
    }
}
