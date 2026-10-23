import Foundation

/// Immutable repair facts captured from the failed invocation. Human-facing
/// diagnostics may change without changing the account or check a task resumes.
/// RepairAction deliberately excludes transient environment secrets from Codable.
public struct RuntimeRepairContext: Codable, Equatable, Sendable {
    public let version: Int
    public let providerBinary: String
    public let message: String
    public let repair: RepairAction
    public let offersAction: Bool

    public init(providerBinary: String, message: String, repair: RepairAction, offersAction: Bool) {
        version = 1
        self.providerBinary = providerBinary
        self.message = message
        self.repair = repair
        self.offersAction = offersAction
    }

    /// Missing or incompatible capture never authorizes an inferred sign-in.
    public static func manualReview(message: String) -> Self {
        Self(providerBinary: "", message: message,
             repair: RepairAction(strategy: .terminal, componentName: "Authentication", title: "Review authentication",
                                  verb: "Review", detail: "Review the failed command and repair authentication manually before resuming."),
             offersAction: false)
    }

    public func encoded() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func decode(from value: String) -> Self? {
        guard let data = value.data(using: .utf8), let context = try? JSONDecoder().decode(Self.self, from: data),
              context.version == 1 else { return nil }
        return context
    }
}
