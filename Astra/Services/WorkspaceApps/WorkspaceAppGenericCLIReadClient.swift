import Foundation

/// Runs a connector READ for an ENABLED capability whose contract implementation declares a `.cli`
/// `readExecution` spec — GENERICALLY, with no per-provider Swift. This is how "create a capability with
/// a CLI tool → enable it → apps read it" works without a hand-written client per connector.
///
/// SECURITY (mirrors the hardened GitHub `gh` path, applied generically):
/// - The COMMAND TEMPLATE is author-controlled (the capability the user created + enabled), NEVER page
///   controlled. The page supplies only declared scalar params.
/// - `command[0]` (the executable) must be a literal (no placeholder) and ABSOLUTE, or a bare name
///   resolved on PATH — never a page value, never a relative path resolved against an inherited cwd.
/// - Params fill WHOLE-TOKEN `{placeholder}` argv elements only (a partial placeholder is a malformed
///   spec → rejected), substituted as argv elements — no shell, never interpolated into a larger token.
/// - Each substituted value is validated: scalar, length-capped, restricted charset, rejected if it could
///   read as a flag (leading `-`).
/// - The process runs with `currentDirectoryURL = workspace.primaryPath` (a cwd-sensitive CLI reads THIS
///   workspace, not ASTRA's launch dir), drained pipes, a hard timeout escalated to SIGKILL, and a stdout
///   byte cap. A non-zero exit or unparseable/non-array output FAILS CLOSED (never "looks like no rows").
/// - Output maps to SCALAR rows only, capped to the requested limit / field count / value size; nested
///   values are dropped. No credentials are read or returned. The binding (appID-scoped, `.mapped`) and
///   the per-app declaration remain the authority — this client only EXECUTES; it relaxes no gate.
///
/// KNOWN follow-up (documented): page-param VALUE constraints (per-param enum/regex/page-fillable schema).
/// Today the placeholder SURFACE is author-declared (the author chooses which params are `{placeholders}`
/// vs hardcoded literal args) and values are charset/flag/length-validated; a schema for value constraints
/// is the next hardening step. Authors should pin sensitive params (repo, account) as LITERAL args.
struct WorkspaceAppGenericCLIReadClient {
    /// Injection seam: returns (stdout, exitCode) for (executablePath, argv, cwd, timeout). Tests
    /// substitute a fake so the suite never spawns a process.
    var runner: any WorkspaceAppCLIReadRunning = WorkspaceAppHardenedCLIRunner()

    static let maxParams = 32
    static let maxValueBytes = 256
    static let maxFieldsPerRow = 64
    static let maxScalarStringBytes = 64 * 1024
    static let timeoutSeconds: TimeInterval = 45
    /// Charset a page-supplied param value may contain (argv, no shell). Excludes shell/quote/control
    /// chars; `-` is allowed INSIDE a value (dates) but a value may not START with `-` (flag injection).
    static let valueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.,:/@-")

