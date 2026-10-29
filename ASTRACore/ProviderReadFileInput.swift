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
              let rawPath = arguments["Path"] as? String,
              !rawPath.contains("\0") else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        for alias in ["file_path", "filePath", "path", "target_path", "targetPath"] where arguments[alias] != nil {
            guard let value = arguments[alias] as? String, value == rawPath else { return nil }
        }
        return path
    }
}
