import SwiftUI
import ASTRACore

/// One reasoning-effort option for the currently selected model.
struct ModelSelectorReasoningChoice: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
}

struct ModelSelectorSuggestion {
    let title: String
    let action: () -> Void
}

/// Two-pane provider and model picker for the composer chip: providers on the
/// left, that provider's models on the right, reasoning effort in the foot.
/// Replaces three nested `Menu` levels (Provider > Model > Reasoning) that had
/// to be crossed with a diagonal cursor path.
struct ModelSelectorPopover<BudgetFooter: View>: View {
    let providers: [ModelSelectorProviderRow]
    let catalog: ModelSelectorCatalog
    let reasoningChoices: [ModelSelectorReasoningChoice]
    let suggestion: ModelSelectorSuggestion?
    let showsBudgetFooter: Bool
    let onSelect: (AgentRuntimeID, String) -> Void
    let onSetup: () -> Void
    /// Uptime (ns) of the chip click that opened this popover, for the
    /// `model_selector_open_to_ready` measurement.
    let openedAt: UInt64?
    @ViewBuilder let budgetFooter: () -> BudgetFooter

    @Environment(\.dismiss) private var dismiss
    @State private var browsing: AgentRuntimeID
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var pending: ModelSelectorPendingInteraction?

    init(
        providers: [ModelSelectorProviderRow],
        catalog: ModelSelectorCatalog,
        reasoningChoices: [ModelSelectorReasoningChoice],
        suggestion: ModelSelectorSuggestion?,
        showsBudgetFooter: Bool,
        onSelect: @escaping (AgentRuntimeID, String) -> Void,
        onSetup: @escaping () -> Void,
        openedAt: UInt64? = nil,
        @ViewBuilder budgetFooter: @escaping () -> BudgetFooter
    ) {
        self.providers = providers
        self.catalog = catalog
        self.reasoningChoices = reasoningChoices
        self.suggestion = suggestion
        self.showsBudgetFooter = showsBudgetFooter
        self.onSelect = onSelect
        self.onSetup = onSetup
        self.openedAt = openedAt
        self.budgetFooter = budgetFooter
        _browsing = State(initialValue: catalog.currentRuntime)
    }

    private static var width: CGFloat { 540 }
    private static var railWidth: CGFloat { 188 }

    var body: some View {
        PerformanceTelemetry.measure(
            ModelSelectorTelemetry.popoverBodyEvent,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            level: .info,
            fields: ["runtime": browsing.rawValue]
        ) {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let suggestion {
                suggestionBar(suggestion)
                Divider()
            }
            HStack(spacing: 0) {
                rail
                    .frame(width: Self.railWidth)
                    .background(Color.primary.opacity(0.03))
                Divider()
                detail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 312)
            // Always present, even for a model with no reasoning levels: the
            // popover keeps one shape instead of jumping as the selection moves.
            Divider()
            footer
        }
        .frame(width: Self.width)
        .onAppear {
            searchFocused = true
            logOpened()
        }
        .onChange(of: selectionSignature) { _, _ in resolvePending() }
    }

    // MARK: - Telemetry

    /// Changes whenever the parent applies a provider, model, or reasoning
    /// pick, which is the moment a pending interaction has visibly landed.
    private var selectionSignature: String {
        [
            catalog.currentRuntime.rawValue,
            catalog.currentModel,
            reasoningChoices.first(where: \.isSelected)?.id ?? "",
        ].joined(separator: "|")
    }