    func read(
        execution: WorkspaceAppCapabilityReadExecution,
        operation: String,
        sourceID: String,
        workspacePath: String,
        input: WorkspaceAppSourceResolutionInput
    ) async throws -> [[String: WorkspaceAppStorageValue]] {
        guard execution.transport == .cli else {
            // http/mcp are accepted in the schema but not yet executable — fail CLOSED, never silently fake.
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("\(sourceID): \(execution.transport.rawValue) transport not executable")
        }
        guard let op = execution.operations[operation], !op.command.isEmpty else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(sourceID)
        }
        // Available params: the page's scalar record + the clamped limit (so a template can use {limit}).
        var params = stringParams(input.parameters)
        params["limit"] = String(max(1, input.limit))
        guard params.count <= Self.maxParams else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource(sourceID)
        }
        // The read MUST run in THIS workspace's directory. Fail CLOSED if it is missing — never inherit
        // ASTRA's own launch cwd (a cwd-sensitive CLI like `gh` would otherwise read whatever repo ASTRA
        // was started from, leaking another workspace's data).
        var isDir: ObjCBool = false
        guard !workspacePath.isEmpty,
              FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("\(sourceID): no workspace directory to run in")
        }
        let argv = try Self.resolveArgv(op.command, params: params, sourceID: sourceID)
        guard let exe = Self.resolveExecutable(argv[0]) else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("\(sourceID): executable '\(argv[0])' not found")
        }
        let result = try await runner.run(
            executablePath: exe,
            arguments: Array(argv.dropFirst()),
            currentDirectory: workspacePath,
            timeout: Self.timeoutSeconds
        )
        // Fail CLOSED on a non-zero exit (auth/network/CLI failure must not look like "no rows").
        guard result.exitCode == 0 else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("\(sourceID): command exited \(result.exitCode)")
        }
        return try Self.decodeRows(from: result.stdout, rowsPath: op.rowsPath, limit: max(1, input.limit), sourceID: sourceID)
    }

    private func stringParams(_ values: [String: WorkspaceAppStorageValue]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in values {
            switch value {
            case .text(let s): out[key] = s
            case .integer(let i): out[key] = String(i)
            case .real(let d): out[key] = String(d)
            case .bool(let b): out[key] = b ? "true" : "false"
            case .null: break
            }
        }
        return out
    }

    // MARK: - argv templating (the security boundary)

    /// Build the final argv from the author's template + validated page params. `command[0]` (the
    /// executable) MUST be a literal (no placeholder). Every other token is either a LITERAL (no `{`) or
    /// EXACTLY one whole-token placeholder `{name}`; a partial placeholder is a malformed spec and is
    /// rejected, so substitution is unambiguous and the flag-injection guard is clean. A substituted value
    /// is validated and may not start with `-`.
    static func resolveArgv(_ command: [String], params: [String: String], sourceID: String) throws -> [String] {
        var argv: [String] = []
        for (index, token) in command.enumerated() {
            guard token.contains("{") || token.contains("}") else {
                argv.append(token)   // literal author-controlled arg
                continue
            }
            // The executable (argv[0]) may never be a placeholder — only the manifest/tool picks it.
            guard index != 0 else {
                throw WorkspaceAppSourceResolutionError.unsupportedSource("\(sourceID): executable must be a literal, not '\(token)'")
            }
            guard token.hasPrefix("{"), token.hasSuffix("}"), token.dropFirst().dropLast().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                // partial/embedded placeholder or malformed → reject the whole read (fail-closed)
                throw WorkspaceAppSourceResolutionError.unsupportedSource("\(sourceID): malformed command placeholder '\(token)'")
            }
            let name = String(token.dropFirst().dropLast())
            guard let value = params[name] else {
                throw WorkspaceAppSourceResolutionError.unsupportedSource("\(sourceID): missing parameter '\(name)'")
            }
            guard isSafeValue(value) else {
                throw WorkspaceAppSourceResolutionError.unsupportedSource("\(sourceID): parameter '\(name)' has an unsafe value")
            }
            argv.append(value)
        }
        guard let first = argv.first, !first.isEmpty else {
            throw WorkspaceAppSourceResolutionError.unsupportedSource("\(sourceID): empty command")
        }
        return argv
    }

    /// A page-supplied value is safe to pass as an argv element iff it is within the length cap, drawn
    /// only from the allowed charset, and does NOT start with `-` (so it can never be read as a flag).
    static func isSafeValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxValueBytes, value.first != "-" else { return false }
        return value.unicodeScalars.allSatisfy { valueAllowed.contains($0) }
    }

    /// Resolve `command[0]`: an ABSOLUTE path that is an executable file is used as-is; a bare name (no
    /// `/`) is resolved on the enriched PATH. A RELATIVE path (contains `/` but not absolute) is REJECTED
    /// so the executable can't be resolved against an inherited working directory. Returns nil ⇒ fail-closed.
    static func resolveExecutable(_ name: String) -> String? {
        if name.contains("/") {
            guard name.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: name) else { return nil }
            return name
        }
        let resolved = RuntimePathResolver.detectExecutablePath(named: name)
        return resolved.isEmpty ? nil : resolved
    }

    // MARK: - JSON → scalar rows

    /// Decode `gh`-style `--json` stdout into scalar rows. Navigates `rowsPath` (dot path) to the row
    /// array; each row object contributes only its SCALAR fields (string/number/bool, value-size + field-
    /// count capped) — nested objects/arrays are dropped. Rows are capped to `limit` (a CLI that ignores
    /// `{limit}` can't over-read). Unparseable output or a non-array at `rowsPath` FAILS CLOSED (throws).
    static func decodeRows(from json: String, rowsPath: String?, limit: Int, sourceID: String) throws -> [[String: WorkspaceAppStorageValue]] {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("\(sourceID): command output was not valid JSON")
        }
        var node: Any? = root
        if let path = rowsPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            for key in path.split(separator: ".") {
                node = (node as? [String: Any])?[String(key)]
            }
        }
        guard let array = node as? [[String: Any]] else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("\(sourceID): command output was not a JSON array of rows")
        }
        return array.prefix(max(1, limit)).map { item in
            var row: [String: WorkspaceAppStorageValue] = [:]
            for (key, raw) in item {
                guard row.count < maxFieldsPerRow else { break }
                if let scalar = scalar(from: raw) { row[key] = scalar }
            }
            return row
        }
    }

    private static func scalar(from raw: Any) -> WorkspaceAppStorageValue? {
        if raw is NSNull { return .null }
        if let s = raw as? String { return s.utf8.count <= maxScalarStringBytes ? .text(s) : .text(String(s.prefix(maxScalarStringBytes))) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d.rounded() == d && abs(d) < 9.0e15 { return .integer(n.int64Value) }
            return .real(d)
        }
        if let b = raw as? Bool { return .bool(b) }
        return nil   // nested object/array → dropped
    }
}

