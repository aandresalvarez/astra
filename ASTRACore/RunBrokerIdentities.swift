import Foundation

/// Stable identity of one installed ASTRA channel. It is distinct from a
/// process identity so UI, broker, and executor restarts retain the same owner.
public struct RunBrokerInstallationID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var id: UUID { rawValue }
}

/// Identity of the durable ledger/store instance that owns a record.
public struct RunBrokerStoreID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var id: UUID { rawValue }
}

/// Identity of one immutable execution attempt.
public struct RunBrokerExecutionID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var id: UUID { rawValue }
}

/// Identity of an operation whose side effects can outlive its execution.
public struct RunBrokerOperationID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var id: UUID { rawValue }
}

/// Identity of the broker/supervisor authority currently allowed to mutate an
/// execution record. The epoch, not this identifier alone, provides fencing.
public struct RunBrokerAuthorityID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var id: UUID { rawValue }
}

/// Monotonic fencing token within one execution/operation identity.
public struct RunBrokerAuthorityEpoch: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let initial = RunBrokerAuthorityEpoch(rawValue: 1)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func successor() -> Self? {
        guard rawValue < UInt64.max else { return nil }
        return Self(rawValue: rawValue + 1)
    }
}

/// An authority identity and its fencing epoch must always travel together.
public struct RunBrokerAuthority: Codable, Hashable, Sendable {
    public let id: RunBrokerAuthorityID
    public let epoch: RunBrokerAuthorityEpoch

    public init(id: RunBrokerAuthorityID, epoch: RunBrokerAuthorityEpoch) {
        self.id = id
        self.epoch = epoch
    }
}
