import Foundation

enum RuntimePathResolver {
    static let usrBin = "/usr/bin"
    static let homebrewBin = "/opt/homebrew/bin"
    static let usrLocalBin = "/usr/local/bin"
    static let googleCloudSDKBin = "\(NSHomeDirectory())/google-cloud-sdk/bin"
    static let userLocalBin = "\(NSHomeDirectory())/.local/bin"
    static let astraToolsPath = "\(NSHomeDirectory())/.astra/tools"

    static let npmGlobalBin = "\(NSHomeDirectory())/.npm-global/bin"

    static var shellPathSuffix: String {
        [
            usrLocalBin,
            homebrewBin,
            googleCloudSDKBin,
            userLocalBin,
            npmGlobalBin
        ].joined(separator: ":")
    }

    static var agentPathSuffix: String {
        "\(shellPathSuffix):\(astraToolsPath)"
    }

    static func detectExecutablePath(
        named executableName: String,
        candidates: [String] = [],
        fallback: String = "",
        fileManager: FileManager = .default
    ) -> String {
        let executableName = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executableName.isEmpty else { return fallback }

        if executableName.contains("/") {
            let explicitPath = (executableName as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: explicitPath) ? explicitPath : fallback
        }

        let searchCandidates = candidates.isEmpty
            ? defaultExecutableCandidates(named: executableName)
            : candidates
        for path in searchCandidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(executableName).path }

        for path in pathCandidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        return fallback
    }

    static func detectClaudePath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "claude",
            candidates: [
                "\(userLocalBin)/claude",
                "\(usrLocalBin)/claude",
                "\(homebrewBin)/claude",
                "\(NSHomeDirectory())/.npm-global/bin/claude"
            ],
            fallback: "\(usrLocalBin)/claude",
            fileManager: fileManager
        )
    }

    static func detectCopilotPath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "copilot",
            candidates: [
                "\(userLocalBin)/copilot",
                "\(homebrewBin)/copilot",
                "\(usrLocalBin)/copilot",
                "\(NSHomeDirectory())/.npm-global/bin/copilot"
            ],
            fallback: "",
            fileManager: fileManager
        )
    }

    static func detectAntigravityPath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "agy",
            candidates: [
                "\(userLocalBin)/agy",
                "\(homebrewBin)/agy",
                "\(usrLocalBin)/agy",
                "\(NSHomeDirectory())/.npm-global/bin/agy"
            ],
            fallback: "",
            fileManager: fileManager
        )
    }

    static func detectCodexPath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "codex",
            candidates: [
                "\(userLocalBin)/codex",
                "\(homebrewBin)/codex",
                "\(usrLocalBin)/codex",
                "\(NSHomeDirectory())/.npm-global/bin/codex"
            ],
            fallback: "",
            fileManager: fileManager
        )
    }

    static func detectCursorPath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "cursor-agent",
            candidates: [
                "\(userLocalBin)/cursor-agent",
                "\(homebrewBin)/cursor-agent",
                "\(usrLocalBin)/cursor-agent",
                "\(NSHomeDirectory())/.npm-global/bin/cursor-agent"
            ],
            fallback: "",
            fileManager: fileManager
        )
    }

    static func detectOpenCodePath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "opencode",
            candidates: [
                "\(userLocalBin)/opencode",
                "\(homebrewBin)/opencode",
                "\(usrLocalBin)/opencode",
                "\(NSHomeDirectory())/.npm-global/bin/opencode"
            ],
            fallback: "",
            fileManager: fileManager
        )
    }

    /// Resolves Docker independently of the GUI app's inherited PATH.
    /// Docker Desktop can expose the CLI through a system link or only inside
    /// its application bundle, so both installation forms are authoritative.
    static func detectDockerPath(fileManager: FileManager = .default) -> String {
        detectExecutablePath(
            named: "docker",
            candidates: [
                "\(usrLocalBin)/docker",
                "\(homebrewBin)/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"
            ],
            fileManager: fileManager
        )
    }

    private static func defaultExecutableCandidates(named executableName: String) -> [String] {
        defaultExecutableSearchDirectories.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent(executableName)
                .path
        }
    }

    static let defaultExecutableSearchDirectories: [String] = [
        userLocalBin,
        homebrewBin,
        usrLocalBin,
        googleCloudSDKBin,
        npmGlobalBin,
        astraToolsPath,
        usrBin
    ]
}

