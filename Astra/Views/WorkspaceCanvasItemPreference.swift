import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

struct WorkspaceCanvasItemPreference: Equatable {
    static let closedRawValue = ""
    static let emptyStorageRawValue = "{}"
    static let maximumEntryCount = 256

    private struct StoredEntry: Codable, Equatable {
        var itemRawValue: String
        var accessOrdinal: UInt64
    }

    private struct StorageEnvelope: Codable, Equatable {
        var version = 2
        var nextAccessOrdinal: UInt64
        var entries: [String: StoredEntry]

        static let empty = StorageEnvelope(nextAccessOrdinal: 1, entries: [:])
    }

    static func rawValue(for item: WorkspaceCanvasItem?) -> String {
        item?.rawValue ?? closedRawValue
    }

    static func item(for rawValue: String) -> WorkspaceCanvasItem? {
        WorkspaceCanvasItem(rawValue: rawValue)
    }

    static func rawValue(in storageRawValue: String, for conversationID: String?) -> String {
        guard let conversationID, !conversationID.isEmpty else { return closedRawValue }
        return decodedStorage(storageRawValue).entries[conversationID]?.itemRawValue ?? closedRawValue
    }

    static func item(in storageRawValue: String, for conversationID: String?) -> WorkspaceCanvasItem? {
        item(for: rawValue(in: storageRawValue, for: conversationID))
    }

    static func updatedStorageRawValue(
        currentStorageRawValue: String,
        conversationID: String?,
        item: WorkspaceCanvasItem?,
        remember: Bool
    ) -> String {
        guard remember, let conversationID, !conversationID.isEmpty else {
            return currentStorageRawValue
        }

        var storage = decodedStorage(currentStorageRawValue)
        if let item {
            let ordinal = allocateAccessOrdinal(in: &storage)
            storage.entries[conversationID] = StoredEntry(
                itemRawValue: rawValue(for: item),
                accessOrdinal: ordinal
            )
        } else {
            storage.entries.removeValue(forKey: conversationID)
        }
        evictLeastRecentlyUsedEntriesIfNeeded(in: &storage)
        return encodedStorage(storage)
    }

    /// Refresh recency only after a remembered item is actually restored.
    /// Merely probing a conversation must not keep stale preferences alive.
    static func touchingStorageRawValue(
        _ storageRawValue: String,
        conversationID: String?
    ) -> String {
        guard let conversationID, !conversationID.isEmpty else { return storageRawValue }
        var storage = decodedStorage(storageRawValue)
        guard storage.entries[conversationID] != nil else { return storageRawValue }
        let ordinal = allocateAccessOrdinal(in: &storage)
        storage.entries[conversationID]?.accessOrdinal = ordinal
        return encodedStorage(storage)
    }

    /// Migrates legacy `[conversationID: item]` JSON and caps oversized state
    /// at load time. Legacy dictionaries contain no recency metadata, so their
    /// keys provide the only deterministic tie-breaker during one-time trim.
    static func normalizedStorageRawValue(_ storageRawValue: String) -> String {
        var storage = decodedStorage(storageRawValue)
        evictLeastRecentlyUsedEntriesIfNeeded(in: &storage)
        return encodedStorage(storage)
    }

    static func entryCount(in storageRawValue: String) -> Int {
        decodedStorage(storageRawValue).entries.count
    }

    static func shouldRestoreRememberedItem(
        activeItem: WorkspaceCanvasItem?,
        isRightRailVisible: Bool,
        rememberedItem: WorkspaceCanvasItem?,
        canPresentRememberedItem: Bool
    ) -> Bool {
        activeItem == nil
            && !isRightRailVisible
            && rememberedItem != nil
            && canPresentRememberedItem
    }

    private static func decodedStorage(_ rawValue: String) -> StorageEnvelope {
        guard let data = rawValue.data(using: .utf8) else { return .empty }
        if let decoded = try? JSONDecoder().decode(StorageEnvelope.self, from: data),
           decoded.version == 2 {
            return sanitized(decoded)
        }

        guard let legacy = try? JSONDecoder().decode([String: String].self, from: data) else {
            return .empty
        }
        var entries: [String: StoredEntry] = [:]
        for (offset, pair) in legacy.sorted(by: { $0.key < $1.key }).enumerated()
        where !pair.key.isEmpty && WorkspaceCanvasItem(rawValue: pair.value) != nil {
            entries[pair.key] = StoredEntry(
                itemRawValue: pair.value,
                accessOrdinal: UInt64(offset + 1)
            )
        }
        return StorageEnvelope(nextAccessOrdinal: UInt64(entries.count + 1), entries: entries)
    }

