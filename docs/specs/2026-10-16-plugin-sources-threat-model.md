# Plugin sources: threat model (Plugins 2.0 R5)

Status: draft for review, 2026-10-16. Parent spec:
`docs/specs/2026-10-15-plugins-2-capability-redesign.md` (phase R5).

## What a source is

A plugin source is a place ASTRA lists plugins from besides its built-ins: a
git repository (https or ssh) or a local folder, holding a marketplace file
(`.claude-plugin/marketplace.json` or `astra-marketplace.json`) whose entries
point at plugin directories inside it. Listing a source shows its plugins on
the Plugins screen as Available; adding one goes through the same review,
approval and Add as an imported plugin file.

The first build of sources (phase 3, superseded) drew about eight P1 review
findings, each a different way untrusted input reached a trusted place:
secrets in URLs, ID and file name collisions, lost provenance, duplicate IDs,
rollback to older versions, silently dropped malformed files, clone
replacement that deleted the fallback first, and asset paths outside the
plugin. This document names the assets and trust boundaries first, then the
rule each threat gets, so the implementation is checked against rules rather
than findings.

## Assets

1. **Secrets**: Keychain credentials of accounts, plugin secret settings, git
   credentials (helper or SSH agent).
2. **The host**: commands ASTRA runs (checks, repairs, local tools, stdio MCP
   servers) and files it writes.
3. **Identity**: a plugin ID, a component ID, the digest an approval is bound
   to, the source a plugin came from.
4. **The library**: installed plugin definitions every workspace runs from.
5. **The person's attention**: what the screen claims a plugin is and does.

## Trust boundaries

- Everything inside a source (marketplace file, manifests, skill text, MCP
  files, icons) is **untrusted** until a person reviews and approves a
  specific digest. Approval covers that digest only.
- The source **location** is typed by the person but is still input: it is
  stored, displayed and handed to git.
- **git** runs on the host with the person's credentials: invoking it is a
  host action, and what it fetches can try to execute during the fetch.
- A **folder** source can change between listing, review and install.

## Threats and rules