    private func logOpened() {
        guard let openedAt else { return }
        // Logged a turn later so the measurement covers the first layout,
        // not only the view being inserted.
        DispatchQueue.main.async {
            PerformanceTelemetry.log(
                ModelSelectorTelemetry.openEvent,
                durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: openedAt),
                level: .info,
                fields: [
                    "runtime": catalog.currentRuntime.rawValue,
                    "provider_count": PerformanceTelemetryFields.count(providers.count),
                    "model_count": PerformanceTelemetryFields.count(catalog.modelCount(for: catalog.currentRuntime)),
                ]
            )
        }
    }

    private func begin(_ event: String, target: String) {
        pending = ModelSelectorPendingInteraction(
            event: event,
            target: target,
            start: DispatchTime.now().uptimeNanoseconds
        )
    }

    private func resolvePending() {
        guard let pending else { return }
        let landed: Bool
        switch pending.event {
        case ModelSelectorTelemetry.modelPickEvent:
            landed = catalog.currentModel == pending.target
        default:
            landed = reasoningChoices.first(where: \.isSelected)?.id == pending.target
        }
        guard landed else { return }
        self.pending = nil
        PerformanceTelemetry.log(
            pending.event,
            durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: pending.start),
            level: .info,
            fields: [
                "runtime": catalog.currentRuntime.rawValue,
                "model_count": PerformanceTelemetryFields.count(catalog.modelCount(for: catalog.currentRuntime)),
                "reasoning_choice_count": PerformanceTelemetryFields.count(reasoningChoices.count),
            ]
        )
    }

    // MARK: - Rail

    private var rail: some View {
        let groups = ModelSelectorPresentation.railGroups(providers)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                railGroup(title: "Providers", rows: groups.providers)
                if !groups.needsSetup.isEmpty {
                    railGroup(title: "Needs setup", rows: groups.needsSetup)
                        .padding(.top, 6)
                }
            }
            .padding(6)
        }
    }

    private func railGroup(title: String, rows: [ModelSelectorProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Stanford.caption(11).weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ForEach(rows) { row in
                providerRow(row)
            }
        }
    }

    private func providerRow(_ row: ModelSelectorProviderRow) -> some View {
        let isBrowsing = row.runtime == browsing
        return SelectorHoverRow(
            isHighlighted: isBrowsing,
            highlight: Color.primary.opacity(0.08),
            action: {
                // Browsing only: looking at another provider's models never
                // changes the selection. A model pick is the only thing that does.
                let start = DispatchTime.now().uptimeNanoseconds
                browsing = row.runtime
                query = ""
                DispatchQueue.main.async {
                    PerformanceTelemetry.log(
                        ModelSelectorTelemetry.browseEvent,
                        durationMilliseconds: PerformanceTelemetry.elapsedMilliseconds(since: start),
                        level: .info,
                        fields: [
                            "runtime": row.runtime.rawValue,
                            "model_count": PerformanceTelemetryFields.count(row.modelCount),
                        ]
                    )
                }
            }
        ) {
            HStack(spacing: 8) {
                ModelSelectorProviderIcon(runtime: row.runtime)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(row.availability == .needsSetup ? .tertiary : .secondary)
                Text(row.title)
                    .font(Stanford.ui(13))
                    .foregroundStyle(row.availability == .needsSetup ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if row.isCurrent {
                    Circle()
                        .fill(Stanford.paloAltoGreen)
                        .frame(width: 7, height: 7)
                        .help("Current provider")
                } else if row.availability != .needsSetup, row.modelCount > 0 {
                    Text("\(row.modelCount)")
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityLabel(row.title)
        // Selected means the persisted selection, not the row being browsed;
        // the value carries state the green dot and grouping show visually.
        .accessibilityValue(ModelSelectorPresentation.providerAccessibilityValue(row, isBrowsing: isBrowsing))
        .accessibilityHint("Shows this provider's models")
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let provider = providers.first(where: { $0.runtime == browsing }) {
            switch provider.availability {
            case .ready:
                modelList(for: provider)
            case .needsSetup:
                setupPane(for: provider)
            case .unavailable(let reason):
                messagePane(icon: "exclamationmark.circle", title: provider.title, message: reason)
            }
        }
    }

    private func modelList(for provider: ModelSelectorProviderRow) -> some View {
        let models = catalog.rows(for: provider.runtime)
        let listing = PerformanceTelemetry.measure(
            ModelSelectorTelemetry.searchEvent,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            level: .info,
            fields: [
                "runtime": provider.runtime.rawValue,
                "model_count": PerformanceTelemetryFields.count(models.count),
            ]
        ) {
            ModelSelectorPresentation.listing(models: models, query: query)
        }
        return VStack(alignment: .leading, spacing: 0) {
            searchField(placeholder: "Search \(provider.title)")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if listing.rows.isEmpty {
                            Text("No models match \"\(query)\".")
                                .font(Stanford.caption(12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 14)
                        }
                        ForEach(listing.rows) { row in
                            modelRow(row, runtime: provider.runtime)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                // A long catalog opens on the current model, not at the top.
                .onAppear {
                    if let selected = listing.rows.first(where: \.isSelected) {
                        proxy.scrollTo(selected.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func searchField(placeholder: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Stanford.ui(11))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(Stanford.ui(13))
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Stanford.ui(12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .stroke(Stanford.borderRest, lineWidth: 1)
        )
        .padding(8)
    }

    private func modelRow(_ row: ModelSelectorModelRow, runtime: AgentRuntimeID) -> some View {
        SelectorHoverRow(
            isHighlighted: row.isSelected,
            highlight: Stanford.lagunita.opacity(0.10),
            action: {
                // Stays open: reasoning levels are per model, so the footer
                // refreshes for the new pick and is the natural next step.
                let modelID = catalog.modelID(forRow: row.id, runtime: runtime)
                if modelID != catalog.currentModel || runtime != catalog.currentRuntime {
                    begin(ModelSelectorTelemetry.modelPickEvent, target: modelID)
                }
                onSelect(runtime, modelID)
            }
        ) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(Stanford.ui(13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(Stanford.caption(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(Stanford.ui(12, weight: .semibold))
                        .foregroundStyle(Stanford.lagunita)
                }
            }
        }
        .help(row.help ?? row.title)
        .accessibilityLabel(row.title)
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    }

    private func setupPane(for provider: ModelSelectorProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(Stanford.ui(16))
                .foregroundStyle(Stanford.poppy)
                .frame(width: 34, height: 34)
                .background(Stanford.poppy.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(ModelSelectorPresentation.setupTitle(for: provider.title))
                .font(Stanford.ui(14, weight: .semibold))
            Text(ModelSelectorPresentation.setupDetail)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onSetup()
                dismiss()
            } label: {
                Text(ModelSelectorPresentation.setupAction)
                    .font(Stanford.ui(13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(Stanford.lagunita, in: RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Settings where provider setup can be completed")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func messagePane(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.ui(16))
                .foregroundStyle(.secondary)
            Text(title)
                .font(Stanford.ui(14, weight: .semibold))
            Text(message)
                .font(Stanford.caption(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Suggestion and footer

    private func suggestionBar(_ suggestion: ModelSelectorSuggestion) -> some View {
        Button {
            suggestion.action()
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(Stanford.ui(11))
                Text(suggestion.title)
                    .font(Stanford.ui(12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Stanford.lagunita)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Reasoning")
                    .font(Stanford.caption(12))
                    .foregroundStyle(reasoningChoices.isEmpty ? .tertiary : .secondary)
                if !reasoningChoices.isEmpty {
                    reasoningControl
                }
                Spacer(minLength: 8)
                if let title = selectedModelLabel {
                    Text(title)
                        .font(Stanford.caption(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            // Same height with or without levels, so the popover never jumps.
            .frame(height: 28)
            .help(reasoningChoices.isEmpty
                ? "The selected model has no reasoning levels"
                : "Reasoning levels for the selected model")
            if showsBudgetFooter {
                HStack(spacing: 14) {
                    budgetFooter()
                }
                .font(Stanford.caption(12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the reasoning row applies to. It always follows the selection,
    /// so while another provider is being browsed it names the selection's
    /// provider too.
    private var selectedModelLabel: String? {
        guard let model = catalog.selectedModelTitle else { return nil }
        guard browsing != catalog.currentRuntime,
              let provider = providers.first(where: \.isCurrent) else { return model }
        return "\(provider.title) · \(model)"
    }

    private var reasoningControl: some View {
        HStack(spacing: 2) {
            ForEach(reasoningChoices) { choice in
                Button {
                    if !choice.isSelected {
                        begin(ModelSelectorTelemetry.reasoningPickEvent, target: choice.id)
                    }
                    choice.select()
                } label: {
                    Text(choice.title)
                        .font(Stanford.ui(12, weight: choice.isSelected ? .medium : .regular))
                        .foregroundStyle(choice.isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Stanford.radiusSmall, style: .continuous)
                                .fill(choice.isSelected ? Color.primary.opacity(0.10) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Event names for the selector's latency lines (category `Performance`).
/// The `model_selector_` prefix is what `UIResponsivenessDiagnostics` keys on.
enum ModelSelectorTelemetry {
    static let openEvent = "model_selector_open_to_ready"
    /// Clicking a provider in the rail to look at its models.
    static let browseEvent = "model_selector_browse_to_ready"
    static let modelPickEvent = "model_selector_model_pick_to_ready"
    static let reasoningPickEvent = "model_selector_reasoning_pick_to_ready"
    static let searchEvent = "model_selector_search"
    /// Building the popover's view description (rows included).
    static let popoverBodyEvent = "model_selector_popover_body"
    /// Building the composer toolbar that hosts the chip.
    static let toolbarBodyEvent = "model_selector_toolbar_body"
}

private struct ModelSelectorPendingInteraction: Equatable {
    let event: String
    let target: String
    let start: UInt64
}

/// Plain row with a hover wash; selection and hover share one highlight shape.
private struct SelectorHoverRow<Content: View>: View {
    let isHighlighted: Bool
    let highlight: Color
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Stanford.radiusMedium, style: .continuous)
                        .fill(isHighlighted ? highlight : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Real brand mark where ASTRA ships one, SF Symbol otherwise. Shared by the
/// selector rail and the composer chip, so the chip names its provider too.
struct ModelSelectorProviderIcon: View {
    let runtime: AgentRuntimeID
    var pointSize: CGFloat = 15

    var body: some View {
        switch runtime {
        case .claudeCode: mark(.claude, fallback: "sparkle")
        case .copilotCLI: mark(.copilot, fallback: "airplane")
        case .antigravityCLI: mark(.gemini, fallback: "sparkle")
        case .codexCLI: mark(.openai, fallback: "terminal")
        case .cursorCLI: mark(nil, fallback: "cursorarrow.rays")
        case .openCodeCLI: mark(nil, fallback: "curlybraces")
        default: mark(nil, fallback: "server.rack")
        }
    }

    private func mark(_ brand: BrandMark?, fallback: String) -> some View {
        CapabilityLeadingIcon(systemImage: fallback, brand: brand, pointSize: pointSize)
    }
}
