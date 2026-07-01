import Foundation
import ASTRACore

struct WorkspacePackSettingsPresentation: Equatable {
    var rows: [Row]
    var diagnostics: [Diagnostic]
    var enabledCount: Int
    var availableCount: Int

    static func make(
        snapshot: AstraPackCatalogSnapshot,
        enabledPackIDs: [String]
    ) -> WorkspacePackSettingsPresentation {
        let enabledIDs = Set(WorkspacePackSelectionPolicy.normalized(enabledPackIDs))
        let catalogRows = snapshot.entries.map { entry in
            Row(entry: entry, isEnabled: enabledIDs.contains(entry.manifest.id))
        }
        let catalogIDs = Set(snapshot.entries.map(\.manifest.id))
        let missingRows = enabledIDs
            .subtracting(catalogIDs)
            .sorted()
            .map(Row.missing(id:))
        let rows = (catalogRows + missingRows).sorted(by: rowOrder)

        return WorkspacePackSettingsPresentation(
            rows: rows,
            diagnostics: snapshot.diagnostics.map(Diagnostic.init(diagnostic:)),
            enabledCount: rows.filter(\.isEnabled).count,
            availableCount: rows.count
        )
    }

    private static func rowOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }
}

extension WorkspacePackSettingsPresentation {
    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        var sourceLabel: String
        var versionLabel: String
        var description: String
        var iconSystemName: String
        var isEnabled: Bool
        var shelfSummary: String
        var templateSummary: String
        var capabilitySummary: String
        var policySummary: String

        init(entry: AstraPackCatalogEntry, isEnabled: Bool) {
            let manifest = entry.manifest
            self.id = manifest.id
            self.name = manifest.name
            self.sourceLabel = Self.sourceLabel(entry.source.kind)
            self.versionLabel = "v\(manifest.version)"
            self.description = manifest.description
            self.iconSystemName = manifest.branding?.iconSystemName ?? "shippingbox"
            self.isEnabled = isEnabled
            self.shelfSummary = Self.shelfSummary(manifest.shelfDefaults)
            self.templateSummary = Self.templateSummary(manifest.appTemplates)
            self.capabilitySummary = Self.capabilitySummary(manifest)
            self.policySummary = Self.policySummary(manifest.policyRestrictions)
        }

        static func missing(id: String) -> Row {
            Row(
                id: id,
                name: id,
                sourceLabel: "Missing",
                versionLabel: "",
                description: "This pack is enabled in the workspace but was not found in the catalog.",
                iconSystemName: "exclamationmark.triangle",
                isEnabled: true,
                shelfSummary: "None",
                templateSummary: "None",
                capabilitySummary: "None",
                policySummary: "No restrictions"
            )
        }

        private init(
            id: String,
            name: String,
            sourceLabel: String,
            versionLabel: String,
            description: String,
            iconSystemName: String,
            isEnabled: Bool,
            shelfSummary: String,
            templateSummary: String,
            capabilitySummary: String,
            policySummary: String
        ) {
            self.id = id
            self.name = name
            self.sourceLabel = sourceLabel
            self.versionLabel = versionLabel
            self.description = description
            self.iconSystemName = iconSystemName
            self.isEnabled = isEnabled
            self.shelfSummary = shelfSummary
            self.templateSummary = templateSummary
            self.capabilitySummary = capabilitySummary
            self.policySummary = policySummary
        }

        private static func sourceLabel(_ kind: AstraPackSource.Kind) -> String {
            switch kind {
            case .builtIn:
                return "Built-in"
            case .local:
                return "Local"
            }
        }

        private static func shelfSummary(_ shelves: [AstraPackShelfDefault]) -> String {
            joined(
                shelves.map { shelf in
                    CoreShelfRegistry.descriptor(forStableID: shelf.id)?.title ?? shelf.title
                }
            )
        }

        private static func templateSummary(_ templates: [AstraPackAppTemplate]) -> String {
            joined(templates.map(\.name))
        }

        private static func capabilitySummary(_ manifest: AstraPackManifest) -> String {
            let capabilityIDs = manifest.capabilityPackageIDs
                + manifest.shelfDefaults.flatMap(\.capabilityPackageIDs)
                + manifest.appTemplates.flatMap(\.capabilityPackageIDs)
            return joined(capabilityIDs)
        }

        private static func policySummary(_ restrictions: [AstraPackPolicyRestriction]) -> String {
            guard !restrictions.isEmpty else { return "No restrictions" }
            return restrictions.count == 1 ? "1 restriction" : "\(restrictions.count) restrictions"
        }

        private static func joined(_ values: [String]) -> String {
            var seen = Set<String>()
            let normalized = values.compactMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
                seen.insert(trimmed)
                return trimmed
            }
            return normalized.isEmpty ? "None" : normalized.joined(separator: ", ")
        }
    }

    struct Diagnostic: Equatable, Identifiable {
        var id: String
        var title: String
        var detail: String

        init(diagnostic: AstraPackCatalogDiagnostic) {
            let sourceKind = diagnostic.source.kind.rawValue
            id = "\(sourceKind)-\(diagnostic.message)"
            title = diagnostic.source.kind == .local ? "Local pack issue" : "Built-in pack issue"
            detail = diagnostic.message
        }
    }
}

enum WorkspacePackSelectionPolicy {
    static func enabledPackIDs(
        current: [String],
        setting packID: String,
        isEnabled: Bool
    ) -> [String] {
        var ids = Set(normalized(current))
        let normalizedPackID = packID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPackID.isEmpty else {
            return ids.sorted()
        }

        if isEnabled {
            ids.insert(normalizedPackID)
        } else {
            ids.remove(normalizedPackID)
        }
        return ids.sorted()
    }

    static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })).sorted()
    }
}
