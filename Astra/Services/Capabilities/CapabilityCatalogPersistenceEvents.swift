import Foundation

struct CapabilityCatalogPersistenceChange: Equatable, Sendable {
    let workspaceID: UUID?

    static func workspace(_ id: UUID) -> Self { Self(workspaceID: id) }
    static let global = Self(workspaceID: nil)
}

extension Notification.Name {
    static let capabilityCatalogPersistenceChanged = Notification.Name("astra.capabilityCatalogPersistenceChanged")
}

enum CapabilityCatalogPersistenceEvents {
    @MainActor
    static func post(_ change: CapabilityCatalogPersistenceChange) {
        NotificationCenter.default.post(name: .capabilityCatalogPersistenceChanged, object: change)
    }
}
