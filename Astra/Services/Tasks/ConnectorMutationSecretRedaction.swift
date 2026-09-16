import Foundation
import ASTRACore

/// Scrubs the credential a connector write was authenticated with out of
/// anything the provider says back.
///
/// The reason this exists rather than leaning on `RunSecretRedaction`: a
/// brokered connector credential is deliberately never registered as a run
/// secret. That is the whole point of the broker — the value is resolved
/// in-process, put on the wire, and never handed to the agent, so the run
/// redaction scope has no reason to know it and the persistence funnel for task
/// events and audit lines cannot recognise it.
///
/// Which is fine until a provider reflects it. Jira and the proxies in front of
/// it quote submitted parameters in error bodies, and `providerMessage` lifts
/// that body verbatim into a message that gets stored in a `TaskEvent` and
/// written to the audit log. So the one string that carries the credential back
/// out of the broker's containment is the failure message, and it has to be
/// scrubbed at the point of use.
enum ConnectorMutationSecretRedaction {
    /// Everything derived from the header that would identify the credential if
    /// it appeared in a response.
    ///
    /// A reflecting service can echo the value at any stage of decoding it: the
    /// whole header, the `Basic` payload on its own, or — for anything that
    /// parsed the credentials before rejecting them — the username and password
    /// separately. Scrubbing only the header string catches the least likely of
    /// those three.
    static func needles(authorizationHeader: String) -> [String] {
        var found: [String] = [authorizationHeader]
        let parts = authorizationHeader.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return usable(found) }
        let payload = parts[1]
        found.append(payload)
        if let decoded = Data(base64Encoded: payload),
           let pair = String(data: decoded, encoding: .utf8) {
            found.append(pair)
            // `user:token`, split on the first colon only: a token may contain
            // one, and splitting on all of them would leave the tail in place.
            if let separator = pair.firstIndex(of: ":") {
                found.append(String(pair[pair.startIndex..<separator]))
                found.append(String(pair[pair.index(after: separator)...]))
            }
        }
        return usable(found)
    }

    /// `message` with every form of the credential replaced.
    ///
    /// Longest first, so scrubbing a component cannot destroy the longer string
    /// that contains it and leave a partial match behind.
    static func redacted(_ message: String, authorizationHeader: String) -> String {
        var scrubbed = message
        for needle in needles(authorizationHeader: authorizationHeader) {
            scrubbed = scrubbed.replacingOccurrences(of: needle, with: RunSecretRedaction.marker)
        }
        return scrubbed
    }

    /// Drops what is too short to be worth matching.
    ///
    /// A one- or two-character username would turn every message into
    /// `[redacted]` fragments and destroy the diagnostic the event exists for,
    /// while protecting a value that is not secret. Same threshold the run
    /// redaction scope uses, for the same reason.
    private static func usable(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= RunSecretRedaction.minimumSecretLength }
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }
}
