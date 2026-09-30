import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@MainActor
@Suite("Model Selector Presentation")
struct ModelSelectorPresentationTests {
    private func row(
        _ id: String,
        selected: Bool = false,
        subtitle: String? = nil
    ) -> ModelSelectorModelRow {
        ModelSelectorModelRow(
            id: id,
            title: id.capitalized,
            subtitle: subtitle,
            help: nil,
            isSelected: selected
        )
    }

    private func provider(
        _ runtime: AgentRuntimeID,
        _ availability: ModelSelectorProviderAvailability,
        current: Bool = false
    ) -> ModelSelectorProviderRow {
        ModelSelectorProviderRow(
            runtime: runtime,
            title: runtime.displayName,
            availability: availability,
            modelCount: 3,
            isCurrent: current
        )
    }

    // MARK: - Rail

    @Test("providers that need setup move to their own group instead of repeating a pill")
    func railSeparatesNeedsSetup() {
        let rows = [
            provider(.claudeCode, .ready, current: true),
            provider(.openCodeCLI, .needsSetup),
            provider(.codexCLI, .unavailable(reason: "No network")),
        ]
        let groups = ModelSelectorPresentation.railGroups(rows)

        #expect(groups.providers.map(\.runtime) == [.claudeCode, .codexCLI])
        #expect(groups.needsSetup.map(\.runtime) == [.openCodeCLI])
    }

