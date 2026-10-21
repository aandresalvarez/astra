import Foundation

/// Admission for executable authentication repair, not a shell interpreter.
/// The legacy classifier may explain compound failures, but only a bounded
/// direct CLI call can authorize signing in or checking an inferred account.
enum RuntimeRepairInvocationPolicy {
    static func admitsDiagnostics(command: String, content: String) -> Bool {
        guard command.utf8.count <= 8_192, content.utf8.count <= 65_536 else { return false }
        // A definition is not evidence that its body ran. Without typed
        // execution provenance, do not pause on text printed by another tool.
        let definition = #"(?:\bfunction\s+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\))\s*\{"#
        return command.range(of: definition, options: .regularExpression) == nil
    }

    static func permitsAutomaticRepair(command: String, commands: [String]) -> Bool {
        let segments = CLISessionExpiryClassifier.segments(command)
        guard segments.count == 1, let segment = segments.first,
              segment.scope.isEmpty, segment.enclosingCommands.isEmpty,
              ["", ";", "\n"].contains(segment.separator), segment.words.count <= 256 else { return false }
        var words = segment.words
        guard dropAssignments(&words) else { return false }
        if let executable = words.first, (executable as NSString).lastPathComponent == "env" {
            words.removeFirst()
            while let option = words.first, option.hasPrefix("-") {
                words.removeFirst()
                if option == "--" { break }
                if ["-i", "--ignore-environment", "-"].contains(option) { continue }
                if ["-u", "--unset"].contains(option) {
                    guard let variable = words.first, variable != "PATH" else { return false }
                    words.removeFirst()
                    continue
                }
                if option == "--unset=PATH" || option == "-uPATH" { return false }
                if option.hasPrefix("--unset=") || (option.hasPrefix("-u") && option.count > 2) { continue }
                // cwd changes, split-string interpretation, and future env
                // options are outside this supported invocation grammar.
                return false
            }
            guard dropAssignments(&words) else { return false }
        }
        guard let executable = words.first else { return false }
        return commands.contains((executable as NSString).lastPathComponent)
    }

    private static func dropAssignments(_ words: inout [String]) -> Bool {
        while let first = words.first,
              first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            // The repair resolver uses ASTRA's trusted executable search.
            // A command-local PATH cannot be reproduced by that resolver.
            if first.hasPrefix("PATH=") { return false }
            words.removeFirst()
        }
        return true
    }
}
