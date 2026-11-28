import Foundation

/// Lexical facts about a path string, answered without Foundation's URL
/// round trip or the filesystem.
public enum FilePathForm {
    /// Whether `path` is absolute and already reads the way
    /// `URL(fileURLWithPath: path).standardizedFileURL.path` would write it,
    /// so a caller handling tens of thousands of paths can skip that round
    /// trip. Conservative: a path with any component standardizing could
    /// change (`.`, `..`, an empty one, a trailing slash, a tilde, or the
    /// `/private` prefix it may strip after asking the filesystem) answers
    /// false and is left to Foundation.
    ///
    /// One pass over the UTF-8 bytes: `String.contains` with a substring goes
    /// through Foundation, and was slower than the round trip it replaces.
    public static func isStandardizedAbsolute(_ path: String) -> Bool {
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: "."), tilde = UInt8(ascii: "~")
        let bytes = path.utf8
        guard bytes.count > 1, bytes.first == slash, bytes.last != slash,
              path != "/private", !path.hasPrefix("/private/") else { return false }
        var componentLength = 0
        var componentIsDots = true
        for byte in bytes.dropFirst() {
            if byte == tilde { return false }
            if byte == slash {
                // An empty component, or one that is "." or "..".
                if componentLength == 0 || (componentIsDots && componentLength <= 2) { return false }
                componentLength = 0
                componentIsDots = true
            } else {
                componentLength += 1
                if byte != dot { componentIsDots = false }
            }
        }
        return !(componentIsDots && componentLength <= 2)
    }
}
