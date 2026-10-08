import Foundation

/// Which Docker daemon a `docker` command reaches when it names none itself.
///
/// `docker context use` persistently points every later command at another
/// daemon, possibly over SSH or TCP, so `docker run` is local only when the
/// daemon it will reach is a socket on this machine. The CLI's own order is
/// followed: `DOCKER_HOST`, then `DOCKER_CONTEXT`, then the config's
/// `currentContext`, whose endpoint is read from its context metadata. A
/// context that cannot be read is not called local.
enum DockerDaemonLocality {
    static func isLocal(
        context explicitContext: String? = nil,
        environment: [String: String],
        configDirectory: URL
    ) -> Bool {
        let context = explicitContext
            ?? nonEmpty(environment["DOCKER_CONTEXT"])
            ?? (nonEmpty(environment["DOCKER_HOST"]) == nil ? currentContext(in: configDirectory) : nil)
        guard let context, context != "default" else {
            return nonEmpty(environment["DOCKER_HOST"]).map(isLocalEndpoint) ?? true
        }
        return endpoint(ofContext: context, in: configDirectory).map(isLocalEndpoint) ?? false
    }

    /// This process's own view: its environment, and the command's `--config`
    /// directory, `DOCKER_CONFIG`, or `~/.docker`.
    static func isLocal(context: String? = nil, configDirectory override: String? = nil) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let directory = (nonEmpty(override) ?? nonEmpty(environment["DOCKER_CONFIG"]))
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker", isDirectory: true)
        return isLocal(context: context, environment: environment, configDirectory: directory)
    }

    static func isLocalEndpoint(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered.hasPrefix("unix://") || lowered.hasPrefix("npipe://")
    }

    private static func currentContext(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return nonEmpty(object["currentContext"] as? String)
    }

    private static func endpoint(ofContext name: String, in directory: URL) -> String? {
        let meta = directory.appendingPathComponent("contexts/meta", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: meta, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("meta.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["Name"] as? String == name else {
                continue
            }
            let endpoints = object["Endpoints"] as? [String: Any]
            return (endpoints?["docker"] as? [String: Any])?["Host"] as? String
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
