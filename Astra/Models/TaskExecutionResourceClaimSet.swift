import Foundation

/// The durable form of a request's frozen resource claims.
///
/// `TaskTurnRequest.resourceClaimsJSON` first held a bare JSON array of
/// claims. A bare array cannot say which rules produced it, so a later change
/// to what a claim means would have to guess. New rows are written as this
/// envelope; the bare array still decodes, as version 0, so existing rows and
/// exported requests keep their meaning without a schema change.
///
/// A version this build does not know is unreadable rather than best-effort:
/// admission then falls back to an exclusive workspace lease and the runtime
/// rejects the request, the same way it treats malformed JSON.
public struct TaskExecutionResourceClaimSet: Codable, Equatable, Sendable {
    /// Bare-array rows written before the envelope existed.
    public static let legacyVersion = 0
    public static let currentVersion = 1

    public let version: Int
    public let claims: [TaskExecutionResourceClaim]

    public init(claims: [TaskExecutionResourceClaim], version: Int = TaskExecutionResourceClaimSet.currentVersion) {
        self.version = version
        self.claims = claims
    }

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads either form. Nil means the claims cannot be read: malformed
    /// JSON, an unknown claim value, or a version newer than this build.
    public static func decode(_ json: String?) -> TaskExecutionResourceClaimSet? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode([TaskExecutionResourceClaim].self, from: data) {
            return TaskExecutionResourceClaimSet(claims: legacy, version: legacyVersion)
        }
        guard let envelope = try? decoder.decode(TaskExecutionResourceClaimSet.self, from: data),
              (legacyVersion + 1...currentVersion).contains(envelope.version) else { return nil }
        return envelope
    }
}
