enum RemoteWorkspacePromptGuidance {
    /// Keeps remote work durable without turning a provider shell call into the scheduler.
    static let longRunningCommandContract = """
    Long-running remote command contract: only launch multi-hour remote work when a reviewed workspace capability explicitly authorizes remote execution. Launch it detached with file-backed logs or status files so it survives SSH disconnects. Keep each SSH or Bash tool call bounded to one launch or one status read; never hold a tool call open with `sleep` or an internal polling loop. Do not replace a long wait with rapid repeated checks. Return the durable external handle, latest verified status, and recovery paths, then end the provider turn. Do not claim ASTRA will continue monitoring unless an explicit ASTRA operation-monitoring capability registered the job.
    """
}
