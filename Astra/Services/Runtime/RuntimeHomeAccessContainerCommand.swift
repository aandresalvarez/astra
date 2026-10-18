import Foundation
import ASTRACore

/// Runs inside the existing provider container, immediately before exec. It
/// observes the same uid, HOME, environment and mounts as the provider and
/// neither creates files nor changes permissions. No extra container is run.
enum RuntimeHomeAccessContainerCommand {
    static let failureMarker = "ASTRA_PROVIDER_HOME_ACCESS_DENIED:"

    static func command(runtime: AgentRuntimeID, executable: String, arguments: [String]) -> [String] {
        let policy = AgentRuntimeAdapterRegistry.homeAccessPolicy(for: runtime)
        return ["/bin/sh", "-c", script(policy: policy), "astra-home-preflight", executable] + arguments
    }

    static func script(policy: RuntimeHomeAccessPolicy) -> String {
        var lines = [#"""
        astra_home_fail() {
            printf '%s %s\n' 'ASTRA_PROVIDER_HOME_ACCESS_DENIED:' "$1" >&2
            exit 78
        }
        astra_home_directory() {
            astra_p=$1
            if [ -e "$astra_p" ] || [ -L "$astra_p" ]; then
                [ -d "$astra_p" ] && [ -r "$astra_p" ] && [ -x "$astra_p" ] || astra_home_fail "Cannot read settings/state folder: $astra_p"
                if [ "$2" = 1 ]; then
                    [ -w "$astra_p" ] || astra_home_fail "Cannot write state folder: $astra_p"
                fi
            elif [ "${3:-$2}" = 1 ]; then
                astra_parent=${astra_p%/*}
                [ -n "$astra_parent" ] || astra_parent=.
                while [ ! -e "$astra_parent" ] && [ ! -L "$astra_parent" ]; do
                    case "$astra_parent" in */*) astra_parent=${astra_parent%/*};; *) astra_parent=.;; esac
                    [ -n "$astra_parent" ] || astra_parent=/
                done
                [ -d "$astra_parent" ] && [ -w "$astra_parent" ] && [ -x "$astra_parent" ] || astra_home_fail "Cannot create state folder: $astra_p"
            fi
        }
        astra_home_file() {
            if [ -e "$1" ] || [ -L "$1" ]; then
                [ -f "$1" ] && [ -r "$1" ] || astra_home_fail "Cannot read settings file: $1"
            elif [ "$2" = 1 ]; then
                astra_home_fail "Settings override does not exist: $1"
            fi
        }
        if [ -z "${HOME:-}" ]; then
            HOME=$(cd ~ && pwd) || astra_home_fail 'Cannot resolve provider home'
            export HOME
        fi
        """#]
        for (index, root) in policy.roots.enumerated() {
            let variable = "astra_root_\(index)"
            lines.append("\(variable)=\"$HOME\"/\(quoted(root.fallback))")
            if let fallback = root.linuxFallbackVariable {
                lines.append("if [ -n \"${\(fallback):-}\" ]; then \(variable)=\"$\(fallback)\"/\(quoted(root.linuxFallbackSuffix)); fi")
            }
            if let override = root.variable {
                lines.append("if [ -n \"${\(override):-}\" ]; then \(variable)=\"$\(override)\"; fi")
            }
            if !root.suffix.isEmpty { lines.append("\(variable)=\"$\(variable)\"/\(quoted(root.suffix))") }
            lines.append("astra_home_directory \"$\(variable)\" \(root.writable ? 1 : 0) \((root.createIfMissing ?? root.writable) ? 1 : 0)")
            for file in root.files {
                let check = "astra_home_file \"$\(variable)\"/\(quoted(file)) 0"
                if let override = root.fileOverrides[file] {
                    lines.append("if [ -n \"${\(override):-}\" ]; then astra_home_file \"$\(override)\" 1; else \(check); fi")
                } else if let preferred = root.fallbacks[file] {
                    lines.append("if [ ! -e \"$\(variable)\"/\(quoted(preferred)) ] && [ ! -L \"$\(variable)\"/\(quoted(preferred)) ]; then \(check); fi")
                } else {
                    lines.append(check)
                }
            }
            for directory in root.directories {
                lines.append("astra_home_directory \"$\(variable)\"/\(quoted(directory)) \(root.writable ? 1 : 0) \((root.createIfMissing ?? root.writable) ? 1 : 0)")
            }
        }
        lines.append("astra_home_config=\"$HOME\"")
        if let variable = policy.homeFilesOverrideVariable {
            lines.append("if [ -n \"${\(variable):-}\" ]; then astra_home_config=\"$\(variable)\"; fi")
        }
        for file in policy.homeFiles { lines.append("astra_home_file \"$astra_home_config\"/\(quoted(file)) 0") }
        for variable in policy.environmentFiles {
            lines.append("if [ -n \"${\(variable):-}\" ]; then astra_home_file \"$\(variable)\" 1; fi")
        }
        lines.append(#"exec "$@""#)
        return lines.joined(separator: "\n")
    }

    private static func quoted(_ value: String) -> String { RuntimeRemediationCatalog.shellQuoted(value) }
}
