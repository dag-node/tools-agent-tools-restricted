# Project lifecycle

How a project enters the agent's reach, what each consent prompt actually grants, and how
every path recovers or reverses. All commands run as your own user — the `ai-tools` CLI
invokes `sudo` itself where a step needs root and prompts for your password there.

```bash
ai-tools --project-claim /path/to/project     # work in the real tree, in place
ai-tools --sandbox-create /path/to/repo       # work in an isolated shallow clone
ai-tools --list                               # what is registered, and which model
```

| Command | Registers | Reverses |
|---|---|---|
| `--project-claim` (alias `--project-create`) | the real tree, in place | `--project-unclaim` |
| `--sandbox-create` | a shallow clone under `/var/opt/ai-tools/sandbox-projects/` | `--sandbox-remove` |
| `--lockdown` | nothing — locks secret-named files, any time | — |
| `--reclaim [--full]` | nothing — hands agent-written files back to you | — |

## Choosing the model

Claim in place when the agent should work your real checkout: shared files, shared git
history (opt-in), results land directly in your tree. The trade is exposure — the setgid
group and the `g:ai-tools:rwX` ACL make the whole tree agent-readable and -writable, so
everything under it is in scope once claimed.

Create a sandbox clone when the tree, its history, or its surroundings should stay out of
reach: the clone is shallow (`--depth=1`), so the agent never sees the origin's history,
and it lives under the already-isolated sandbox area, so nothing above it needs a grant.
The agent's commits go to a dedicated branch (`ai-tools/sandbox-<user>/<leaf>`) that you
push and merge back yourself — the day-to-day work cycle is documented on the host in
`/var/opt/ai-tools/README.md`.

The launch wrapper offers the same choice interactively when you run `claude` in an
unregistered directory.

## What each prompt grants

```text
Do you want to proceed? [Y/n] (default: Yes):
```

Every yes/no question states its default; Enter — and any run without a terminal — takes
it. Defaults fall on the safe side, so a question that *widens* access defaults to No and
is never auto-answered by the environment; only an explicit flag (`--project-claim -y`
for the proceed prompt, `--yes` on `ai-tools-lockdown`) pre-answers one.

A claim walks through self-contained blocks, each with its own decision:

- **Proceed confirm** (`[y/N]`) — approves exactly the pending steps the Review block
  lists: registration, the setgid group + ACL grant on the tree, the SELinux label, and
  any drift repair shown above it.
- **Secret lockdown** (`[Y/n]`) — runs before anything widens access. The scan
  (`ai-tools-lockdown --dry-run`, the first sudo prompt) matches known secret-name
  patterns; locking sets the finds to owner-only (`600`/`700`). Declining stops the claim
  — access is never granted over exposed secrets. Lockdown is best-effort pattern
  matching: handle any secret it cannot know about yourself first.
- **`.git` history** (`[Y/n]`) — normalizes `.git` so the agent reads the repo's full
  history and your own commits stay agent-accessible. Decline it to keep history hidden;
  the working tree stays claimed either way.
- **Traverse-only parents** (`[y/N]`) — when the project sits under a directory the
  sandbox account cannot enter (a `700` home), grants `u:ai-tools:--x` on each blocking
  parent you own: enter only, never list or read. It widens access *above* the project,
  hence default No.

## Re-claiming: drift and skip-lists

```bash
ai-tools --project-claim        # from inside the project; idempotent
```

A re-claim is a quiet no-op when nothing is missing, and repairs what is. Files moved
into the tree from outside (`mv` keeps their old group and inherits no ACL) surface as
*interior permission drift* — listed with owner and mode, repaired under the same proceed
confirm and secret gate as a first claim. Hits under skip-listed directory names
(`node_modules`, build output — the trees claim deliberately leaves alone) are reported
separately with their remedies:

```bash
# /etc/ai-tools/operator.conf — reopen a source dir that shares a skipped name
SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE="tools/bin"
```

then re-claim; or `ai-tools --reclaim --full` for ownership alone. To keep a subtree out
of the agent's reach on purpose, make it owner-only (`chmod 700`) or add a `!`-exclusion
line for it in `~/.config/ai-tools/allowed-projects` — both stop it being re-reported.

## Sandbox clones are secured before they open

```bash
ai-tools --sandbox-create /path/to/repo
```

The clone is born owner-only (`umask 077`), so checked-in credentials in the tip commit
are unreadable to the sandbox account from the first instant. The lockdown gate runs
next; only past it is the clone opened to the agent group, labelled, and registered —
with the locked paths kept private. Declining (or a failed lockdown) stops fail-closed:
the clone stays on disk, private and unregistered, with a guard `CLAUDE.md` inside.

```bash
ai-tools --sandbox-create /var/opt/ai-tools/sandbox-projects/<name>   # resume
```

Pointing `--sandbox-create` at the existing clone path resumes exactly where it stopped:
gate, then normalize + label + register, removing the guard on success.

## Recovery and reversal

```bash
ai-tools --lockdown /path/to/project    # lock secret-named files, any time
ai-tools --reclaim  /path/to/project    # hand agent-written files back to you
ai-tools --project-unclaim              # revert a claim; the directory stays on disk
```

`--lockdown` runs the same scan-and-lock on demand — after adding a credential file to a
claimed tree, or before re-running a stopped claim. `--reclaim` returns agent-written
files to `<you>:ai-tools` (including the `.git` tree the per-session sweeps skip); run it
before an ACL-unaware backup so plain ownership carries your access into the copy, and
add `--full` to include the heavy skipped trees. `--project-unclaim` reverses a claim
end to end: label reverted, both registries dropped, and — behind its own confirm — the
tree regrouped away from the agent with group write removed. `--sandbox-remove` deletes a
clone and its registration, warning about unpushed commits first; the remote branch stays
for others to merge.

## Where the security boundary actually is

The allowlist (`~/.config/ai-tools/allowed-projects`) gates where sessions *launch* and
which written files get ownership handed back — it is not a read boundary. Once any
session runs, ordinary file permissions plus the SELinux `ai_tools_project_t` label are
what confine it, which is why every flow above locks secrets down *before* granting group
access, and why declining a lockdown always fails closed. The invariants live in
[`CLAUDE.md` — Security model](../CLAUDE.md#security-model--what-sandbox_user-can-and-cannot-do);
the per-component mechanism in [`.claude/rules/`](../.claude/rules/).
