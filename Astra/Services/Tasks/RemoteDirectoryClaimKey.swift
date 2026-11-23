import Foundation
import ASTRAPersistence

/// The identity a `.remoteDirectory` claim is held under: the machine a
/// workspace SSH connection reaches and the folder on it the task works in.
///
/// Nothing here contacts the host, so two spellings are compared by what can
/// be known locally:
///
/// - The machine is the connection's declared `host` and `port`. A connection
///   that names only an SSH config alias is keyed by that alias. Two names for
///   one machine (an alias here, its `HostName` there) are not unified.
/// - The folder is normalized lexically. A relative path and `~/…` are rooted
///   at the login user's home (`~user`, or `~` when no user is declared).
///   Symlinks and the real location of a home directory stay unknown.
///
/// Where the relation between two folders on one machine cannot be known
/// (`~/app` and `/srv/app`, or a `..` that climbs out of a home), they are
/// treated as overlapping. Unknown never reads as independent.
enum RemoteDirectoryClaimKey {
    private static let separator: Character = " "

    static func key(for connection: SSHConnection) -> String? {
        guard let machine = machine(for: connection) else { return nil }
        return machine + String(separator) + canonicalPath(connection.remotePath, user: connection.user)
    }

    static func machine(for connection: SSHConnection) -> String? {
        let host = token(connection.host).lowercased()
        if !host.isEmpty { return "\(host):\(connection.port)" }
        let alias = token(connection.configAlias)
        return alias.isEmpty ? nil : "alias:\(alias)"
    }

    /// `/absolute/path`, `~user/path`, or `~/path`, without `.` segments,
    /// repeated or trailing slashes. A `..` that leaves its root yields `/`,
    /// the whole machine.
    static func canonicalPath(_ rawPath: String, user: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = token(user).isEmpty ? "~" : "~\(token(user))"
        var root: String
        var rest: Substring
        if trimmed.hasPrefix("/") {
            root = "/"
            rest = Substring(trimmed)
        } else if trimmed.hasPrefix("~") {
            let first = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            root = first[0] == "~" ? home : String(first[0])
            rest = first.count > 1 ? first[1] : ""
        } else {
            root = home
            rest = Substring(trimmed)
        }
        var components: [Substring] = []
        for component in rest.split(separator: "/", omittingEmptySubsequences: true) where component != "." {
            guard component == ".." else { components.append(component); continue }
            if components.isEmpty {
                // Above a home directory is somewhere on the machine no local
                // rule can place.
                root = "/"
                components = []
                break
            }
            components.removeLast()
        }
        let joined = components.joined(separator: "/")
        if root == "/" { return "/" + joined }
        return joined.isEmpty ? root : root + "/" + joined
    }

    /// Whether two keys may name the same folder, or one a folder inside the
    /// other.
    static func overlap(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = parts(lhs), let right = parts(rhs) else { return lhs == rhs }
        guard left.machine == right.machine else { return false }
        let leftRoot = root(of: left.path), rightRoot = root(of: right.path)
        guard leftRoot == rightRoot else {
            // Two different named users' homes are separate folders. Anything
            // else (a home against an absolute path, or against the unnamed
            // login user's home) could be the same place.
            return !(isNamedHome(leftRoot) && isNamedHome(rightRoot))
        }
        return left.path == right.path || contains(left.path, right.path) || contains(right.path, left.path)
    }

    /// `service on release.example.com:22`, for a waiting line.
    static func displayName(_ key: String) -> String {
        guard let parts = parts(key) else { return key }
        return "\(parts.path) on \(parts.machine)"
    }

    private static func parts(_ key: String) -> (machine: String, path: String)? {
        guard let index = key.firstIndex(of: separator) else { return nil }
        let machine = String(key[..<index]), path = String(key[key.index(after: index)...])
        return machine.isEmpty || path.isEmpty ? nil : (machine, path)
    }

    private static func root(of path: String) -> String {
        path.hasPrefix("/") ? "/" : String(path.split(separator: "/", maxSplits: 1)[0])
    }

    private static func isNamedHome(_ root: String) -> Bool {
        root.hasPrefix("~") && root.count > 1
    }

    private static func contains(_ outer: String, _ inner: String) -> Bool {
        inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/")
    }

    /// A machine or user name as one token: the key separates its two halves
    /// with a space.
    private static func token(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
