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
| T3 | Code runs during fetch (hooks, filters, fsmonitor, LFS smudge, submodules, `ext` transport) | `git clone --depth 1 --no-recurse-submodules` with `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false -c credential.interactive=never`, `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, a minimal environment, and a timeout. ASTRA only reads files from the checkout | The fixed argument and environment set; a repository with a post-checkout hook does not run it |
| T4 | A marketplace entry or asset path escapes the plugin directory (`..`, absolute paths, symlinks) | Every path a source names is resolved inside the source root and inside its plugin directory after resolving symlinks; anything else is refused with a visible problem on that entry | `../`, absolute, and symlink-out entries are refused |
| T5 | A source plugin claims a built-in's ID or another source's plugin ID, to replace it or take over its accounts and settings | A plugin keeps the source it was installed from (`sourceMetadata`: kind, location ID, plugin path). A source plugin whose ID is a built-in's is refused. One whose ID is installed from elsewhere (a file, another source) is listed as a conflict and offers no Add or Update | Built-in ID refused; cross-source ID shows conflict, no Add |
| T6 | Two entries in one marketplace share an ID, or a plugin declares two components with one identity | Duplicate plugin IDs in one source: both are listed with a problem and neither is offered. Component identities are validated as for any package (R3) | Duplicate IDs flagged; duplicate component refused |
| T7 | Rollback: a source serves an older version to replace a newer installed one | An Update is offered only for a strictly greater semantic version from the plugin's own source. Equal version with a different digest is shown as changed and needs review; lower is never offered | Lower and equal versions are not offered as Update |
| T8 | What was reviewed is not what gets installed (folder edited, clone refetched) | Review shows the digest; Add installs the exact package bytes that were reviewed, copied into the library. The runtime never reads a source checkout | Changing the folder after review makes Add refuse with "changed since review" |
| T9 | A source plugin's checks or repairs run host commands | Checks from a source plugin are not run (shown as "not checked") until the read-only rule (parent spec, Health and repair) is enforced against them. Terminal repairs must be a plain call to the component's own CLI, with no line breaks or control characters (R0). Nothing a source declares runs without a person's click | A source plugin's `exec` check is never invoked |
| T10 | MCP servers and local tools from sources run arbitrary commands or reach plaintext endpoints | The package validator's rules apply unchanged: `LocalToolSecurityPolicy` for commands and default arguments, https (or loopback http) for remote MCP, declared environment keys only; unsupported headers are reported, not dropped | Unsafe command, http remote and undeclared env refused |
| T11 | Malformed or oversized input is dropped silently or exhausts memory | Files over a size limit (marketplace 256 KB, manifest 512 KB, skill text 256 KB, icon 512 KB), more than 200 entries, or undecodable files are listed with a problem, never skipped silently. An unreadable `sources.json` is reported and never overwritten | Each limit; a corrupt `sources.json` survives a save attempt |
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