| # | Threat | Rule (what the implementation must do) | Test |
| --- | --- | --- | --- |
| T1 | A token embedded in a source URL is stored in `sources.json`, shown on screen and written to logs | Accept only `https://host/path`, `ssh://[user@]host/path`, `git@host:path`, `owner/repo` (GitHub) or an absolute folder path. Refuse a URL with a password, query, fragment, or an https user; refuse `file://`, `ext::` and any other scheme. Private repositories authenticate through git's credential helper or SSH agent only. Locations are logged by source ID, never verbatim | Each refused form; a stored source never contains `@` before the host in https |
| T2 | Argument injection into git (`-uhook`, `--upload-pack=…`) | A location never starts with `-`; git is invoked with an argument array (no shell) and `--` before the location | `-c…` and `--upload-pack` locations refused; the argument vector ends `-- <location> <dir>` |
| T3 | Code runs during fetch (hooks, filters, fsmonitor, LFS smudge, submodules, `ext` transport), including a filter driver or hook the person's own git configuration defines, which a source can select through `.gitattributes` | Neither the system nor the person's git configuration is read (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`), so no filter driver, hook path or alias of theirs applies. `git clone --depth 1 --no-checkout --no-recurse-submodules`, then `git checkout` once the tree is measured (T11), after writing `$GIT_DIR/info/attributes` as `* -text -eol -crlf -ident -filter -working-tree-encoding` (that file outranks every in-tree `.gitattributes`, whatever its pattern, macro or nesting, on every git version; `--attr-source` would need Git 2.41, newer than some macOS 14 installs), with `core.attributesFile=/dev/null` and `GIT_ATTR_NOSYSTEM=1`, so no `ident`, `working-tree-encoding`, filter or eol attribute from the repository's `.gitattributes`, the person's `~/.config/git/attributes` or the system file changes what is written and the files are the size measured, each with `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false -c credential.helper=osxkeychain -c credential.interactive=never`, `GIT_TERMINAL_PROMPT=0`, a minimal environment, and a timeout. Credentials come only from the system keychain helper or the SSH agent. ssh reads no configuration either: `GIT_SSH_COMMAND` is `/usr/bin/ssh -F /dev/null` with `ProxyCommand=none`, `ProxyJump=none`, `PermitLocalCommand=no`, forwarding and control sockets off, `BatchMode=yes` and `IdentityFile=none`, so a `ProxyCommand`, `Match exec` or `LocalCommand` in `~/.ssh/config` or the system file never runs and no key file is read from disk; only the agent's keys authenticate. Every option is one Git 2.39 accepts; `credential.interactive` is ignored before Git 2.47, where `GIT_TERMINAL_PROMPT=0` with no askpass still prevents prompts. Host keys are verified without a prompt: `StrictHostKeyChecking=accept-new` with ASTRA's own `PluginSources/known_hosts` first and the person's `~/.ssh/known_hosts` second, so a host seen for the first time is recorded in ASTRA's file (the person's is read, never written) and a known host whose key changed is refused on every later fetch. ASTRA only reads files from the checkout | The fixed argument and environment set; the effective ssh configuration (`ssh -G`) has no proxy or local command and its identity file list is exactly `none`; the clone, ls-tree and checkout options are all ones Git 2.39 documents; a repository using `*.txt ident`, an `[attr]` macro, `eol=crlf`, `working-tree-encoding` and nested `.gitattributes` checks out byte-identical; a hook the user's git config names does not run; a non-LFS filter driver in the user's global config, selected by the repository's `.gitattributes`, does not run |
| T4 | A marketplace entry or asset path escapes the plugin directory (`..`, absolute paths, symlinks) | Every path a source names is resolved inside the source root and inside its plugin directory after resolving symlinks; anything else is refused with a visible problem on that entry | `../`, absolute, and symlink-out entries are refused |
| T5 | A source plugin claims a built-in's ID or another source's plugin ID, to replace it or take over its accounts and settings | A plugin keeps the source it was installed from (`sourceMetadata`: kind, location ID, plugin path). A source plugin whose ID is a built-in's is refused. One whose ID is installed from elsewhere (a file, another source) is listed as a conflict and offers no Add or Update | Built-in ID refused; cross-source ID shows conflict, no Add |
| T6 | Two entries in one marketplace share an ID, or a plugin declares two components with one identity | Duplicate plugin IDs in one source: both are listed with a problem and neither is offered. Component identities are validated as for any package (R3) | Duplicate IDs flagged; duplicate component refused |
| T7 | Rollback: a source serves an older version to replace a newer installed one | An Update is offered only for a strictly greater semantic version from the plugin's own source. Equal version with a different digest is shown as changed and needs review; lower is never offered | Lower and equal versions are not offered as Update |
| T8 | What was reviewed is not what gets installed (folder edited, clone refetched) | Review shows the digest; Add installs the exact package bytes that were reviewed, copied into the library. The runtime never reads a source checkout | Changing the folder after review makes Add refuse with "changed since review" |
| T9 | A source plugin's checks or repairs run host commands | Checks from a source plugin are not run (shown as "not checked") until the read-only rule (parent spec, Health and repair) is enforced against them. Terminal repairs must be a plain call to the component's own CLI, exactly as the check declares it, with no line breaks, control characters or shell metacharacters (`;|&` `` ` `` `$<>()` are refused through `LocalToolSecurityPolicy`, `RepairAction.isSafeTerminalCommand`) (R0). Nothing a source declares runs without a person's click | A source plugin's `exec` check is never invoked; `gcloud auth login; rm -rf ~` and a lookalike path are refused as repairs |
| T10 | MCP servers and local tools from sources run arbitrary commands or reach plaintext endpoints | The package validator's rules apply unchanged: `LocalToolSecurityPolicy` for commands and default arguments, https (or loopback http) for remote MCP, declared environment keys only; unsupported headers are reported, not dropped | Unsafe command, http remote and undeclared env refused |
| T11 | Malformed or oversized input is dropped silently or exhausts memory or disk (one huge blob, or many files the marketplace never names) | The download is watched and cancelled past 64 MB, and objects over 1 MB are streamed rather than inflated in memory (`core.bigFileThreshold=1m`), so a small pack of a huge compressible blob can't exhaust memory before the tree is measured (128 MiB zero blob: 139 MB peak without, 3.6 MB with); the clone has no checkout until `git ls-tree -r -l` shows the tip's files total at most 64 MB and 10,000 files; past either, the fetch is refused and its staging folder removed, keeping the previous checkout. Files over a size limit (marketplace 256 KB, manifest 512 KB, skill text 256 KB, icon 512 KB), more than 200 entries, or undecodable files are listed with a problem, never skipped silently. An unreadable `sources.json` is reported and never overwritten | Each limit; an oversized repository is refused before any checkout and leaves nothing behind; a corrupt `sources.json` survives a save attempt |
| T12 | A refetch fails halfway and leaves no usable checkout | Fetch into a temporary directory, then replace the previous checkout atomically; the previous one stays until the new one is complete | A failed fetch keeps the previous checkout |
| T13 | Removing a source while it is fetching, or two fetches of one source | Operations on one source are serialized; Remove waits for, or cancels, a running fetch | Remove during fetch leaves no orphan directory |
| T14 | A source misrepresents itself on screen (name, author, icon) | The screen shows the source's location (sanitized, T1) next to every plugin from it, and the review sheet shows the digest; names from the source are display text only | The row shows the source |

