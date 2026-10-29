# Shared provider configuration: physical identity and legacy reservations

Antigravity tasks and utilities modify the same settings file. Its reservation
now identifies the resolved location, rather than the spelling of the provider
home. `/tmp` and `/private/tmp`, directory aliases, and file symlinks share one
versioned key. Creating or atomically replacing settings does not change it.
Resolution respects symlinks before `..` and the case sensitivity of each
parent volume. Hard-linked, special, dangling or unresolvable configuration
paths fail closed with an explanation.

The runner pins the effective provider home before waiting, including scoped
HOME overrides. An inherited home stays separate from an explicitly configured
home: resolving its identity never grants write access to the whole home or
adds it to the utility read allowlist. After admission the runner validates
the settings destination before mutation, after asynchronous supervision baseline
collection and immediately before spawning. Final validation runs inside failed
spawn cleanup so rejection also releases stream and termination callbacks.
Settings writes use the reserved target, preserving file symlinks.
Utilities use the same identity, gate and validation. A changed destination
requires a fresh admission; it never silently transfers the reservation.

## Authority and compatibility

The execution journal remains the release authority. The new key is persisted
through the existing owner; context, request accounting and remaining limits
are not reset. Kernel locks serialize live execution, and sidecars point to
the durable journal across stores and restarts.

Existing lock files, sidecars and journals are not renamed, deleted or migrated.
An unreleased legacy claim lacks captured physical identity: resolving its path
today cannot prove which target it originally reserved. Such a claim blocks
new Antigravity admission conservatively, including retained claims. Anonymous
legacy kernel locks are waited on without assuming which resource they own.
Cancellation or expiration does not release the previous execution.

A legacy pointer with a missing or unreadable journal is an explicit migration
block. Absence is not termination proof. Reconcile it using independent execution
and tool-stop evidence before retrying; do not delete it merely because its path
resembles a test fixture. Old test runs used the production coordination root,
so affected installations may need this reconciliation before adopting the new
identity. SwiftPM tests now use a private process namespace.

New versioned pointers only fence their own resource, so a missing journal for
one new profile cannot block a different new profile. Legacy compatibility
inspection runs outside the UI actor and checks cancellation and its deadline.

Do not run an older ASTRA binary alongside the upgraded version. An old binary
can invent a previously unknown alias after compatibility inspection; it does
not participate in the new identity protocol. Existing reservations are
preserved, but this is not a guarantee for future launches by mixed versions.

## Verification

`ProviderSharedStateIdentityTests` covers aliases before/after creation,
filesystem resolution order, mixed volume sensitivity, atomic replacement,
hard/dangling links, independent gates, independent profiles, legacy contention,
cancelled waits, retargeted settings, symlink-safe writes and task/utility parity.
`ProviderSharedStateMigrationTests` covers current/retained legacy claims,
cross-store cold admission, missing legacy authority, unchanged pointers and
independence from missing versioned journals. Both suites are selected by the
focused pre-push mapping. `ProviderSharedStateLaunchTests` covers deterministic
retargeting during baseline collection, zero launch/accounting on rejection,
inherited versus explicit home permissions, scoped HOME pinning, utility key
propagation and final utility validation. Process regressions verify callback
cleanup when final validation rejects a launch.

The development machine's old QA namespace was reconciled separately with the
owner's authorization: 1,343 pointers to removed test fixtures and 14 pointers
from named QA installations were backed up and retired. The latter's surviving
execution chains were checked against stop receipts and a subsequent host reboot,
with remote work excluded and no active task processes. Journals and stable lock
files were preserved. This administrative cleanup is not an application migration
rule and does not authorize deleting real or uncertain reservations elsewhere.

Native QA uses the opt-in `ProviderReservationAppFixtureTests` to seed untouched
drafts in a new store. It fabricates no runs or execution receipts. Run the
development bundle with an isolated macOS user-home override and a provider
home inside that QA tree so store, workspaces and coordination locks all remain
private. Real-provider completion and cancellation must be observed in the app
and checked against its persisted execution journal. This does not certify
that an existing production coordination namespace is free of migration blocks.
