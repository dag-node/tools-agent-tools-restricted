# About this project

**About** — [all docs](../index.md)

Why a coding agent gets a locked-down account of its own, what that separates
it from, and where the boundary this project draws sits.

An agent started from your shell holds everything your account holds: your SSH
keys, your credentials, every project on the host, and your sudo rights.
`ai-tools` gives it a different account — `ai-tools`, with no login shell
and no password — and lets it work on the projects you claim for it.
What separates your account from the sandbox account is ordinary filesystem
permissions plus an SELinux type — the boundary the kernel already enforces
between any two users.

Four properties follow from that, and each has a page that says what you do
about it:

- A session starts only inside a project you claimed, and refuses a system
  directory or a whole home as the target ([Projects](../projects/index.md)).
- Files the agent writes are born owned by the sandbox account and come back
  to you, without you running anything ([Projects](../projects/index.md)).
- The sandbox account does not hold a sudo rule of its own. The two rules
  the stack installs belong to the operators group, and they start a session
  and stop every running one ([Sessions](../sessions/index.md)).
- Secret-named files are locked away before a claim grants the agent anything,
  and a claim asks before exposing git history
  ([Projects](../projects/index.md)).

**What this is not.** The model defends the host from the agent while the agent
runs. It does not make what the agent wrote safe to execute afterwards —
reading a diff before you run from the tree is that control. The allowlist
decides where a session may start and which writes are handed back, rather than
acting as a read boundary the kernel enforces. Operators are trusted: the model
defends the host and its other users from the agent, not from an operator
who already holds the launch grant. The full scope, including what is
deliberately out of it, is
[ref-section-x6a9](../../CLAUDE.md#ref-section-x6a9).
