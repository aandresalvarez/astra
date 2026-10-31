import Foundation
import ASTRAModels

/// Pure compatibility policy for ASTRA's process-local execution leases.
///
/// Workspaces organize tasks, but are not an isolation boundary. Admission is
/// therefore based on typed, canonical resource identities across the entire
/// app. Durable `TaskTurnRequest.resourceClaims` remain the authority; this
/// broker only evaluates and orders their process-local lease projections.
enum TaskExecutionResourceBroker {
    private struct ResourceIdentity: Hashable {
        let kind: TaskExecutionResourceKind
        let key: String
    }

    struct Conflict: Equatable, Sendable {
        let requested: TaskResourceLockClaim
        let holder: TaskResourceLockClaim
    }

    static func lockClaims(
        for claims: [TaskExecutionResourceClaim],
        taskID: UUID,
        requestID: UUID?,
        runMode: String
    ) -> [TaskResourceLockClaim] {
        var normalized: [ResourceIdentity: TaskExecutionResourceAccess] = [:]
        for claim in claims {
            let identity = ResourceIdentity(kind: claim.kind, key: canonicalKey(for: claim))
            let existing = normalized[identity]
            normalized[identity] = existing == .exclusive || claim.access == .exclusive ? .exclusive : .shared
        }
        return normalized.map { identity, access in
            TaskResourceLockClaim(
                taskID: taskID,
                resourceKey: identity.key,
                accessMode: access == .shared ? .readOnly : .write,
                runMode: runMode,
                resourceKind: identity.kind,
                requestID: requestID
            )
        }
        .sorted(by: claimOrder)
    }

    static func firstConflict(
        requested: [TaskResourceLockClaim],
        active: [TaskResourceLockClaim]
    ) -> Conflict? {
        for request in requested.sorted(by: claimOrder) {
            if let holder = active.first(where: { conflicts($0, request) }) {
                return Conflict(requested: request, holder: holder)
            }
        }
        return nil
    }

    static func canAcquire(
        _ requested: [TaskResourceLockClaim],
        active: [TaskResourceLockClaim]
    ) -> Bool {
        firstConflict(requested: requested, active: active) == nil
    }

    static func conflicts(_ existing: TaskResourceLockClaim, _ requested: TaskResourceLockClaim) -> Bool {
        guard identitiesOverlap(existing, requested) else { return false }
        return existing.accessMode == .write || requested.accessMode == .write
    }

    static func claimsCompete(_ earlier: TaskResourceLockClaim, _ later: TaskResourceLockClaim) -> Bool {
        guard identitiesOverlap(earlier, later) else { return false }
        return earlier.accessMode == .write || later.accessMode == .write
    }

    static func canonicalKey(for claim: TaskExecutionResourceClaim) -> String {
        canonicalKey(kind: claim.kind, key: claim.key)
    }

    static func canonicalKey(kind: TaskExecutionResourceKind, key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFilesystemKind(kind), !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    /// Names the holder so the user knows which task to stop: its title (when
    /// `holderTitle` knows it) and short id, plus both paths when the two
    /// claims overlap only because one folder contains the other.
    static func blockerSummary(
        requested: [TaskResourceLockClaim],
        active: [TaskResourceLockClaim],
        holderTitle: (UUID) -> String? = { _ in nil }
    ) -> String {
        guard let conflict = firstConflict(requested: requested, active: active) else {
            return "resource lock unavailable"
        }
        let holder = conflict.holder
        let summary = "Waiting for \(displayName(conflict.requested)) held by \(holderLabel(holder.taskID, title: holderTitle(holder.taskID)))"
        let held = canonicalKey(kind: holder.resourceKind, key: holder.resourceKey)
        let wanted = canonicalKey(kind: conflict.requested.resourceKind, key: conflict.requested.resourceKey)
        guard isFilesystemKind(holder.resourceKind), held != wanted else { return summary + "." }
        let relation = isPath(held, ancestorOf: wanted) ? "contains" : "is inside"
        return summary + ": it holds \(held), which \(relation) \(wanted)."
    }

    static func holderLabel(_ taskID: UUID, title: String?) -> String {
        let shortID = String(taskID.uuidString.prefix(8))
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "task \(shortID)" }
        let name = trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
        return "task \u{201C}\(name)\u{201D} (\(shortID))"
    }

    static func displayName(_ claim: TaskResourceLockClaim) -> String {
        claim.resourceKind.rawValue.replacingOccurrences(of: "_", with: " ") + " resource"
    }

    private static func identitiesOverlap(
        _ lhs: TaskResourceLockClaim,
        _ rhs: TaskResourceLockClaim
    ) -> Bool {
        guard lhs.resourceKind == rhs.resourceKind else { return false }
        let left = canonicalKey(kind: lhs.resourceKind, key: lhs.resourceKey)
        let right = canonicalKey(kind: rhs.resourceKind, key: rhs.resourceKey)
        if isFilesystemKind(lhs.resourceKind) {
            return left == right || isPath(left, ancestorOf: right) || isPath(right, ancestorOf: left)
        }
        return left == right
    }

    private static func isFilesystemKind(_ kind: TaskExecutionResourceKind) -> Bool {
        switch kind {
        case .workspace, .gitCommonDirectory:
            true
        case .browserSession, .docker, .remoteDirectory, .accountSession, .nativeSession:
            false
        }
    }

    private static func isPath(_ possibleAncestor: String, ancestorOf path: String) -> Bool {
        guard !possibleAncestor.isEmpty else { return false }
        let ancestor = possibleAncestor.hasSuffix("/") ? possibleAncestor : possibleAncestor + "/"
        return path.hasPrefix(ancestor)
    }

    private static func claimOrder(_ lhs: TaskResourceLockClaim, _ rhs: TaskResourceLockClaim) -> Bool {
        if lhs.resourceKind.rawValue != rhs.resourceKind.rawValue {
            return lhs.resourceKind.rawValue < rhs.resourceKind.rawValue
        }
        if lhs.resourceKey != rhs.resourceKey { return lhs.resourceKey < rhs.resourceKey }
        return lhs.accessMode.rawValue < rhs.accessMode.rawValue
    }
}