    @Test("availability resolves setup before request compatibility")
    func availabilityOrdering() {
        #expect(ModelSelectorProviderAvailability.resolve(
            readinessKnown: false, allowsLaunch: false, blockedReason: nil
        ) == .unavailable(reason: "Checking provider setup…"))
        #expect(ModelSelectorProviderAvailability.resolve(
            readinessKnown: true, allowsLaunch: false, blockedReason: "Not compatible"
        ) == .needsSetup)
        #expect(ModelSelectorProviderAvailability.resolve(
            readinessKnown: true, allowsLaunch: true, blockedReason: "Not compatible"
        ) == .unavailable(reason: "Not compatible"))
        #expect(ModelSelectorProviderAvailability.resolve(
            readinessKnown: true, allowsLaunch: true, blockedReason: nil
        ) == .ready)
    }

    // MARK: - Listing

    @Test("the whole catalog is listed in catalog order, however long, with no disclosure")
    func everyModelIsListed() {
        for count in [1, 4, 5, 6, 11, 40] {
            var models = (1...count).map { row("m\($0)") }
            models[count - 1] = row("m\(count)", selected: true)
            let listing = ModelSelectorPresentation.listing(models: models, query: "")

            #expect(listing.rows == models, "count \(count) dropped models")
            #expect(!listing.isFiltered)
        }
    }

    @Test("search matches titles, descriptions and exact ids across the whole catalog")
    func searchSpansTheWholeCatalog() {
        let models = [
            row("alpha"),
            row("beta", subtitle: "Fast and cheap"),
            row("gamma"),
            row("delta"),
            row("epsilon"),
            row("zeta"),
        ]

        #expect(ModelSelectorPresentation.listing(models: models, query: "  ZET ").rows.map(\.id) == ["zeta"])
        #expect(ModelSelectorPresentation.listing(models: models, query: "cheap").rows.map(\.id) == ["beta"])
        let none = ModelSelectorPresentation.listing(models: models, query: "nope")
        #expect(none.rows.isEmpty)
        #expect(none.isFiltered)
    }

    // MARK: - Catalog

    private func antigravityCache() -> RuntimeModelAvailabilityCache {
        RuntimeModelAvailabilityCache(rawSnapshots: [
            .antigravityCLI: """
            {"runtimeID":"antigravity_cli","models":["gemini-3.8-flash-low","gemini-3.8-flash-high","gemini-3.8-pro-medium"],"checkedAt":0,"authority":"authoritative","details":[{"value":"gemini-3.8-flash-low","displayName":"Gemini 3.8 Flash (Low)"},{"value":"gemini-3.8-flash-high","displayName":"Gemini 3.8 Flash (High)"},{"value":"gemini-3.8-pro-medium","displayName":"Gemini 3.8 Pro (Medium)"}]}
            """
        ])
    }

    @Test("Antigravity lists base models, not one row per reasoning SKU")
    func antigravityRowsAreBaseModels() {
        let catalog = ModelSelectorCatalog(
            cache: antigravityCache(),
            currentRuntime: .antigravityCLI,
            currentModel: "gemini-3.8-flash-high"
        )
        let rows = catalog.rows(for: .antigravityCLI)

        #expect(rows.map(\.title) == ["Gemini 3.8 Flash", "Gemini 3.8 Pro"])
        #expect(rows.filter(\.isSelected).map(\.title) == ["Gemini 3.8 Flash"])
    }

    @Test("picking the same Antigravity base keeps its effort, another base uses its preferred one")
    func antigravityKeepsEffortOnlyForTheSameBase() {
        let catalog = ModelSelectorCatalog(
            cache: antigravityCache(),
            currentRuntime: .antigravityCLI,
            currentModel: "gemini-3.8-flash-high"
        )

        #expect(catalog.modelID(forRow: "gemini-3.8-flash", runtime: .antigravityCLI) == "gemini-3.8-flash-high")
        #expect(catalog.modelID(forRow: "gemini-3.8-pro", runtime: .antigravityCLI) == "gemini-3.8-pro-medium")
    }

    @Test("a model picked under another provider is passed through and never marked selected")
    func otherProviderRowsAreNotSelected() {
        let catalog = ModelSelectorCatalog(
            cache: antigravityCache(),
            currentRuntime: .antigravityCLI,
            currentModel: "gemini-3.8-flash-high"
        )
        let claudeRows = catalog.rows(for: .claudeCode)

        #expect(!claudeRows.isEmpty)
        #expect(claudeRows.allSatisfy { !$0.isSelected })
        #expect(catalog.modelID(forRow: "sonnet", runtime: .claudeCode) == "sonnet")
    }

    @Test("a current model the provider no longer lists stays visible and selected")
    func unlistedCurrentModelStaysVisible() {
        let catalog = ModelSelectorCatalog(
            cache: RuntimeModelAvailabilityCache(rawSnapshots: [:]),
            currentRuntime: .claudeCode,
            currentModel: "my-hand-typed-model"
        )
        let rows = catalog.rows(for: .claudeCode)

        #expect(rows.first?.id == "my-hand-typed-model")
        #expect(rows.first?.isSelected == true)
    }

    // MARK: - Reasoning per model

    private func codexCache() -> RuntimeModelAvailabilityCache {
        RuntimeModelAvailabilityCache(rawSnapshots: [
            .codexCLI: """
            {"runtimeID":"codex_cli","models":["wide","narrow","plain"],"checkedAt":0,"authority":"authoritative","details":[{"value":"wide","displayName":"Wide","supportedReasoningEfforts":["low","medium","high","xhigh"],"defaultReasoningEffort":"medium"},{"value":"narrow","displayName":"Narrow","supportedReasoningEfforts":["low","medium"],"defaultReasoningEffort":"low"},{"value":"plain","displayName":"Plain"}]}
            """
        ])
    }

    private func codexCatalog(model: String = "wide") -> ModelSelectorCatalog {
        ModelSelectorCatalog(cache: codexCache(), currentRuntime: .codexCLI, currentModel: model)
    }

    @Test("an effort the new model offers carries over untouched")
    func supportedEffortCarriesOver() {
        #expect(codexCatalog().resolvedReasoningEffort("low", model: "narrow", runtime: .codexCLI) == "low")
        #expect(codexCatalog().resolvedReasoningEffort("medium", model: "wide", runtime: .codexCLI) == "medium")
    }

    @Test("an effort the new model lacks falls back to that model's own default")
    func unsupportedEffortFallsBackToTheModelDefault() {
        #expect(codexCatalog().resolvedReasoningEffort("xhigh", model: "narrow", runtime: .codexCLI) == "low")
    }

    @Test("a model with no effort knob drops the carried-over effort")
    func modelWithoutEffortsDropsTheValue() {
        #expect(codexCatalog().resolvedReasoningEffort("high", model: "plain", runtime: .codexCLI) == nil)
    }

    @Test("letting the provider decide stays that way across a model change")
    func providerDefaultSurvivesAModelChange() {
        #expect(codexCatalog().resolvedReasoningEffort(nil, model: "narrow", runtime: .codexCLI) == nil)
        #expect(codexCatalog().resolvedReasoningEffort("", model: "narrow", runtime: .codexCLI) == nil)
    }

    @Test("the footer is labelled with the model it applies to")
    func selectedModelTitleNamesTheCurrentModel() {
        #expect(codexCatalog(model: "narrow").selectedModelTitle == "Narrow")
    }

    // MARK: - Speed

    @Test("the rail counts providers without building their rows, and agrees with them")
    func railCountsMatchRows() {
        let catalog = ModelSelectorCatalog(
            cache: antigravityCache(),
            currentRuntime: .antigravityCLI,
            currentModel: "gemini-3.8-flash-high"
        )
        for runtime in [AgentRuntimeID.antigravityCLI, .claudeCode, .codexCLI] {
            let counted = catalog.modelCount(for: runtime)
            #expect(counted == catalog.rows(for: runtime).count, "\(runtime.rawValue) count drifted from its rows")
        }
    }

    @Test("selector latency lines land in the responsiveness report")
    func selectorLatencyIsReported() {
        let entries = [
            LogEntry(level: .info, category: "Performance", message: "event=\(ModelSelectorTelemetry.openEvent) duration_ms=180.00 runtime=cursor_cli"),
            LogEntry(level: .info, category: "Performance", message: "event=\(ModelSelectorTelemetry.providerSwitchEvent) duration_ms=95.00 runtime=codex_cli"),
            LogEntry(level: .info, category: "Performance", message: "event=\(ModelSelectorTelemetry.modelPickEvent) duration_ms=40.00 runtime=codex_cli"),
            LogEntry(level: .info, category: "Performance", message: "event=\(ModelSelectorTelemetry.reasoningPickEvent) duration_ms=12.00 runtime=codex_cli"),
            LogEntry(level: .info, category: "Performance", message: "event=\(ModelSelectorTelemetry.searchEvent) duration_ms=9.00 runtime=cursor_cli"),
            LogEntry(level: .info, category: "Performance", message: "event=model_selector_rows_build duration_ms=60.00 runtime=cursor_cli row_count=246"),
        ]
        let events = Set(UIResponsivenessDiagnostics.makeReport(entries: entries).eventSummaries.map(\.event))

        #expect(events == [
            ModelSelectorTelemetry.openEvent,
            ModelSelectorTelemetry.providerSwitchEvent,
            ModelSelectorTelemetry.modelPickEvent,
            ModelSelectorTelemetry.reasoningPickEvent,
            ModelSelectorTelemetry.searchEvent,
            "model_selector_rows_build",
        ])
    }

    // MARK: - Wiring

    @Test("the composer chip opens the two-pane selector instead of nested menus")
    func composerUsesTheSelectorPopover() throws {
        let toolbar = try sourceFile("Astra/Views/Components/ComposerToolbar.swift")
        let popover = try sourceFile("Astra/Views/Components/ModelSelectorPopover.swift")

        #expect(toolbar.contains("ModelSelectorPopover("))
        #expect(!toolbar.contains("Label(\"Provider\", systemImage:"))
        #expect(!toolbar.contains("Label(\"Model\", systemImage:"))
        // Nested Menu submenus are exactly what made the old selector hard to
        // use; the popover itself must not reintroduce them.
        #expect(!popover.contains("Menu {"))
        // Every model is listed; a disclosure hid the one users were looking for.
        #expect(!popover.contains("Show all"))
        // Reasoning levels are per model: every way of changing provider or
        // model has to re-resolve the effort, on both composers.
        #expect(toolbar.contains("alignReasoningEffort(model: modelID, runtime: runtime)"))
        #expect(toolbar.contains("alignReasoningEffort(model: switchedModel, runtime: runtime)"))
        // The chip is a control that names its provider: brand mark, accent tint.
        #expect(toolbar.contains("ModelSelectorProviderIcon("))
        #expect(!toolbar.contains("return Stanford.coolGrey\n    }\n\n    private var runtimePillBackground"))
        // The reasoning footer is always laid out so the popover keeps one shape.
        #expect(!popover.contains("if !reasoningChoices.isEmpty || showsBudgetFooter"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
