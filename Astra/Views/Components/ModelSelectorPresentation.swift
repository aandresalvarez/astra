import Foundation
import ASTRACore

/// Why a provider can or cannot be picked right now. `needsSetup` is the only
/// state the selector answers with an action; `unavailable` is informational
/// (still checking, or blocked for this particular request).
enum ModelSelectorProviderAvailability: Equatable {
    case ready
    case needsSetup
    case unavailable(reason: String)

    static func resolve(
        readinessKnown: Bool,
        allowsLaunch: Bool,
        blockedReason: String?
    ) -> ModelSelectorProviderAvailability {
        guard readinessKnown else { return .unavailable(reason: "Checking provider setup…") }
        guard allowsLaunch else { return .needsSetup }
        if let blockedReason { return .unavailable(reason: blockedReason) }
        return .ready
    }
}

struct ModelSelectorProviderRow: Equatable, Identifiable {
    let runtime: AgentRuntimeID
    let title: String
    let availability: ModelSelectorProviderAvailability
    let modelCount: Int
    let isCurrent: Bool

    var id: String { runtime.rawValue }
}

struct ModelSelectorModelRow: Equatable, Identifiable {
    /// Stable id within one provider: the model id, or the base id for an
    /// Antigravity family whose reasoning efforts are separate SKUs.
    let id: String
    let title: String
    let subtitle: String?
    /// Exact `--model` value, surfaced as a tooltip instead of a third line.
    let help: String?
    let isSelected: Bool

    /// Text the search field matches against: what the user reads plus the
    /// exact id they might paste.
    var searchText: String {
        [title, subtitle, id].compactMap { $0 }.joined(separator: " ")
    }
}

struct ModelSelectorListing: Equatable {
    var rows: [ModelSelectorModelRow]
    var isFiltered: Bool
}

struct ModelSelectorRailGroups: Equatable {
    var providers: [ModelSelectorProviderRow]
    var needsSetup: [ModelSelectorProviderRow]
}

enum ModelSelectorPresentation {
    /// Shared status lives in the group, not on each row: providers that still
    /// need setup move to their own group instead of carrying a per-row pill.
    static func railGroups(_ rows: [ModelSelectorProviderRow]) -> ModelSelectorRailGroups {
        ModelSelectorRailGroups(
            providers: rows.filter { $0.availability != .needsSetup },
            needsSetup: rows.filter { $0.availability == .needsSetup }
        )
    }

    /// Every model the provider offers, in catalog order, or the matches for
    /// the search text. The list scrolls instead of hiding models behind a
    /// disclosure: a user scanning for a model should never have to expand first.
    static func listing(models: [ModelSelectorModelRow], query: String) -> ModelSelectorListing {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ModelSelectorListing(rows: models, isFiltered: false)
        }
        let matches = models.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
        return ModelSelectorListing(rows: matches, isFiltered: true)
    }

    static func setupTitle(for providerName: String) -> String {
        "\(providerName) isn't set up"
    }

    static let setupDetail = "Install the CLI and sign in to use its models in ASTRA."
    static let setupAction = "Set up in Settings"
}

/// Builds model rows and resolves a picked row back to the exact model id the
/// runtime launches with. Antigravity lists base models (its `-low/-medium/
/// -high` SKUs are reasoning efforts, see `AntigravityCLIRuntime`), every other
/// runtime lists its model ids directly.
///
/// A class so one instance can memoize rows for the life of a popover render:
/// the rail counts every provider and Cursor alone lists ~250 models, each run
/// through `RuntimeModelMenuOptionPresentation`. Rebuilding them on every
/// search keystroke is what made the selector feel slow.
@MainActor
final class ModelSelectorCatalog {
    let cache: RuntimeModelAvailabilityCache
    let currentRuntime: AgentRuntimeID
    let currentModel: String

    private var rowsByRuntime: [AgentRuntimeID: [ModelSelectorModelRow]] = [:]
    private var memoizedAntigravityGroups: [AntigravityCLIRuntime.AntigravityModelGroup]?

    init(cache: RuntimeModelAvailabilityCache, currentRuntime: AgentRuntimeID, currentModel: String) {
        self.cache = cache
        self.currentRuntime = currentRuntime
        self.currentModel = currentModel
    }

