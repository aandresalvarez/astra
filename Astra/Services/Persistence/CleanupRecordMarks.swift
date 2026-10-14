import Foundation

/// The marks beside one cleanup record that tell a retry whether the deletion
/// it describes was saved: `.store`, the store the deletion was about to be
/// saved to, written before the save, and `.committed`, written once the save
/// succeeded. Every deletion outbox, connector credential cleanup and
/// workspace deletion alike, keeps its marks through this type and judges
/// them through `verdict`, so one rule decides what a retry may remove.
public struct CleanupRecordMarks: Sendable {
    public let record: URL

    public init(record: URL) {
        self.record = record
    }

    public enum StoreMark: Equatable, Sendable {
        /// Written before store marks existed.
        case absent
        case recorded(String)
        /// Can't be read, or reads as something `PersistentStoreIdentity`
        /// never writes, as a truncated write leaves.
        case unreadable
    }

    public struct State: Equatable, Sendable {
        /// Whether the deletion is marked saved; nil when that can't be checked.
        public var committed: Bool?
        public var store: StoreMark

        public init(committed: Bool?, store: StoreMark) {
            self.committed = committed
            self.store = store
        }
    }

    public func read() -> State {
        let committed: Bool?
        do {
            _ = try FileManager.default.attributesOfItem(atPath: committedURL.path)
            committed = true
        } catch {
            committed = WorkspaceFileLayout.isMissingFile(error) ? false : nil
        }
        let store: StoreMark
        do {
            store = PersistentStoreIdentity.decode(try Data(contentsOf: storeURL)).map { .recorded($0) } ?? .unreadable
        } catch {
            store = WorkspaceFileLayout.isMissingFile(error) ? .absent : .unreadable
        }
        return State(committed: committed, store: store)
    }

    /// Names the store the deletion is about to be saved to, and returns the
    /// mark this replaced, nil when there was none, for `restoreStore` to put
    /// back if the deletion isn't saved. One that can't be read throws, since
    /// it couldn't be put back.
    @discardableResult
    public func markStore(_ identity: String) throws -> Data? {
        let previous: Data?
        do {
            previous = try Data(contentsOf: storeURL)
        } catch where WorkspaceFileLayout.isMissingFile(error) {
            previous = nil
        }
        try Data(identity.utf8).write(to: storeURL, options: .atomic)
        return previous
    }

    /// Puts back the store mark `markStore` replaced.
    public func restoreStore(_ previous: Data?) {
        if let previous {
            try? previous.write(to: storeURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: storeURL)
        }
    }

    public func markCommitted() throws {
        try Data().write(to: committedURL, options: .atomic)
    }

    /// Removes both marks, with or after their record.
    public func remove() {
        try? FileManager.default.removeItem(at: committedURL)
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// When the record was last written; nil when that can't be read.
    public var writtenAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: record.path))?[.modificationDate] as? Date
    }

    private var committedURL: URL { record.appendingPathExtension("committed") }
    private var storeURL: URL { record.appendingPathExtension("store") }

    public enum Verdict: Equatable, Sendable {
        /// Saved: what it names may be cleaned up.
        case committed
        /// Never saved: its owner is still in the store it was recorded for.
        /// Dropped without removing anything.
        case unsaved
        /// Can't be told, the store having changed since: dropped without
        /// removing anything, while what it names stays owned until the other
        /// cleanups of its batch have run.
        case unconfirmed
        /// A mark, or which store this is, can't be read for now: kept, and
        /// what it names stays owned.
        case wait
    }

    /// The one rule. A deletion marked saved was saved. One a quit left
    /// unmarked was saved when the store it was recorded for no longer holds
    /// its owner, and never saved when it still does; in another store it
    /// can't be told. A record from before store marks existed is judged by
    /// the store alone, and only one written after this store was created,
    /// so a recovery's replacement store never vouches for it.
    public static func verdict(
        _ state: State, ownerStored: Bool, currentStore: String?, storeCreated: Date?, writtenAt: Date?
    ) -> Verdict {
        guard let marked = state.committed else { return .wait }
        switch state.store {
        case .unreadable:
            return .wait
        case .absent:
            if marked { return .committed }
            guard let storeCreated, let writtenAt, writtenAt >= storeCreated else { return .wait }
            return ownerStored ? .unsaved : .committed
        case .recorded(let recorded):
            if marked { return .committed }
            guard let currentStore else { return .wait }
            guard recorded == currentStore else { return .unconfirmed }
            return ownerStored ? .unsaved : .committed
        }
    }
}
