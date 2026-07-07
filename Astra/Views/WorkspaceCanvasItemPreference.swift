import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

struct WorkspaceCanvasItemPreference: Equatable {
    static let closedRawValue = ""
    static let emptyStorageRawValue = "{}"

    static func rawValue(for item: WorkspaceCanvasItem?) -> String {
        item?.rawValue ?? closedRawValue
    }

    static func item(for rawValue: String) -> WorkspaceCanvasItem? {
        WorkspaceCanvasItem(rawValue: rawValue)
    }

    static func rawValue(in storageRawValue: String, for conversationID: String?) -> String {
        guard let conversationID, !conversationID.isEmpty else { return closedRawValue }
        return decodedStorage(storageRawValue)[conversationID] ?? closedRawValue
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
            storage[conversationID] = rawValue(for: item)
        } else {
            storage.removeValue(forKey: conversationID)
        }
        return encodedStorage(storage)
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

    private static func decodedStorage(_ rawValue: String) -> [String: String] {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func encodedStorage(_ storage: [String: String]) -> String {
        guard !storage.isEmpty else { return emptyStorageRawValue }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(storage),
              let encoded = String(data: data, encoding: .utf8) else {
            return emptyStorageRawValue
        }
        return encoded
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
