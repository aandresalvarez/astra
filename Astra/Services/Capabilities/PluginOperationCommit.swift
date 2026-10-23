import Foundation
import SwiftData
import ASTRAModels

/// The SwiftData commit boundary. A successful callback alone is not proof;
/// a fresh context must observe the exact receipt saved with the domain state.
/// The caller owns restoring domain mutations only for `notCommitted`.
@MainActor
enum PluginOperationCommit {
    enum Failure: Error { case duplicateOperation, invalidReceipt, saveDidNotPersist }

    struct Snapshot: Equatable {
        let id: UUID
        let kind: PluginOperationReceipt.Kind
        let pluginIDs: [String]
        let workspaceIDs: [UUID]
        let manifestDigest: String?
        let completedAt: Date?

        init(_ receipt: PluginOperationReceipt) throws {
            guard receipt.formatVersion == 1, let kind = PluginOperationReceipt.Kind(rawValue: receipt.kindRawValue) else {
                throw Failure.invalidReceipt
            }
            let ids = receipt.workspaceIDStrings.compactMap(UUID.init(uuidString:))
            guard ids.count == receipt.workspaceIDStrings.count else { throw Failure.invalidReceipt }
            id = receipt.id
            self.kind = kind
            pluginIDs = receipt.pluginIDs
            workspaceIDs = ids
            manifestDigest = receipt.manifestDigest
            completedAt = receipt.completedAt
        }
    }

    enum Outcome {
        case committed(Snapshot, saveReportedFailure: Bool)
        case notCommitted(Error)
        /// Neither rollback nor irreversible cleanup is authorized without
        /// knowing whether the save landed. Keep prepared recovery material.
        case indeterminate(UUID, Error)
    }

    static func save(
        id: UUID = UUID(), kind: PluginOperationReceipt.Kind, pluginIDs: [String], workspaceIDs: [UUID],
        manifestDigest: String? = nil, modelContext: ModelContext,
        persist: (ModelContext) throws -> Void = { try $0.save() },
        readSaved: ((UUID, ModelContainer) throws -> Snapshot?)? = nil
    ) -> Outcome {
        let receipt = PluginOperationReceipt(id: id, kind: kind, pluginIDs: pluginIDs,
            workspaceIDs: workspaceIDs, manifestDigest: manifestDigest)
        let expected: Snapshot
        do {
            var descriptor = FetchDescriptor<PluginOperationReceipt>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard try modelContext.fetch(descriptor).isEmpty else { return .notCommitted(Failure.duplicateOperation) }
            expected = try Snapshot(receipt)
        } catch { return .notCommitted(error) }
        modelContext.insert(receipt)
        var saveFailure: Error?
        do { try persist(modelContext) } catch { saveFailure = error }
        do {
            let observed = try (readSaved ?? read)(id, modelContext.container)
            guard let observed else {
                modelContext.delete(receipt)
                return .notCommitted(saveFailure ?? Failure.saveDidNotPersist)
            }
            guard observed == expected else { return .indeterminate(id, Failure.invalidReceipt) }
            return .committed(observed, saveReportedFailure: saveFailure != nil)
        } catch { return .indeterminate(id, error) }
    }

    static func read(_ id: UUID, container: ModelContainer) throws -> Snapshot? {
        let saved = ModelContext(container)
        var descriptor = FetchDescriptor<PluginOperationReceipt>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try saved.fetch(descriptor).first.map(Snapshot.init)
    }
}
