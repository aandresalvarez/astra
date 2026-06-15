import Foundation
import ASTRACore

struct RuntimeModelMenuOptionPresentation: Equatable, Sendable {
    var title: String
    var subtitle: String?
    var detail: String?
    var compactTitle: String

    init(
        model: String,
        runtime: AgentRuntimeID,
        cache: RuntimeModelAvailabilityCache
    ) {
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = RuntimeModelAvailability.displayName(for: modelID, runtime: runtime, cache: cache)
        let description = RuntimeModelAvailability.modelDescription(for: modelID, runtime: runtime, cache: cache)
        let idDisplayName = RuntimeModelDisplayName.displayName(modelID)
        let familyVersion = description.flatMap(RuntimeModelDisplayName.familyVersionLabel(in:))
            ?? RuntimeModelDisplayName.familyVersionLabel(in: displayName)
        let alias = Self.aliasKind(modelID: modelID, displayName: displayName)

        title = Self.title(
            modelID: modelID,
            displayName: displayName,
            idDisplayName: idDisplayName,
            familyVersion: familyVersion,
            alias: alias
        )
        subtitle = Self.subtitle(description: description, familyVersion: familyVersion)
        detail = modelID.isEmpty ? nil : "Model ID: \(modelID)"
        compactTitle = Self.compactTitle(title: title, familyVersion: familyVersion, alias: alias)
    }

    private static func title(
        modelID: String,
        displayName: String,
        idDisplayName: String,
        familyVersion: String?,
        alias: AliasKind
    ) -> String {
        switch alias {
        case .defaultAlias:
            if let familyVersion {
                return "\(displayName) - \(familyVersion)"
            }
            return displayName
        case .familyAlias:
            if let familyVersion {
                if let suffix = parentheticalSuffix(in: displayName) {
                    return "\(familyVersion) \(suffix)"
                }
                return familyVersion
            }
            return displayName
        case .none:
            if displayName != modelID {
                return displayName
            }
            return idDisplayName
        }
    }

    private static func subtitle(description: String?, familyVersion: String?) -> String? {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let familyVersion,
              trimmed.localizedCaseInsensitiveCompare(familyVersion) != .orderedSame,
              trimmed.localizedCaseInsensitiveContains(familyVersion),
              trimmed.lowercased().hasPrefix(familyVersion.lowercased()) else {
            return trimmed
        }

        var remainder = String(trimmed.dropFirst(familyVersion.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = remainder.first, ["·", "-", ":", "–"].contains(first) {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder.isEmpty ? nil : remainder
    }

    private static func compactTitle(
        title: String,
        familyVersion: String?,
        alias: AliasKind
    ) -> String {
        if alias == .defaultAlias, let familyVersion {
            return familyVersion
        }
        return title.replacingOccurrences(
            of: #"\s*\([^)]*\)$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func parentheticalSuffix(in value: String) -> String? {
        guard let range = value.range(
            of: #"\([^)]*\)"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(value[range])
    }

    private static func aliasKind(modelID: String, displayName: String) -> AliasKind {
        let normalizedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedModel == "default" {
            return .defaultAlias
        }
        let familyAliases: Set<String> = ["opus", "sonnet", "haiku", "fable", "mythos"]
        if familyAliases.contains(normalizedModel) {
            return .familyAlias
        }
        let normalizedDisplay = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if familyAliases.contains(normalizedDisplay) {
            return .familyAlias
        }
        return .none
    }

    private enum AliasKind: Equatable {
        case defaultAlias
        case familyAlias
        case none
    }
}
