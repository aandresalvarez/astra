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
    /// The user's own label that this runtime is approved for PHI and other
    /// sensitive data (Settings > Runtime). ASTRA does not verify it.
    var approvesSensitiveData = false

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
    /// Ready providers the user marked approved for PHI and sensitive data.
    var approved: [ModelSelectorProviderRow]
    var providers: [ModelSelectorProviderRow]
    var needsSetup: [ModelSelectorProviderRow]

    /// "Providers" alone would read as "all of them" under an approved group.
    var providersTitle: String {
        approved.isEmpty ? "Providers" : "Other providers"
    }
}

enum ModelSelectorPresentation {
    /// Shared status lives in the group, not on each row: providers that still
    /// need setup move to their own group instead of carrying a per-row pill,
    /// and approved providers lead under a header that says what approval
    /// means, which a bare icon could not. Setup outranks approval: a
    /// provider that cannot run belongs with the others that cannot.
    static func railGroups(_ rows: [ModelSelectorProviderRow]) -> ModelSelectorRailGroups {
        let usable = rows.filter { $0.availability != .needsSetup }
        return ModelSelectorRailGroups(
            approved: usable.filter(\.approvesSensitiveData),
            providers: usable.filter { !$0.approvesSensitiveData },
            needsSetup: rows.filter { $0.availability == .needsSetup }
        )
    }

    static let approvedGroupTitle = "Approved for sensitive data"

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

    /// What VoiceOver says after a provider's name: whether it is the actual
    /// selection, its availability, and whether its models are on screen.
    static func providerAccessibilityValue(
        _ row: ModelSelectorProviderRow,
        isBrowsing: Bool
    ) -> String {
        var parts: [String] = []
        if row.isCurrent { parts.append("Selected provider") }
        switch row.availability {
        case .ready:
            parts.append(row.modelCount == 1 ? "1 model" : "\(row.modelCount) models")
        case .needsSetup:
            parts.append("Needs setup")
        case .unavailable(let reason):
            parts.append(reason)
        }
        // Only the exception is announced; "not approved" is the default.
        if row.approvesSensitiveData { parts.append(sensitiveDataStatus(approved: true)) }
        if isBrowsing { parts.append("Showing its models") }
        return parts.joined(separator: ", ")
    }

    static func sensitiveDataStatus(approved: Bool) -> String {
        approved ? "Approved for PHI and sensitive data" : "Not approved for PHI or sensitive data"
    }

    /// The footer's short line for the selected provider. Approval is the
    /// user's label, never an ASTRA verdict.
    static func sensitiveDataFooterLabel(approved: Bool) -> String {
        approved ? "Approved for PHI" : "Not approved for PHI"
    }

    static let sensitiveDataChangeAction = "Change"
    static let sensitiveDataApprovedHelp = "You marked this provider as approved for PHI and sensitive data in Settings > Runtime. ASTRA does not verify it."
    static let sensitiveDataNotApprovedHelp = "Not approved for PHI or sensitive data. Mark it approved in Settings > Runtime once your organization allows it."

    static let compatibilityPendingReason = "Checking compatibility with this request…"

    /// Why a ready provider cannot be picked for the current request, once a
    /// compatibility snapshot exists. The selected runtime is scored first and
    /// the others later, so a provider missing from the snapshot is *unscored*,
    /// not compatible: it stays unpickable until its verdict arrives, matching
    /// the old menu, which required an eligible candidate.
    static func compatibilityBlockReason(
        isScored: Bool,
        isEligible: Bool,
        blockingReason: String?
    ) -> String? {
        guard isScored else { return compatibilityPendingReason }
        guard !isEligible else { return nil }
        return blockingReason ?? "Not compatible with this request."
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

/// Keeps one `ModelSelectorCatalog` alive across composer re-renders.
///
/// A provider switch re-renders the composer several times (runtime, then
/// model, then effort), and a fresh catalog each time threw its memoized rows
/// away: `model_selector_rows_build` logged Cursor's 246 rows being built twice
/// per switch. The catalog is reused while its inputs are unchanged.
/// Deliberately not observable — handing out a cached value must not
/// invalidate the view that asked for it.
@MainActor
final class ModelSelectorCatalogStore {
    private var current: ModelSelectorCatalog?

    func catalog(
        cache: RuntimeModelAvailabilityCache,
        currentRuntime: AgentRuntimeID,
        currentModel: String
    ) -> ModelSelectorCatalog {
        if let current,
           current.currentRuntime == currentRuntime,
           current.currentModel == currentModel,
           current.cache == cache {
            return current
        }
        let fresh = ModelSelectorCatalog(
            cache: cache,
            currentRuntime: currentRuntime,
            currentModel: currentModel
        )
        current = fresh
        return fresh
    }
}
