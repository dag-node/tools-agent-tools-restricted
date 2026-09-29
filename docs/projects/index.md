# Project lifecycle

**Projects** · [Create](create.md) · [Claim](claim.md) · [Clone](clone.md) ·
[Push](push.md) · [List](list.md) · [Disable](disable.md) · [Enable](enable.md)
· [Unclaim](unclaim.md) · [Remove](remove.md) · [Lockdown](lockdown.md) ·
[Handback](handback.md) · [Permissions](permissions.md) — [all
docs](../index.md)

How a project enters the agent's reach, which command moves it from one state
to the next, and where the page for each command takes over from this one.

```bash
ai-tools projects create ~/src/newproject   # a new project, claimed
ai-tools projects claim  ~/src/existing     # a tree you have, claimed in place
ai-tools projects clone  ~/src/repo         # an isolated shallow clone instead
ai-tools projects list                      # what is registered, and how
```

Run every command as your own user: the `ai-tools` CLI calls `sudo` itself
for the steps that need root and prompts for your password there. Every
`DIRECTORY` argument but `projects create`'s defaults to the current directory,
and every yes/no question states its default, which Enter and a run without
a terminal take (`man ai-tools`). Two pages under this category describe
a property of a claimed tree rather than a command:
[Permissions](permissions.md), for what owns a file the agent wrote and how you
and the agent share one tree, and [Lockdown](lockdown.md), for what a claim
locks away before it grants anything.

## Choose a model first

**Claim in place** when the agent should work your real checkout: shared files,
shared git history (opt-in), and results that land in your tree. The trade is
exposure. Once claimed, the whole tree is in the agent's reach except for two
kinds of path: one that is owner-only, and one named on a `!` line of your
allowlist. Every other path loses world access and gains the agent,
and the world access does not come back at an unclaim
([Permissions](permissions.md)).

**Create a sandbox clone** when the tree, its history, or its surroundings
should stay out of reach. The clone is shallow, so the agent does not read
the origin's history; it lives under the sandbox area, so no directory
enclosing it needs a grant; and the agent's commits go to a branch of their
own, which you push and merge back yourself ([Clone](clone.md)).

Running `claude` in an unregistered directory offers the same choice
interactively.

## The states, and the command for each move

```text
   (nothing)  --projects create-->  claimed  --projects disable-->  disabled
                --projects claim-->          <--projects enable---
                                       |
                     projects unclaim  |  projects remove
                                       v
                       registered no more (files kept / files deleted)
```

| Command | What it answers | How to reverse it |
|---|---|---|
| [`projects create`](create.md) | how to start a new project the agent can work in | `projects unclaim` or `projects remove` |
| [`projects claim`](claim.md) | how a tree you already have is claimed, what it asks, and what a re-claim repairs | `projects unclaim` |
| [`projects clone`](clone.md) | how to work in a shallow clone that keeps the origin and its history out of reach | `projects remove` |
| [`projects push`](push.md) | how a clone's commits reach the branch it tracks | — |
| [`projects list`](list.md) | what is registered, and what is inconsistent | — |
| [`projects disable`](disable.md) | how to park a project so no session starts there | `projects enable` |
| [`projects enable`](enable.md) | how to lift the park, and what a `!` line it does not lift means | `projects disable` |
| [`projects unclaim`](unclaim.md) | how the agent's access comes off a tree whose files you keep | `projects claim` again |
| [`projects remove`](remove.md) | how a project and its directory are deleted | — |
| [`projects lockdown`](lockdown.md) | how secret-named files are kept from the agent, on demand | — |
| [`projects handback`](handback.md) | how agent-written files become yours again, inside a project that stays claimed | — |

**`projects handback` does not reverse a claim.** `projects unclaim` does,
and running `projects claim` again is how a project comes back.
`projects handback` changes **file ownership** inside a project that stays
claimed and keeps working — reach for it when agent-written files should be
yours again, and for `projects unclaim` when you want the agent out.

## Where the boundary is

Your allowlist decides where a session may start and which written files come
back to you; it does not decide what a running session may read. Once a session
runs, the permissions on the tree and its files are what confine it, which is
why every command here that grants access locks secret-named files down first,
and why declining that lockdown stops the command. [The boundary, and what is
out of scope](../about/scope.md) states it in full.
