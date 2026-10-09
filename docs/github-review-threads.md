# Reading GitHub review threads

Agents can read a pull request's review conversations through two fixed reads on
the GitHub host tool:

```text
review-threads --repo OWNER/REPO --pr NUMBER [--after CURSOR]
review-thread --id THREAD_ID [--after CURSOR]
```

MCP runtimes pass these tokens in the GitHub tool's `arguments` array. CLI-relay
runtimes prefix the command with `astra-host-control github --`. `review-threads`
lists threads with only each thread's first comment (its identity, no body), so a
page of long discussions stays under the broker's output cap; `review-thread`
returns a thread's comment bodies. The returned `pageInfo` belongs to each
connection: page the thread list and then each thread's comments until
`hasNextPage` is false.

The queries are owned by ASTRA. Callers supply only the repository, PR number,
thread id and cursor; options, query text, mutations and raw `api` calls are
rejected before `gh` starts.

ASTRA does not reply to or resolve review threads yet. When asked, the agent
summarizes each thread, makes the requested fixes, and gives the user the reply
it would post. Replies and resolutions from the chat are planned once the
permission levels are harmonized (Ask asks before acting outside ASTRA; Auto
does not ask and leaves a visible record).

Focused regression coverage:

```bash
swift test --filter HostControlToolSupportTests
```
