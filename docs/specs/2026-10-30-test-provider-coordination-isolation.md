# Explicit provider coordination isolation for tests

Provider reservations outlive kernel locks. A fixture can intentionally leave an
unverified journal after its fake provider exits. Before test namespace isolation,
that fixture could publish a pointer in the user's shared coordination directory.
Removing the fixture workspace did not remove its separate in-memory-store
journal or shared pointer. Physical-file identity migration correctly preserves
these unresolved legacy reservations conservatively across profiles.

The empty-retry headless scenario reproduces this: a synthetic prior receipt is
followed by an empty fake CLI exit. Local settlement can finish while the provider
stream still has no complete terminal/tool evidence. `settlementToolsStopped`
describes ASTRA's settlement children; it does not override
`stopProof.toolsStopped`. An absent PID is not a tool-stop receipt.

## Namespace ownership

`ProviderSharedStateNamespace` replaces process-name inference:

- The existing test-bundle load-time constructor declares isolation before any
  suite, singleton gate or ownership handoff runs, including direct `swift test`.
- The test wrapper generates a fresh `ASTRA_TEST_PROVIDER_NAMESPACE_ID` UUID for
  every invocation. Helpers inherit that identity independently of their name.
- A UUID selects a private directory under `/private/tmp`; it cannot select an
  arbitrary app coordination path. Malformed or missing inheritance after bundle
  registration fails closed.
- Test overrides must remain temporary and cannot select the shared namespace,
  including symlink aliases. Physical provider resources in test scope must also
  be temporary, preventing an isolated gate from admitting a real user profile.
- App processes without a test declaration keep the existing shared namespace.
  Legacy compatibility, journal authority and release criteria are unchanged.

## Recovery boundary and limits

`ProviderFixtureRecoveryService` is test-only. It creates a new isolated namespace
and captures provenance while constructing a synthetic legacy reservation. It
cannot attach to an existing app coordination directory. The rehearsal requires
exact reference/journal bytes, matching task/owner/execution identities, absent
process identities, a complete bound stop proof, finished settlement, no retained
uncertainty, and both kernel/task leases. It syncs an immutable audit containing
the original pointer and journal before unlinking only the matching pointer.
Retries are idempotent. No journal fields or stop flags are rewritten.

This is not a production repair command. Existing leaked fixtures without
captured provenance or complete tool-stop evidence remain reserved. Do not
weaken legacy conflicts, infer completion from temporary paths, promote settlement
flags into provider proof, or delete locks/journals to bypass admission. Recovering
such an old object requires independently verifiable evidence of its fixture
identity and all execution/tool termination, retained locally for audit.

## Validation

Regression coverage includes bootstrap registration, inherited UUIDs, malformed
inheritance, shared-root aliases, non-temporary provider resources, failed
handoffs, cancellation, the original empty-retry scenario, audited/idempotent
retirement, live processes, incomplete tools/groups/remote evidence, active task
leases, missing/changed provenance and journals, audit failure, and neighboring
unverified reservations. Wrapper tests exercise renamed helpers, failures and
process-group cancellation. Provider scenarios use synthetic homes/configuration
and fake executables; they do not establish live Antigravity authentication or
real-provider success.