    func rows(for runtime: AgentRuntimeID) -> [ModelSelectorModelRow] {
        if let memoized = rowsByRuntime[runtime] { return memoized }
        let rows = PerformanceTelemetry.measure(
            "model_selector_rows_build",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            level: .info,
            fields: ["runtime": runtime.rawValue],
            resultFields: { ["row_count": PerformanceTelemetryFields.count($0.count)] }
        ) {
            buildRows(for: runtime)
        }
        rowsByRuntime[runtime] = rows
        return rows
    }

    private func buildRows(for runtime: AgentRuntimeID) -> [ModelSelectorModelRow] {
        let isCurrent = runtime == currentRuntime
        if runtime == .antigravityCLI {
            let groups = antigravityGroups()
            let selectedBase = isCurrent
                ? AntigravityCLIRuntime.currentSelection(model: currentModel, groups: groups).baseID
                : nil
            return groups.map { group in
                ModelSelectorModelRow(
                    id: group.baseID,
                    title: group.baseDisplayName,
                    subtitle: nil,
                    help: "Model ID: \(group.baseID)",
                    isSelected: group.baseID == selectedBase
                )
            }
        }

        return modelIDs(for: runtime).map { id in
            let option = RuntimeModelMenuOptionPresentation(model: id, runtime: runtime, cache: cache)
            return ModelSelectorModelRow(
                id: id,
                title: option.title,
                subtitle: option.subtitle,
                help: option.detail,
                isSelected: isCurrent && id == currentModel
            )
        }
    }

    /// The ids a provider's list shows. A task can carry a model the provider
    /// no longer lists (typed by hand or left over from a cache refresh); it
    /// stays visible and selected.
    private func modelIDs(for runtime: AgentRuntimeID) -> [String] {
        let candidates = RuntimeModelAvailability.models(for: runtime, cache: cache)
        let trimmedCurrent = currentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtime == currentRuntime, !trimmedCurrent.isEmpty, !candidates.contains(trimmedCurrent) else {
            return candidates
        }
        return [trimmedCurrent] + candidates
    }

    /// The effort to keep after the model changes. `nil` ("let the provider
    /// decide") stays `nil`; a concrete effort the new model does not offer
    /// falls back to that model's own default, and a model with no effort knob
    /// drops it. Efforts differ per model, so a pick never carries over blindly.
    func resolvedReasoningEffort(
        _ current: String?,
        model: String,
        runtime: AgentRuntimeID
    ) -> String? {
        guard let current, !current.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return RuntimeModelAvailability.normalizedReasoningEffort(
            current,
            for: model,
            runtime: runtime,
            cache: cache
        )
    }

    /// Title of the model the current selection resolves to, for labelling
    /// controls (like reasoning) that apply to it.
    var selectedModelTitle: String? {
        rows(for: currentRuntime).first(where: \.isSelected)?.title
    }

    /// The rail's count, without building presentation rows for providers the
    /// user is not looking at.
    func modelCount(for runtime: AgentRuntimeID) -> Int {
        if let memoized = rowsByRuntime[runtime] { return memoized.count }
        if runtime == .antigravityCLI { return antigravityGroups().count }
        return modelIDs(for: runtime).count
    }

    /// The model id to launch with after the user picks `rowID` under `runtime`.
    func modelID(forRow rowID: String, runtime: AgentRuntimeID) -> String {
        guard runtime == .antigravityCLI else { return rowID }
        let groups = antigravityGroups()
        guard let group = groups.first(where: { $0.baseID == rowID }) else { return rowID }
        let selection = AntigravityCLIRuntime.currentSelection(model: currentModel, groups: groups)
        let keepsEffort = runtime == currentRuntime && selection.baseID == rowID
        return AntigravityCLIRuntime.fullModelID(
            base: rowID,
            effort: keepsEffort ? selection.effort : group.preferredDefaultEffort,
            groups: groups
        )
    }

    private func antigravityGroups() -> [AntigravityCLIRuntime.AntigravityModelGroup] {
        if let memoizedAntigravityGroups { return memoizedAntigravityGroups }
        let options = RuntimeModelAvailability.models(for: .antigravityCLI, cache: cache).map { id in
            AntigravityCLIRuntime.AntigravityModelOption(
                id: id,
                displayName: RuntimeModelAvailability.displayName(
                    for: id,
                    runtime: .antigravityCLI,
                    cache: cache
                )
            )
        }
        let groups = AntigravityCLIRuntime.groupModelOptions(options)
        memoizedAntigravityGroups = groups
        return groups
    }
}
