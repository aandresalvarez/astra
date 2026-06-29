import Foundation
import ASTRACore

struct AstraPackCompositionInput: Equatable, Sendable {
    var manifest: AstraPackManifest
    var sourceKind: AstraPackSource.Kind?
    var sourcePath: String?

    init(
        manifest: AstraPackManifest,
        sourceKind: AstraPackSource.Kind? = nil,
        sourcePath: String? = nil
    ) {
        self.manifest = manifest
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
    }

    init(entry: AstraPackCatalogEntry) {
        self.init(
            manifest: entry.manifest,
            sourceKind: entry.source.kind,
            sourcePath: entry.source.manifestURL?.path
        )
    }
}

struct AstraPackCompositionDiagnostic: Equatable, Sendable {
    enum ConflictKind: String, Equatable, Sendable {
        case shelfDefault = "shelf_default"
        case vocabulary
    }

    var packIDs: [String]
    var conflictKind: ConflictKind
    var key: String
    var winningPackID: String
    var losingPackIDs: [String]
    var message: String
}

struct AstraPackCompositionResult: Equatable, Sendable {
    var orderedInputs: [AstraPackCompositionInput]
    var shelfDefaults: [AstraPackShelfDefault]
    var capabilityPackageIDsByShelfID: [String: [String]]
    var vocabulary: [String: String]
    var policyRestrictions: [AstraPackPolicyRestriction]
    var diagnostics: [AstraPackCompositionDiagnostic]

    var orderedPacks: [AstraPackManifest] {
        orderedInputs.map(\.manifest)
    }

    var orderedPackIDs: [String] {
        orderedPacks.map(\.id)
    }
}

enum AstraPackComposition {
    static func resolve(packs: [AstraPackManifest]) -> AstraPackCompositionResult {
        resolve(inputs: packs.map { AstraPackCompositionInput(manifest: $0) })
    }

    static func resolve(entries: [AstraPackCatalogEntry]) -> AstraPackCompositionResult {
        resolve(inputs: entries.map(AstraPackCompositionInput.init(entry:)))
    }

    static func resolve(inputs: [AstraPackCompositionInput]) -> AstraPackCompositionResult {
        let orderedInputs = inputs.enumerated()
            .sorted { stableInputOrder($0, $1) }
            .map(\.element)
        let shelfResolution = resolveShelfDefaults(from: orderedInputs)
        let vocabularyResolution = resolveVocabulary(from: orderedInputs)

        return AstraPackCompositionResult(
            orderedInputs: orderedInputs,
            shelfDefaults: shelfResolution.shelfDefaults,
            capabilityPackageIDsByShelfID: shelfResolution.capabilityPackageIDsByShelfID,
            vocabulary: vocabularyResolution.vocabulary,
            policyRestrictions: resolvePolicyRestrictions(from: orderedInputs),
            diagnostics: shelfResolution.diagnostics + vocabularyResolution.diagnostics
        )
    }

    private static func stableInputOrder(
        _ lhs: EnumeratedSequence<[AstraPackCompositionInput]>.Element,
        _ rhs: EnumeratedSequence<[AstraPackCompositionInput]>.Element
    ) -> Bool {
        let lhsPriority = effectivePriority(for: lhs.element)
        let rhsPriority = effectivePriority(for: rhs.element)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsSourceRank = sourceRank(for: lhs.element)
        let rhsSourceRank = sourceRank(for: rhs.element)
        if lhsSourceRank != rhsSourceRank {
            return lhsSourceRank < rhsSourceRank
        }

        let idOrder = lhs.element.manifest.id.localizedCaseInsensitiveCompare(rhs.element.manifest.id)
        if idOrder != .orderedSame {
            return idOrder == .orderedAscending
        }

        let versionOrder = lhs.element.manifest.version.localizedCaseInsensitiveCompare(rhs.element.manifest.version)
        if versionOrder != .orderedSame {
            return versionOrder == .orderedAscending
        }

        let lhsPath = lhs.element.sourcePath ?? ""
        let rhsPath = rhs.element.sourcePath ?? ""
        if lhsPath != rhsPath {
            return lhsPath < rhsPath
        }

        return lhs.offset < rhs.offset
    }

