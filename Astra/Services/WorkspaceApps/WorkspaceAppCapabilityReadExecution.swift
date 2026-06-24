import Foundation

/// How a connector READ is executed GENERICALLY, without per-provider Swift. A contract implementation
/// contributed by an ENABLED capability (derived from its CLI tool) carries this spec; the generic read
/// client (`WorkspaceAppGenericCLIReadClient`) runs it. The built-in native clients (BigQuery/REDCap/
/// GitHub) leave `readExecution` nil and keep their hand-written fast paths — so this is purely additive
/// and closes the "enable a capability → apps can read it, zero new Swift" gap for the CLI transport.
///
/// Security model (mirrors the hardened GitHub `gh` path): the COMMAND TEMPLATE is author-controlled
/// (the user who created + enabled the capability), never page-controlled. The page (via `astra.read`)
/// supplies only declared scalar params, substituted into `{placeholder}` argv TOKENS — validated, never
/// shell-interpolated (argv array, no shell), and rejected if they could read as a flag. Output is parsed
/// as JSON and mapped to SCALAR rows only.
struct WorkspaceAppCapabilityReadExecution: Codable, Sendable, Equatable {
    /// Only `.cli` is executable today; `.http`/`.mcp` are accepted in the schema but the generic client
    /// fails CLOSED for them (honest "transport not yet executable") until implemented.
    var transport: WorkspaceAppContractTransport
    /// operation name → how to run it. The source's `operation` (or the requirement's first op) selects one.
    var operations: [String: Operation]

    struct Operation: Codable, Sendable, Equatable {
        /// argv template: `command[0]` is the executable (resolved on PATH if not absolute); the rest are
        /// literal args plus `{param}` placeholder TOKENS filled from the page's validated scalar params.
        var command: [String]
        /// Dot path into the JSON stdout to the ARRAY of row objects (e.g. "data.items"); nil ⇒ stdout is
        /// already a top-level array. Each row object's scalar fields become a row; nested values are dropped.
        var rowsPath: String?
    }
}