## Out of scope for R5

- Signature verification of sources or plugins (no signing infrastructure).
- Sandboxing the git process beyond T3 (a dedicated helper is future work).
- Plugins whose marketplace `source` is not a path inside the repository
  (another git URL, a package registry): listed as unsupported.

## Exit criteria

Every row's test passes; a full `swift test` passes; adding a plugin from a
local folder source and from a git source (a local bare repository in tests)
installs exactly the reviewed digest, and its later Update follows T7.

## How R5 was built (2026-10-16)

R5 is on `plugins2-r5`, stacked on R4. Each row above has a test in
`PluginSourcesTests`, named by its row.

- **Where the rules live.** `PluginSource.make` (T1, T2),
  `PluginSourceFetcher` (T2, T3, T12), `BrokeredPluginDirectory` and
  `PluginSourcePluginReader` (T4, T11), `PluginSourceCatalog` (T5–T10,
  T14), `PluginSourceStore` (T11), `PluginSourceCoordinator` (T13).
- **Reading.** Every plugin is read through a reader scoped to its own
  directory (`PluginDirectoryReading.scoped(to:)`), so a symlink can't
  reach a sibling plugin either. Only regular files are read, so a FIFO
  can't hang a listing. A source plugin's asset icon is replaced by its
  symbol and reported, so no asset path is read or copied.
- **Checks (T9).** A source plugin's setup checks are stripped from the
  package at listing time and reported as "N setup checks (not run)", so
  nothing it declares can run. Its digest is that of the stripped package.
- **Review and import (T8).** The review sheet shows the source, the digest,
  what isn't brought over, and `worksOn`. Import re-lists the source,
  refuses when the digest changed or a rule now refuses it, and installs
  the reviewed copy. Adding it to a workspace is then the row's Add, as for
  an imported file.
- **Provenance (T5).** The library files every installed plugin as local
  on load (`CapabilityGovernanceNormalizer`), so a file on disk can never
  claim a source. Where an installed plugin came from is a separate record,
  `PluginSources/provenance.json`, keyed by plugin ID with the content
  digest of the copy the source installed
  (`PluginSourceCatalog.contentDigest`). A record whose digest no longer
  matches the installed copy, say after a file was imported over it, does
  not count, so only that source's own copy is "from" it. An import
  journals the record before the library write: `beginProvenance` keeps the
  copy the record names and adds the incoming one as `pendingDigest`, and
  only after the library write does `recordProvenance` settle on the new
  digest. An exit between the two leaves whichever copy the library holds
  recognised as the source's own, so it can still be updated from there.
  Digest matching alone is not enough when the same bytes come back by
  another route, so a local install also forgets the record: Remove drops it
  after the uninstall, and a file import or Create drops it for the plugin
  it installs (`PluginSourceStore.forgetProvenance`, through
  `CapabilityCatalogActionService.forgetSource`). A removed source plugin
  imported again from a file is local, with no updates from the old source
  and no conflict shown to other sources.
- **Updates (T7).** Shown in the Sources section: "Review update" for a
  greater version, "Changed: review" for the same version with another
  digest. The import replaces only the copy installed from the same source.
- **Testing transport.** The fetcher's allowed transports are a property
  (https and ssh). Only the tests add `file`, to fetch a local bare
  repository as the exit criteria ask.
