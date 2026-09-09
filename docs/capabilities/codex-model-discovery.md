# Codex model discovery

ASTRA obtains Codex picker models from the configured CLI using a short-lived
`codex app-server --stdio` process. It completes `initialize`, sends
`initialized`, then requests every `model/list` page. It never creates a thread
or starts a turn. The configured Codex home is passed as `CODEX_HOME`, matching
the provider configuration used for execution.

The provider catalog is the source for model IDs, display metadata, recommended
default, reasoning options, and input modalities. `RuntimeModelAvailability`
owns the derived cache; Codex metadata is an optional field so older snapshots
and other providers remain readable. The recommended default leads the cached
list. Explicit task selections are preserved, including models absent from the
visible picker catalog. The catalog is not an execution allowlist.

Previously the Codex readiness check persisted bundled choices as authoritative
without querying the provider. That both hid new models and caused explicit
choices absent from the static list to resolve to an older default. Legacy
Codex snapshots therefore cannot constrain explicit model selections either.

Discovery runs through the existing runtime readiness/refresh workflow. A
successful complete catalog replaces the cache. Timeout, cancellation, invalid
responses, pagination loops, empty catalogs, and startup failures retain the
last successful cache and surface a readiness warning. Bundled choices serve
only as offline suggestions. The probe bounds total response bytes, pages, and
elapsed time and terminates its process on every exit path.

Regression coverage:

```sh
swift test --filter 'CodexModelAvailabilityServiceTests|CodexCLIRuntimeTests'
```

Optional read-only verification against an installed, authenticated CLI:

```sh
RUN_CODEX_MODEL_DISCOVERY_SMOKE=1 swift test --filter CodexModelAvailabilityServiceTests
```

Protocol reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server#list-models-modellist).