    private static func encodedStorage(_ storage: StorageEnvelope) -> String {
        guard !storage.entries.isEmpty else { return emptyStorageRawValue }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(storage),
              let encoded = String(data: data, encoding: .utf8) else {
            return emptyStorageRawValue
        }
        return encoded
    }

    private static func sanitized(_ storage: StorageEnvelope) -> StorageEnvelope {
        let validEntries = storage.entries.filter {
            !$0.key.isEmpty && WorkspaceCanvasItem(rawValue: $0.value.itemRawValue) != nil
        }
        let maximumOrdinal = validEntries.values.map(\.accessOrdinal).max() ?? 0
        return StorageEnvelope(
            nextAccessOrdinal: max(storage.nextAccessOrdinal, maximumOrdinal &+ 1),
            entries: validEntries
        )
    }

    private static func allocateAccessOrdinal(in storage: inout StorageEnvelope) -> UInt64 {
        if storage.nextAccessOrdinal == UInt64.max {
            renormalizeOrdinals(in: &storage)
        }
        let ordinal = storage.nextAccessOrdinal
        storage.nextAccessOrdinal += 1
        return ordinal
    }

    private static func renormalizeOrdinals(in storage: inout StorageEnvelope) {
        let orderedIDs = storage.entries.keys.sorted {
            let lhs = storage.entries[$0]?.accessOrdinal ?? 0
            let rhs = storage.entries[$1]?.accessOrdinal ?? 0
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        for (offset, id) in orderedIDs.enumerated() {
            storage.entries[id]?.accessOrdinal = UInt64(offset + 1)
        }
        storage.nextAccessOrdinal = UInt64(orderedIDs.count + 1)
    }

    private static func evictLeastRecentlyUsedEntriesIfNeeded(in storage: inout StorageEnvelope) {
        let overflow = storage.entries.count - maximumEntryCount
        guard overflow > 0 else { return }
        let victims = storage.entries.keys.sorted {
            let lhs = storage.entries[$0]?.accessOrdinal ?? 0
            let rhs = storage.entries[$1]?.accessOrdinal ?? 0
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }.prefix(overflow)
        for id in victims {
            storage.entries.removeValue(forKey: id)
        }
    }
}

enum WorkspaceCanvasItemPreferenceStore {
    static func load(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: AppStorageKeys.activeWorkspaceCanvasItemsByConversation)
            ?? WorkspaceCanvasItemPreference.emptyStorageRawValue
    }

    @discardableResult
    static func saveIfChanged(
        currentRawValue: String,
        updatedRawValue: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard currentRawValue != updatedRawValue else { return false }
        save(updatedRawValue, defaults: defaults)
        return true
    }

    static func save(_ rawValue: String, defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: AppStorageKeys.activeWorkspaceCanvasItemsByConversation)
    }

    @discardableResult
    static func remove(conversationID: String, defaults: UserDefaults = .standard) -> Bool {
        let current = load(defaults: defaults)
        let updated = WorkspaceCanvasItemPreference.updatedStorageRawValue(
            currentStorageRawValue: current,
            conversationID: conversationID,
            item: nil,
            remember: true
        )
        return saveIfChanged(currentRawValue: current, updatedRawValue: updated, defaults: defaults)
    }
}

struct GeneratedHTMLDiscoveryState: Equatable {
    let preferredPath: String
    let signature: String

    static let empty = GeneratedHTMLDiscoveryState(preferredPath: "", signature: "")

    static func discovered(preferredPath: String, taskID: UUID) -> GeneratedHTMLDiscoveryState {
        GeneratedHTMLDiscoveryState(
            preferredPath: preferredPath,
            signature: TaskGeneratedFiles.htmlPreviewSignature(for: preferredPath, taskID: taskID)
        )
    }

    func shouldApplyDiscovery(preferredPath: String, taskID: UUID) -> Bool {
        signature != TaskGeneratedFiles.htmlPreviewSignature(for: preferredPath, taskID: taskID)
    }
}