/// Outcome of running a capability read command: drained stdout + the process exit code.
struct WorkspaceAppCLIReadResult: Sendable, Equatable {
    var stdout: String
    var exitCode: Int32
}

/// Transport seam for the generic CLI read — the real one spawns a hardened `Process`; tests inject a
/// fake that returns canned stdout so the suite never shells out.
protocol WorkspaceAppCLIReadRunning {
    func run(executablePath: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) async throws -> WorkspaceAppCLIReadResult
}

/// Refuses (no transport configured) — the safe default for tests that don't opt into a fake.
struct WorkspaceAppUnavailableCLIReadRunner: WorkspaceAppCLIReadRunning {
    func run(executablePath: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) async throws -> WorkspaceAppCLIReadResult {
        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("cli: \(executablePath)")
    }
}

/// The real CLI runner: a hardened `Process` invocation (explicit executable, argv array — NO shell,
/// `nullDevice` stdin, cwd pinned to the workspace, stdout byte-capped + both pipes drained to avoid
/// deadlock, hard timeout escalated SIGTERM→SIGKILL) modeled on the proven GitService path. Read-only by
/// intent; the capability author's command does the work.
struct WorkspaceAppHardenedCLIRunner: WorkspaceAppCLIReadRunning {
    static let maxStdoutBytes = 4 * 1024 * 1024

    func run(executablePath: String, arguments: [String], currentDirectory: String?, timeout: TimeInterval) async throws -> WorkspaceAppCLIReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = RuntimeProcessEnvironment.enriched()
        // Require a real working directory — never inherit ASTRA's launch cwd (defense in depth; the
        // caller already validated the workspace dir).
        guard let currentDirectory, FileManager.default.fileExists(atPath: currentDirectory) else {
            throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("cli: no working directory")
        }
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let box = CLIOutputBox(cap: Self.maxStdoutBytes)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { box.append(chunk) }
        }
        // Drain stderr too (prevents a full-pipe deadlock); its content is discarded from rows.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        return try await withThrowingTaskGroup(of: WorkspaceAppCLIReadResult.self) { group in
            group.addTask {
                try process.run()
                let pid = process.processIdentifier
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() > deadline {
                        process.terminate()                                   // SIGTERM
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if process.isRunning { kill(pid, SIGKILL) }           // escalate
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        throw WorkspaceAppSourceResolutionError.capabilityReadUnavailable("cli: timed out")
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                box.append(outPipe.fileHandleForReading.readDataToEndOfFile())   // drain remainder
                return WorkspaceAppCLIReadResult(stdout: box.string(), exitCode: process.terminationStatus)
            }
            let result = try await group.next() ?? WorkspaceAppCLIReadResult(stdout: "", exitCode: -1)
            return result
        }
    }
}

/// Thread-safe, byte-capped accumulator for drained stdout (the readabilityHandler fires on a background
/// queue). Caps total bytes so a CLI emitting unbounded output can't exhaust memory.
private final class CLIOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int
    init(cap: Int) { self.cap = cap }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < cap else { return }
        data.append(chunk.prefix(cap - data.count))
    }
    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}
