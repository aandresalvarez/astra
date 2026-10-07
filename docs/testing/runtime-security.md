# Runtime-Security Tests

Run the focused runtime-security regressions with:

```bash
script/runtime_security_tests.sh
```

The command covers connector launch preflight, launch-resource projection and
policy exposure, sandbox settings and kernel enforcement, process-runner
integration, run permission manifests, permission actions, and sandbox-denial
diagnostics. It uses temporary files and test doubles; it does not read ASTRA
production workspaces, App Support data, or credentials.

## Test Pyramid

1. **Focused runtime-security command:** Run during development and incident
   repair. It lists the SwiftPM tests first, requires every declared suite to
   match at least one exact test identifier, and then runs the set serially.
2. **Focused repository checks:** Run `script/prepush.sh` before publishing.
   This adds architecture, persistence, runtime-adapter, and path-selected test
   coverage plus whitespace checks.
3. **Full suite:** Run `swift test --no-parallel` before merging shared runtime,
   persistence, model, package, or release changes. The focused command is a
   fast feedback loop, not a substitute for the full suite.

The inventory check is intentional: SwiftPM can exit successfully when a
`--filter` matches zero tests. A renamed or removed suite must therefore fail
before the regression command starts.

## Incident Fixtures

Regression fixtures derived from incidents must preserve the real command
grammar that reached the failing boundary. Keep shell prefixes, absolute
executable paths, quoting, argument order, placeholders such as SSH `%h` and
`%p`, and the original stderr shape when those details affect parsing or
resource discovery. Replace secrets, account names, hosts, and unrelated paths
with deterministic test values, but do not simplify the command into a form
that bypasses the production parser. Assert the durable decision or diagnostic,
not incidental log formatting.

Validate changes to the entrypoint itself with:

```bash
script/runtime_security_tests_tests.sh
bash -n script/runtime_security_tests.sh script/runtime_security_tests_tests.sh
```

## Policy level × runtime contract

`Tests/AgentPolicyRuntimeMatrixTests.swift` pins the whole runtime × level grid:
only Auto renders a provider's bypass flags, Ask and the legacy presets never do
and keep each provider's own sandbox on, and a new runtime fails the suite until
its Auto flags are declared. Per-runtime flag builders are still tested in their
own suites; the matrix is what stops a shared change from moving a level in a
runtime nobody was looking at.

The same suite pins Ask's command semantics on every runtime: destructive and
publishing commands ask rather than being refused (`sudo` stays denied), and
no runtime pre-grants a local tool in Ask.

## Policy level × external action contract

`Tests/PermissionLevelActionMatrixTests.swift` pins `ExternalActionPolicy` for
every level and every external action ASTRA performs or owns: Auto performs and
records, Ask and Custom ask, and a new action kind fails the suite until it is
placed. The behaviour behind each answer has its own pins:

- connector credentials — `ConnectorPreflightServiceTests` (launch gate) and
  `BrokeredCredentialLevelTests` (run-boundary offer);
- Jira writes — `ConnectorMutationAutoSendTests`;
- GitHub review posting — the Auto cases in `GitHubReviewPublicationTests`;
- commands the agent ran itself — `AgentExternalActionObserverTests`;
- the chat record — `ExternalActionRecordTests`.

Each of these was mutation-checked: removing the rule it pins makes it fail.

The unit tests never run a real CLI, so they cannot see a provider dropping a
flag. Run this locally after upgrading any provider CLI:

```bash
script/check_provider_cli_flags.sh
```

It checks that each flag ASTRA passes is still in the installed CLI's `--help`
(and, for OpenCode's undocumented `--dangerously-skip-permissions` alias, that the
parser still accepts it). CLIs that are not installed are skipped.
