import Foundation

// Moved here as part of Track A2.2 (finishing A2's Models cycle-break) so
// `Astra/Models/AgentTask.swift`/`TaskSchedule.swift`/`TaskTemplate.swift`
// can depend on it without pulling in the Settings subsystem.
public enum TaskExecutionDefaults {
    public static let runtime = AgentRuntimeID.claudeCode

    /// `model` is read as a default parameter value by `AgentTask`/
    /// `TaskSchedule`/`TaskTemplate` initializers - i.e. by nearly every test
    /// in the suite that constructs a task, not just a handful of narrow
    /// scenarios. Unlike `ExecutionPathSafety`/`registeredRuntime(_:)` (real
    /// security/runtime-selection gates that must trap if unregistered),
    /// this is a low-stakes UX default with a verifiable, stable answer, so
    /// it uses the seam's non-trapping `currentIfRegistered` accessor and
    /// falls back to a hardcoded literal rather than crashing a whole test
    /// process over suite-execution ordering (confirmed empirically: routing
    /// this through the trapping `.required` accessor crashed the first test
    /// in the suite to construct a default `AgentTask()`, before any of the
    /// registering suites had run). The literal is kept in sync with the live
    /// registry default by `AgentRuntimeAdapterTests.claudeCodeDefaultModelIsPinned()`.
    public static let model: String = {
        if let lookup = AgentRuntimeRegistrySeam.currentIfRegistered {
            return lookup.defaultModel(for: runtime)
        }
        return "claude-sonnet-4-6"
    }()

    public static let tokenBudget = 100_000
    public static let budgetEnforcementMode = BudgetEnforcementMode.warning
    public static let budgetPresets = [10_000, 25_000, 50_000, 100_000, 200_000, 500_000, 1_000_000, 0]
}

/// The pure (UserDefaults-free) half of `BudgetEnforcementMode`. Its
/// `configuredDefault`/`configuredDefault(in:)` statics, which read
/// `UserDefaults`/`AppStorageKeys`, stay behind as an app-target extension in
/// `Astra/Services/Settings/AppearancePreference.swift` - `ASTRACore` has no
/// business reading user preferences.
public enum BudgetEnforcementMode: String, CaseIterable, Identifiable, Sendable {
    case hardStop = "hard_stop"
    case warning = "warning"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hardStop: "Hard Stop"
        case .warning: "Warning Only"
        }
    }

    public var helpText: String {
        switch self {
        case .hardStop: "Stop the provider process when ASTRA estimates or receives usage above the task budget."
        case .warning: "Keep the task running and record a budget warning when usage goes over the task budget."
        }
    }
}