// MARK: - Centralized process environment

/// Builds a rich process environment for running CLI tools.
///
/// macOS apps launched from Finder receive a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`).
/// CLI tools that are shell scripts (Node.js, Python, etc.) need their interpreter on PATH.
/// This utility probes the user's login shell once at first use to discover the full PATH
/// (including NVM, Volta, pyenv, etc.), caches the result, and merges it with known
/// well-known directories as a hardcoded fallback.
///
/// Use `enriched()` for every child process — readiness checks, task launches, and utility probes.
enum RuntimeProcessEnvironment {
    /// Well-known directories always included, even if the shell probe fails.
    static let wellKnownDirectories: [String] = [
        RuntimePathResolver.homebrewBin,
        RuntimePathResolver.usrLocalBin,
        RuntimePathResolver.googleCloudSDKBin,
        RuntimePathResolver.userLocalBin,
        RuntimePathResolver.npmGlobalBin,
        RuntimePathResolver.astraToolsPath,
    ]

    private static let shellPATHLock = NSLock()
    nonisolated(unsafe) private static var cachedShellPATH: [String]?
    nonisolated(unsafe) private static var isProbingShellPATH = false

    /// Builds a process environment with a rich PATH suitable for running CLI tools.
    ///
    /// - Parameters:
    ///   - additionalPaths: Extra directories to prepend (e.g. browser shim dir).
    ///   - extraVariables: Additional env vars to merge (e.g. Vertex routing flags).
    /// - Returns: A complete environment dictionary based on the current process environment.
    static func enriched(
        additionalPaths: [String] = [],
        extraVariables: [String: String] = [:]
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        var pathParts: [String] = []
        pathParts.append(contentsOf: additionalPaths)
        pathParts.append(contentsOf: shellPATHForCurrentThread())
        pathParts.append(contentsOf: wellKnownDirectories)
        pathParts.append(env["PATH"] ?? "")

        env["PATH"] = deduplicatedPATH(pathParts)

        for (key, value) in extraVariables {
            env[key] = value
        }

        return env
    }

    static func shouldProbeLoginShellSynchronously(
        isMainThread: Bool = Thread.isMainThread,
        hasCachedShellPATH: Bool
    ) -> Bool {
        !isMainThread && !hasCachedShellPATH
    }

    private static func shellPATHForCurrentThread() -> [String] {
        shellPATHLock.lock()
        if let cachedShellPATH {
            shellPATHLock.unlock()
            return cachedShellPATH
        }
        let shouldProbeSynchronously = shouldProbeLoginShellSynchronously(
            hasCachedShellPATH: cachedShellPATH != nil
        )
        shellPATHLock.unlock()

        if shouldProbeSynchronously {
            let probed = probeLoginShellPATH() ?? []
            shellPATHLock.lock()
            cachedShellPATH = probed
            shellPATHLock.unlock()
            return probed
        }

        startShellPATHProbeIfNeeded()
        return []
    }

    private static func startShellPATHProbeIfNeeded() {
        shellPATHLock.lock()
        if cachedShellPATH != nil || isProbingShellPATH {
            shellPATHLock.unlock()
            return
        }
        isProbingShellPATH = true
        shellPATHLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let probed = probeLoginShellPATH() ?? []
            shellPATHLock.lock()
            cachedShellPATH = probed
            isProbingShellPATH = false
            shellPATHLock.unlock()
        }
    }

    /// Deduplicates PATH components while preserving order.
    static func deduplicatedPATH(_ parts: [String]) -> String {
        var seen = Set<String>()
        var result: [String] = []
        let components = parts
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty }
        for component in components {
            if seen.insert(component).inserted {
                result.append(component)
            }
        }
        return result.joined(separator: ":")
    }

    /// Probes the user's login shell to discover their full PATH.
    ///
    /// Runs `$SHELL -l -c 'echo $PATH'` with a 3-second timeout.
    /// Returns the PATH components, or nil if the probe fails.
    private static func probeLoginShellPATH() -> [String]? {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"],
              !shell.isEmpty else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "echo $PATH"]
        process.environment = ["HOME": NSHomeDirectory()]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = DispatchTime.now() + .seconds(3)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            completed.signal()
        }

        if completed.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        let components = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        return components.isEmpty ? nil : components
    }
}
