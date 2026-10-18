import Foundation
import AstraObjCSupport

/// Identifies only deny entries that apply to this user and the failed access.
/// Never remove an entire ACL: it can also carry deliberate sharing policy.
enum RuntimeAccessACL {
    struct DenyEntry: Equatable, Sendable {
        let principal: String?
        let permissions: [String]
        // A group rule also governs other users. Do not rewrite shared policy
        // merely to restore this user's provider access.
        var requiresManualRepair: Bool { principal == nil || principal?.hasPrefix("group:") == true }
    }
    static func denyingEntries(at path: String, permissions: [acl_perm_t]) -> [DenyEntry] {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return [] }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY.rawValue
        var denied: [DenyEntry] = []
        while acl_get_entry(acl, selector, &entry) == 0, let current = entry {
            selector = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var set: acl_permset_t?
            guard acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_DENY,
                  acl_get_permset(current, &set) == 0, let set,
                  permissions.contains(where: { acl_get_perm_np(set, $0) == 1 }),
                  let principal = acl_get_qualifier(current) else { continue }
            defer { acl_free(principal) }
            if AstraMembership.currentUserMatchesPrincipal(principal.assumingMemoryBound(to: UInt8.self)) {
                let names = permissions.filter { acl_get_perm_np(set, $0) == 1 }.compactMap(permissionName)
                denied.append(DenyEntry(
                    principal: AstraMembership.posixPrincipal(forUUID: principal.assumingMemoryBound(to: UInt8.self)),
                    permissions: Array(Set(names)).sorted()
                ))
            }
        }
        return denied
    }

    static func repairCommands(path: String, entries: [DenyEntry], sudo: Bool = false, link: Bool = false) -> [String] {
        // Subtract only the failed permissions. Unlike -N or -a#, this also
        // preserves unrelated permissions and inheritance flags in the SAME ACE.
        entries.compactMap {
            guard !$0.requiresManualRepair, let principal = $0.principal else { return nil }
            let entry = "\(principal) deny \($0.permissions.joined(separator: ","))"
            return "\(sudo ? "sudo " : "")chmod \(link ? "-h " : "")-a \(RuntimeRemediationCatalog.shellQuoted(entry)) \(RuntimeRemediationCatalog.shellQuoted(path))"
        }
    }

    private static func permissionName(_ permission: acl_perm_t) -> String? {
        switch permission {
        case ACL_READ_DATA: return "read"
        case ACL_WRITE_DATA: return "write"
        case ACL_APPEND_DATA: return "append"
        case ACL_EXECUTE: return "execute"
        case ACL_DELETE: return "delete"
        case ACL_DELETE_CHILD: return "delete_child"
        default: return nil
        }
    }
}