    private static func effectivePriority(for input: AstraPackCompositionInput) -> Int {
        if let compositionPriority = input.manifest.compositionPriority {
            return compositionPriority
        }

        switch input.sourceKind {
        case .builtIn:
            return 0
        case .local:
            return 100
        case nil:
            return defaultPriority(forPackID: input.manifest.id)
        }
    }

    private static func defaultPriority(forPackID packID: String) -> Int {
        if packID == "astra.core" || packID.hasPrefix("astra.core.") {
            return -100
        }
        if packID.hasPrefix("astra.") {
            return 0
        }
        return 100
    }

    private static func sourceRank(for input: AstraPackCompositionInput) -> Int {
        switch input.sourceKind {
        case .builtIn:
            return 0
        case .local:
            return 1
        case nil:
            return input.manifest.id.hasPrefix("astra.") ? 0 : 1
        }
    }

    private struct ShelfResolution {
        var shelfDefaults: [AstraPackShelfDefault]
        var capabilityPackageIDsByShelfID: [String: [String]]
        var diagnostics: [AstraPackCompositionDiagnostic]
    }

    private struct ShelfContribution: Equatable {
        var packID: String
        var packCapabilityPackageIDs: [String]
        var shelfDefault: AstraPackShelfDefault
        var packOrder: Int
        var shelfOrder: Int
    }

    private static func resolveShelfDefaults(from inputs: [AstraPackCompositionInput]) -> ShelfResolution {
        var contributionsByShelfID: [String: [ShelfContribution]] = [:]

        for (packOrder, input) in inputs.enumerated() {
            for (shelfOrder, shelfDefault) in input.manifest.shelfDefaults.enumerated() {
                contributionsByShelfID[shelfDefault.id, default: []].append(ShelfContribution(
                    packID: input.manifest.id,
                    packCapabilityPackageIDs: input.manifest.capabilityPackageIDs,
                    shelfDefault: shelfDefault,
                    packOrder: packOrder,
                    shelfOrder: shelfOrder
                ))
            }
        }

        var diagnostics: [AstraPackCompositionDiagnostic] = []
        let winners = contributionsByShelfID.keys.sorted().compactMap { shelfID -> ShelfContribution? in
            guard let contributions = contributionsByShelfID[shelfID],
                  let winner = contributions.last else {
                return nil
            }

            let losingPackIDs = uniquePackIDs(
                contributions
                    .filter { contribution in
                        contribution.packID != winner.packID
                            && shelfContributionConflicts(contribution, winner)
                    }
                    .map(\.packID)
            )
            if !losingPackIDs.isEmpty {
                let packIDs = uniquePackIDs(contributions.map(\.packID))
                diagnostics.append(AstraPackCompositionDiagnostic(
                    packIDs: packIDs,
                    conflictKind: .shelfDefault,
                    key: shelfID,
                    winningPackID: winner.packID,
                    losingPackIDs: losingPackIDs,
                    message: "Shelf default '\(shelfID)' was declared by \(packIDs.joined(separator: ", ")); \(winner.packID) won by composition order."
                ))
            }

            return winner
        }
        .sorted {
            if $0.packOrder != $1.packOrder {
                return $0.packOrder < $1.packOrder
            }
            if $0.shelfOrder != $1.shelfOrder {
                return $0.shelfOrder < $1.shelfOrder
            }
            return $0.shelfDefault.id.localizedCaseInsensitiveCompare($1.shelfDefault.id) == .orderedAscending
        }

        return ShelfResolution(
            shelfDefaults: winners.map(\.shelfDefault),
            capabilityPackageIDsByShelfID: capabilityPackageIDsByShelfID(from: contributionsByShelfID),
            diagnostics: diagnostics
        )
    }

    private static func shelfContributionConflicts(
        _ lhs: ShelfContribution,
        _ rhs: ShelfContribution
    ) -> Bool {
        lhs.shelfDefault != rhs.shelfDefault
            || effectiveCapabilityPackageIDs(for: lhs) != effectiveCapabilityPackageIDs(for: rhs)
    }

