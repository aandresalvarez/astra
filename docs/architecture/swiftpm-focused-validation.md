# SwiftPM focused-validation architecture

Date: 2026-07-13

## Context

ASTRA's root Swift package has a large application target and a large aggregate
test target. SwiftPM's `swift test --filter` option filters which tests execute;
it does not prune the test product's compile graph. A cold three-test Git parser
run therefore built the same application and test modules as the full suite.

Measurements were taken on Apple Swift 6.3.3 with a 12-core Apple Silicon host.
Dependencies were resolved first, then `swift package clean` was used before
each cold root-package measurement. Warm measurements immediately repeated the
same command.

| Validation path | Cold | Warm | Observation |
| --- | ---: | ---: | --- |
| `swift test --filter GitStatusParserTests` | 167.92s | 1.59s | Three tests executed in 0.001s after a 1,356-action build. |
| `script/prepush.sh` | 189.78s | 14.72s | 554 selected tests executed in about 12s. |
| `swift test` | 217.73s to failure | 46.04s to failure | The cold build took 172.47s; clean `main` then hit existing concurrent `TaskThreadHistoryReaderTests` and SwiftData failures. |
| `ASTRA_AUTO_TEAM_SIGNING=0 ./script/build_and_run.sh bundle` | 97.75s | 7.25s | The dev-channel build uses a distinct compiler define and correctly owns a separate production-module cache entry. |
| `swift build --target ASTRAGitContracts` | 8.38s | 0.97s | Only four target build actions were required, but the root manifest still resolved unrelated dependencies. |

## Root cause

The former `ASTRAGitContracts` SwiftPM target contained one pure source file,
but its parser tests lived in `ASTRATests`. That created this dependency path:

```text
GitStatusParserTests
  -> ASTRATests (387 Swift files)
  -> ASTRA (586 Swift files)
  -> models, persistence, tools, Markdown, and Sparkle
```

Warm-cache behavior was already effective. Sharing one scratch directory across
worktrees would not change the dependency graph and would introduce concurrent
writer and absolute-source-path risks. Build artifacts therefore remain scoped
to each worktree and package.

## Decision

`ASTRAGitContracts` is a self-contained local Swift package with no package
dependencies. It owns typed Git value contracts and deterministic domain
parsers or policies. It must not import AppKit, SwiftUI, SwiftData, the ASTRA app
module, models, or persistence.

The root app consumes the package's library product. Pure contract tests live
with the package and can run through `script/test_git_contracts.sh` without
building the app. The root package also includes those same test sources in its
aggregate test product so `swift test --no-parallel` remains comprehensive.
App adapters, subprocess integration, persistence, and UI tests remain in the
root package.

Architecture fitness tests are independently runnable through
`script/test_architecture.sh`. The validation planner uses these lanes:

- Git contract test-only changes: architecture fitness plus the Git package
  tests, without compiling the app.
- Git contract production source or package-manifest changes: the isolated Git
  package tests plus the root focused suites, which compile the ASTRA consumer
  and catch public-API drift.
- Architecture-test-only changes: the standalone architecture package.
- Any root application, package-manifest, script, or mixed change: the
  standalone checks plus the existing root focused suites.
- A release/tag checkout with `ASTRA_RELEASE_GATE=1`: the root focused suites
  regardless of its diff, preserving the unconditional release-number,
  update, and packaging gates before signing.

This boundary gives future typed Git publication domain logic a fast, testable
home without copying unmerged publication code or creating test-only production
abstractions.

## Results

The isolated Git-contract lane reduced cold focused validation from 167.92s to
6.53s (about 26x faster) and remained cache-fast at 0.69s warm. The complete
contract-test-only pre-push route (architecture fitness, contract tests, and
routing-script tests) took 24.93s cold and 12.32s warm, compared with the former
189.78s and 14.72s pre-push measurements. Production contract and manifest
changes intentionally retain the root consumer compile gate. Running the same
four tests through the root package after this change still required 1,282 build
actions and 167.28s cold, confirming that package isolation, rather than test
filter selection, is what removes the large compile graph.

On the final rebased head, the supported serial full suite passed 5,321 tests in
505 suites. Its cold root build took 271.77s and test execution took 308.37s.
The development app bundled and launched
successfully. Its bundle timings were 116.87s cold and 12.13s warm; this decision
does not claim a bundle-speed improvement because the development-channel app
still correctly compiles the complete production graph with its channel-specific
build define.
