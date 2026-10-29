import Foundation

/// Antigravity's `read_file` contract uses `Path`. Keep its native arguments
/// intact: generic alias merging can replace the path the provider actually
/// reads with a different, apparently permitted path.
public enum ProviderReadFileInput {
    public static func path(from input: [String: Any]?) -> String? {
        guard var arguments = input else { return nil }
        arguments.removeValue(forKey: ToolInputFingerprint.key)
        if arguments.keys.contains("summary") {
            guard arguments.count == 1,
                  let summary = arguments["summary"] as? String,
                  let data = summary.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            arguments = object
        }
        // These are not native argument containers. Refuse ambiguous payloads
        // instead of choosing a different nesting/alias precedence to agy.
        guard ["input", "arguments", "args", "summary"].allSatisfy({ arguments[$0] == nil }),
              let rawPath = validatedPath(arguments["Path"] as? String) else { return nil }
        for alias in ["file_path", "filePath", "path", "target_path", "targetPath"] where arguments[alias] != nil {
            guard let value = arguments[alias] as? String, value == rawPath else { return nil }
        }
        return rawPath
    }

    /// Policy must check the same filename the native tool will read. In
    /// particular, trimming a trailing space could conceal an external symlink.
    public static func validatedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty, !path.contains("\0"),
              path == path.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return path
    }
}
