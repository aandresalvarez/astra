import SwiftData

/// Whether a model is still safe to read persisted properties from.
///
/// A SwiftUI view that holds a `Workspace` (or any model) re-runs its body when
/// one of its own `@Query`s or observed properties moves, independently of the
/// parent that mounted it. Deleting the model and saving moves those inputs, so
/// the body runs once more against the dead model before any parent gate can
/// unmount it, and reading a persisted property that was not already faulted in
/// traps inside SwiftData (`aandresalvarez/astra#495`).
///
/// A persisted deletion leaves the model detached with `isDeleted` still false,
/// so a missing context alone is suspicious, but it is also the normal state of
/// a model that was never inserted (tests, unsaved drafts), whose values live
/// in memory and read fine. Only a model that reached a store carries a store
/// identifier, which is what tells the two apart.
public extension PersistentModel {
    var isLive: Bool {
        if isDeleted { return false }
        if modelContext != nil { return true }
        return persistentModelID.storeIdentifier == nil
    }
}
