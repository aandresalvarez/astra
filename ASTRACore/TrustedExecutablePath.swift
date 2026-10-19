import Foundation

/// Which executables ASTRA runs on its own, by path: a health check on
/// every scan (`HealthCheckPolicy`), a repair's re-check, and a Terminal
/// repair button (`TerminalRepairPolicy`). Allowlisted arguments don't make
/// a program read-only: `/tmp/plugin/gh` named after the GitHub CLI is
/// whatever its author wrote. So a known CLI counts only as a bare name
/// found on ASTRA's own search path, or as an installed path: an absolute
/// path of plain components under a system or package-manager prefix
/// (`/opt/homebrew/…` and `/usr/local/…` included), never a home,
/// workspace or temporary folder, and still there once symlinks resolve.
public enum TrustedExecutablePath {
    public static let installedPrefixes = ["/usr/", "/bin/", "/sbin/", "/opt/", "/Applications/", "/Library/"]

    /// `candidate` when it is an absolute path of plain components (no `.`
    /// or `..`, no shell syntax), so it is safe as one Terminal word, under
    /// an installed prefix. The string alone: see `isInstalled` for the file.
    public static func installedPath(_ candidate: String) -> String? {
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard candidate.hasPrefix("/"), candidate.count <= 1024,
              installedPrefixes.contains(where: { candidate.hasPrefix($0) }),
              candidate.range(of: #"^(/[A-Za-z0-9._+-]+)+$"#, options: .regularExpression) != nil,
              !components.contains(where: { $0 == "." || $0 == ".." })
        else { return nil }
        return candidate
    }

    /// True for an executable a plugin may name: a bare plain name, which
    /// ASTRA looks up on its own search path, or an installed path.
    public static func isTrustedDeclaration(_ binary: String) -> Bool {
        guard binary.contains("/") else {
            return binary.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]*$"#, options: .regularExpression) != nil
        }
        return installedPath(binary) != nil
    }

    /// True when the file at `path`, symlinks resolved, is an installed path:
    /// `/opt/homebrew/bin/gh` resolves into Homebrew's Cellar and stays
    /// trusted; a link from there into a temporary folder does not.
    public static func isInstalled(_ path: String) -> Bool {
        isInstalled(path) { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    /// `isInstalled` with the symlink resolution given (for tests).
    static func isInstalled(_ path: String, resolvingSymlinks resolve: (String) -> String) -> Bool {
        installedPath(path) != nil && installedPath(resolve(path)) != nil
    }
}