    private static func effectiveCapabilityPackageIDs(for contribution: ShelfContribution) -> [String] {
        var capabilityPackageIDs: [String] = []
        appendUnique(contribution.packCapabilityPackageIDs, to: &capabilityPackageIDs)
        appendUnique(contribution.shelfDefault.capabilityPackageIDs, to: &capabilityPackageIDs)
        return capabilityPackageIDs
    }

    private static func capabilityPackageIDsByShelfID(
        from contributionsByShelfID: [String: [ShelfContribution]]
    ) -> [String: [String]] {
        var capabilityPackageIDsByShelfID: [String: [String]] = [:]
        for shelfID in contributionsByShelfID.keys.sorted() {
            guard let contributions = contributionsByShelfID[shelfID] else { continue }
            var capabilityPackageIDs: [String] = []
            for contribution in contributions {
                appendUnique(effectiveCapabilityPackageIDs(for: contribution), to: &capabilityPackageIDs)
            }
            capabilityPackageIDsByShelfID[shelfID] = capabilityPackageIDs
        }
        return capabilityPackageIDsByShelfID
    }

    private struct VocabularyResolution {
        var vocabulary: [String: String]
        var diagnostics: [AstraPackCompositionDiagnostic]
    }

    private struct VocabularyContribution: Equatable {
        var packID: String
        var value: String
    }

    private static func resolveVocabulary(from inputs: [AstraPackCompositionInput]) -> VocabularyResolution {
        var contributionsByKey: [String: [VocabularyContribution]] = [:]

        for input in inputs {
            for key in input.manifest.vocabulary.keys.sorted() {
                guard let value = input.manifest.vocabulary[key] else { continue }
                contributionsByKey[key, default: []].append(VocabularyContribution(
                    packID: input.manifest.id,
                    value: value
                ))
            }
        }

        var vocabulary: [String: String] = [:]
        var diagnostics: [AstraPackCompositionDiagnostic] = []
        for key in contributionsByKey.keys.sorted() {
            guard let contributions = contributionsByKey[key],
                  let winner = contributions.last else {
                continue
            }
            vocabulary[key] = winner.value

            let losingPackIDs = uniquePackIDs(
                contributions
                    .filter { $0.packID != winner.packID && $0.value != winner.value }
                    .map(\.packID)
            )
            if !losingPackIDs.isEmpty {
                let packIDs = uniquePackIDs(contributions.map(\.packID))
                diagnostics.append(AstraPackCompositionDiagnostic(
                    packIDs: packIDs,
                    conflictKind: .vocabulary,
                    key: key,
                    winningPackID: winner.packID,
                    losingPackIDs: losingPackIDs,
                    message: "Vocabulary key '\(key)' was declared by \(packIDs.joined(separator: ", ")); \(winner.packID) won by composition order."
                ))
            }
        }

        return VocabularyResolution(vocabulary: vocabulary, diagnostics: diagnostics)
    }

    private struct PolicyKey: Hashable {
        var contributionKind: String
        var action: String
    }

    private static func resolvePolicyRestrictions(from inputs: [AstraPackCompositionInput]) -> [AstraPackPolicyRestriction] {
        var order: [PolicyKey] = []
        var restrictionsByKey: [PolicyKey: AstraPackPolicyRestriction] = [:]

        for input in inputs {
            for restriction in input.manifest.policyRestrictions where restriction.effect == "restrict" {
                let key = PolicyKey(
                    contributionKind: restriction.contributionKind,
                    action: restriction.action
                )
                if restrictionsByKey[key] == nil {
                    order.append(key)
                }
                restrictionsByKey[key] = restriction
            }
        }

        return order.compactMap { restrictionsByKey[$0] }
    }

    private static func appendUnique(_ values: [String], to target: inout [String]) {
        for value in values where !target.contains(value) {
            target.append(value)
        }
    }

    private static func uniquePackIDs(_ values: [String]) -> [String] {
        var result: [String] = []
        appendUnique(values, to: &result)
        return result
    }
}
