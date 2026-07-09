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
