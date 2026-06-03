# Sandbox projects

This directory holds **shallow clones** that the Claude Code sandbox agent works
in, so the agent never reads the original repository's full git history — which
may contain credentials or other secrets the agent should not see.

```bash
# everything runs as @PROJECTS_USER@ — no sudo needed
cd /path/to/original/repo          # a normal checkout with a remote
ai-tools --sandbox-create          # clone it into sandbox-projects/, push a branch

cd /var/opt/ai-tools/sandbox-projects/<name>
claude                             # agent edits and commits here

ai-tools --sandbox-push            # send the agent's commits to the remote branch
```

`ai-tools --sandbox-create` does three things: creates the branch
`ai-tools/sandbox-@PROJECTS_USER@/main` from the repo's current branch and pushes
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
and to pick up upstream changes you remove the sandbox and re-create it
(`ai-tools --sandbox-create` reuses the same branch).

If you ever do fetch or pull here, it stays safe **only** while `.git/shallow` is
intact — git honours that boundary and fetches shallow changes only. Two things
break it, and both download the original repo's full history (the secrets the
sandbox exists to keep out) into the clone:

- `git fetch --unshallow` / `git fetch --deepen` — explicit deepening; never run these.
- a **missing** `.git/shallow` — then an ordinary `git pull` unshallows. The agent
  has no credentials and cannot fetch, but it *can* delete `.git/shallow`; so before
  pulling with your own credentials, confirm the file is still present (or don't pull).

When in doubt, push the work out and throw the clone away rather than syncing it.

## Secrets in the working tree still need protection

Shallowness removes only the *history*. The clone's current working tree still
contains whatever secrets live at the tip commit — a checked-in `.env`, a key file,
a `kubeconfig`. The sandbox clone is an ordinary registered project, so the same
protections apply and you should still use them as defense in depth:

- `!`-exclude live secret paths for this clone in
  `~/.config/ai-tools/allowed-projects`, so their ownership is never handed back to
  the agent group; and
- run `cd <clone> && sudo ai-tools-lockdown` to lock existing secret-named files
  (`.env`, `*.key`, …) to `<you>:<you> 600` before the agent runs.

A shallow clone is not a substitute for keeping the agent away from live secrets —
it only keeps *past* ones out.

## Pushing back

Only **@PROJECTS_USER@** can push. The sandbox account (`ai-tools`) has no SSH key
or git credential, so it physically cannot reach the remote — `ai-tools
--sandbox-push` runs as @PROJECTS_USER@ and uses @PROJECTS_USER@'s credentials.

The push target is a per-repository branch:

```
ai-tools/sandbox-@PROJECTS_USER@/main
```

`main` is the default leaf; `ai-tools --sandbox-create` accepts a custom leaf
(e.g. `ai-tools/sandbox-@PROJECTS_USER@/feature-x`). Each repository has its own
remote, so the same branch name across projects never collides.

## Merging the agent's work

Anyone with access to the repository reviews and merges the branch:

```
git fetch origin
git log origin/main..origin/ai-tools/sandbox-@PROJECTS_USER@/main   # review
git merge origin/ai-tools/sandbox-@PROJECTS_USER@/main              # or rebase
```

Use a regular merge or rebase to keep every agent commit. A **squash** merge
collapses them into one — only do that if you do not want the per-commit history.

## Tearing down

```
ai-tools --sandbox-remove /var/opt/ai-tools/sandbox-projects/<name>
```

Removes the local clone and unregisters it. The remote branch is left in place so
it can still be merged.

## How permissions work here

`sandbox-projects/` is setgid to group `ai-tools`, so each clone is born in that
group; `ai-tools --sandbox-create` adds group-write and the setgid bit so the
agent can read and write the tree. The clone is owned by @PROJECTS_USER@, not by
the sandbox account, and @PROJECTS_USER@ is **not** a member of the `ai-tools`
group — the shared group on the project files is what lets both collaborate
without the projects user joining the sandbox group.

See the repository `CLAUDE.md` for the full security model.
