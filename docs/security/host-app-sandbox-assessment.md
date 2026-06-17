# Host App Sandbox Assessment

Status: Phase 5 decision recorded.

## Decision

Do not enable `com.apple.security.app-sandbox` on the ASTRA host app while
runtime Seatbelt wrapping depends on `/usr/bin/sandbox-exec`.

The host bundle currently uses only the Apple Events entitlement in
`script/ASTRA.entitlements`. That is intentional: ASTRA owns a child-process
Seatbelt boundary for provider runtimes, and the host process must be able to
launch `sandbox-exec` to apply that boundary. Flipping on the App Sandbox without
a replacement launcher would risk removing the stronger runtime confinement we
already enforce for agent processes.

## Current Boundary

ASTRA now has two active layers:

- `HostFileAccessBroker` is the host-app file access chokepoint. App-side reads
  are classified as explicit user selections, ASTRA-managed storage, or implicit
  scans. Implicit scans skip privacy-sensitive locations such as Photos, Music,
  app bundles, Mail, Messages, media libraries, and external volumes.
- `ExecutionSandbox` wraps runtime providers in a macOS Seatbelt profile. Strict
  and autonomous runs enforce the read/write allowlist; best-effort runs can
  audit read denials before they become hard failures.

This means the next native macOS hardening step is not "turn on the host App
Sandbox" by itself. The next step is a migration design that keeps runtime
Seatbelt wrapping intact.

## Security-Scoped Bookmarks Path

Security-scoped bookmarks become valuable when the host app is App-Sandboxed or
when ASTRA intentionally persists user-granted folder access across launches.
Before adopting them, ASTRA needs all of these pieces:

- A durable bookmark store for user-selected workspace and input roots.
- Bookmark start/stop access wrapped around every brokered explicit-user path.
- A migration path for existing workspaces that were selected before bookmarks.
- A launcher strategy for runtime sandboxing that still works after the host is
  App-Sandboxed, such as a non-sandboxed privileged/helper launcher or a
  replacement confinement mechanism.
- Manual validation that Photos, Music, Mail, Messages, app bundles, and
  external volumes do not prompt unless selected by the user.

Until those are present, the safer product posture is:

- Keep host App Sandbox off.
- Keep host reads centralized through `HostFileAccessBroker`.
- Keep runtime providers wrapped by ASTRA's Seatbelt profile.
- Keep the entitlement file pinned by tests so the host sandbox is not enabled
  accidentally.
