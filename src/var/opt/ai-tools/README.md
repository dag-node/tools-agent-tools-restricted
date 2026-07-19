# Sandbox projects

This directory holds **shallow clones** that the Claude Code sandbox agent works
in, so the agent never reads the original repository's full git history — which
may contain credentials or other secrets the agent should not see.

```bash
# everything runs as the operator — no sudo needed
cd /path/to/original/repo          # a normal checkout with a remote
ai-tools --sandbox-create          # clone it into sandbox-projects/, push a branch

cd /var/opt/ai-tools/sandbox-projects/<name>
claude                             # agent edits and commits here

ai-tools --sandbox-push            # send the agent's commits to the remote branch
```

`ai-tools --sandbox-create` does three things: creates the branch
`ai-tools/sandbox-<operator>/main` from the repo's current branch and pushes
it to the repo's remote, shallow-clones that branch into
`/var/opt/ai-tools/sandbox-projects/<name>` (depth 1 — no historical objects), and
registers the clone so Claude Code may run there.

## Why this is the boundary

The original repo's `.git` is never copied into the sandbox. The clone's own
history is a single commit, so even if the agent reads its `.git`, there is no old
history to leak. Credentials buried in the original repo's past commits stay
outside the sandbox entirely.

## Treat the clone as push-only — avoid `git pull`/`fetch`

The clone is intentionally **shallow**; that is the isolation. The workflow never
pulls: the agent commits locally and `ai-tools --sandbox-push` sends the work up,
and to pick up upstream changes the operator removes the sandbox and re-creates it
(`ai-tools --sandbox-create` reuses the same branch).

Any fetch or pull here stays safe **only** while `.git/shallow` is
intact — git honours that boundary and fetches shallow changes only. Two things
break it, and both download the original repo's full history (the secrets the
sandbox exists to keep out) into the clone:

- `git fetch --unshallow` / `git fetch --deepen` — explicit deepening; never run these.
- a **missing** `.git/shallow` — then an ordinary `git pull` unshallows. The agent
  has no credentials and cannot fetch, but it *can* delete `.git/shallow`; so before
  pulling with the operator's own credentials, confirm the file is still present (or
  skip the pull).

When in doubt, push the work out and throw the clone away rather than syncing it.

## Secrets in the working tree still need protection

Shallowness removes only the *history*. The clone's current working tree still
contains whatever secrets live at the tip commit — a checked-in `.env`, a key file,
a `kubeconfig`. The sandbox clone is an ordinary registered project, so the same
protections apply and the operator should still use them as defense in depth:

- `!`-exclude live secret paths for this clone in
  `~/.config/ai-tools/allowed-projects`, so their ownership is never handed back to
  the agent group; and
- run `ai-tools --lockdown <clone>` (or `cd <clone> && sudo ai-tools-lockdown`) to
  lock existing secret-named files (`.env`, `*.key`, …) to `<operator>:<operator> 600`
  before the agent runs. Either form prompts for the operator's sudo password.

`ai-tools --sandbox-create` runs this lockdown on the fresh clone **before** granting
the agent any access: the clone is born owner-only, and only after the lockdown gate
passes is it opened to the agent group and registered. When the operator declines, or
lockdown fails, the create stops fail-closed — the clone stays private and unregistered,
with a guard `CLAUDE.md` written into it (any existing `CLAUDE.md` is preserved as
`CLAUDE.md.bak`); re-running `ai-tools --sandbox-create <clone>` resumes securing and
registering it, removing the guard and restoring the original.

A shallow clone is not a substitute for keeping the agent away from live secrets —
it only keeps *past* ones out.

## Pushing back

Only the **operator** can push. The sandbox account (`ai-tools`) has no SSH key
or git credential, so it physically cannot reach the remote — `ai-tools
--sandbox-push` runs as the operator and uses the operator's credentials.

The push target is a per-repository branch:

```
ai-tools/sandbox-<operator>/main
```

`main` is the default leaf; `ai-tools --sandbox-create` accepts a custom leaf
(e.g. `ai-tools/sandbox-<operator>/feature-x`). Each repository has its own
remote, so the same branch name across projects never collides.

## Merging the agent's work

Anyone with access to the repository reviews and merges the branch:

```
git fetch origin
git log origin/main..origin/ai-tools/sandbox-<operator>/main   # review
git merge origin/ai-tools/sandbox-<operator>/main              # or rebase
```

Use a regular merge or rebase to keep every agent commit. A **squash** merge
collapses them into one — do that only to drop the per-commit history.

## Tearing down

```
ai-tools --sandbox-remove /var/opt/ai-tools/sandbox-projects/<name>
```

Removes the local clone and unregisters it. The remote branch is left in place so
it can still be merged.

## How permissions work here

`sandbox-projects/` is setgid to group `ai-tools`, so each clone is born in that
group; `ai-tools --sandbox-create` adds group-write and the setgid bit so the
agent can read and write the tree. The clone is owned by the operator, not by
the sandbox account, and the operator is **not** a member of the `ai-tools`
group — the shared group on the project files is what lets both collaborate
without the operator joining the sandbox group.

See the repository `CLAUDE.md` for the full security model.
