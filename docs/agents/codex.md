# Codex

[Agents](index.md) · [Claude Code](claude-code.md) · **Codex** · [Setting
names](setting-names.md) — [all docs](../index.md)

What the Codex package adds to a host, how you turn it on, and which of its
files you may edit. The package ships off; two lines turn it on.

## Turn Codex on

```bash
sudo sed -i 's/^#\?AI_TOOLS_AGENTS=.*/AI_TOOLS_AGENTS="claude-code codex"/' /etc/ai-tools/operator.conf
sudo ai-tools-admin system bootstrap
```

The package installs its files whether or not the agent is on, and stays
off until `AI_TOOLS_AGENTS` in `/etc/ai-tools/operator.conf` names `codex`.
The bootstrap then installs the `@openai/codex` package into the sandbox
toolchain, points the launcher at the vendor binary, and labels it
for the SELinux confinement; the nightly toolchain update maintains it
from then on. An operator starts a session in a claimed project by typing
`codex`, exactly as they type `claude`: the wrapper at `/usr/local/bin/codex`
checks the caller and the project, then drops to the sandbox account.

Codex needs a login before its first turn. The sandbox has no browser, so use
the device-code login from inside a session:

```bash
codex login --device-auth
```

The login is stored in the sandbox account's own Codex home,
`/opt/ai-tools/.codex`, and every operator's session on the host uses that one
identity. An API key is the optional alternative; the vendor's documentation
covers each login.

## What a Codex session gets, and does not

A Codex session is confined exactly as a Claude Code session: it runs
as the sandbox account, in the confined SELinux domain, inside a claimed
project, and the files it writes come back to you. Codex does not add a sandbox
of its own: the package pins it to the mode Codex calls `danger-full-access`,
and its banner prints that as `YOLO mode`. Both names describe Codex's own
layer, which is off, and neither describes what confines the session — leaving
that layer off is what keeps the host's confinement closed. [Setting
names](setting-names.md) explains why, and warns what the same option means
on a Codex install that has none of this around it. A session that asks
for another mode on its command line lands on the managed default.

Asking for another mode does not tighten a session, because the sandbox
account, the SELinux domain and the session unit are what decide its reach; it
can break one, though. Codex's sandbox needs a user namespace the session unit
refuses, so a session that ends up on a bubblewrap-bound profile keeps every
host control and loses its tool calls, which fail with:

```text
bwrap: No permissions to create a new namespace
```

That line means the session selected a mode this host does not run, not
that something is misconfigured: the pin turns off a layer that could not run
here anyway. See [SELinux confinement](../system/selinux.md) and [The boundary,
and what is out of scope](../about/scope.md).

The SELinux denials a Codex session raises on an enforcing host have been
swept, and the policy was not widened for any of them. One is Codex's own —
a filesystem watch under the sandbox account's home, refused at startup —
and the rest are the ones any session raises, listed
in [ref-section-g7c5](../system/selinux.md#ref-section-g7c5). An access
the policy does not grant stays refused in the session and logged in the audit
log, so a tool call that failed is worth reading against [SELinux
confinement](../system/selinux.md) before treating it as a defect.

Two groups of commands are refused outright, the same ones a Claude Code
session is refused: the git verbs that destroy work no commit and no reflog
returns (`git push --force`, `git reset --hard`, `git clean`), and the commands
that report on the host itself (`ps`, `df`, `id`, `rpm`, and the like). Nothing
else on the host stops either group, which is why each command has a row.

A refused command is raised in the session with its reason, for you to run
where the consequence lands; an unattended `codex exec` reports it and finishes
rather than waiting for anyone.

The rows are the `[rules]` table of `/etc/codex/requirements.toml`, each
carrying the reason it is there — read the file for the set this release ships.
Relaxing a row is an edit you own, and a rule there can only narrow
what a session may run, never widen it; [Setting names](setting-names.md)
covers the keys in that file whose names read as the opposite of their effect.

A row matches the command from its first word forward, word by word,
so where a flag sits decides whether the row catches it: `git push --force` is
refused and `git push origin main --force` is not. This layer is a gate
on the habitual spelling, not a boundary — what bounds a session is the sandbox
account's own access.

Turned off by the package, and stated so you know what to expect: Codex's
sub-agents, MCP servers, plugins and marketplaces, image generation,
and telemetry. The `rg`, `zsh` and `bwrap` Codex ships beside its binary run
in a session like any other program. What they cannot do is start one: only
the pinned binary is a session entrypoint. The npm channel does not publish
a signed per-release checksum, so Codex's entrypoint is pinned as installed
instead: root records the checksum of the binary, `ai-tools status` reports
that pin as `UNCHANGED`, and a binary that changes afterwards under the same
version refuses the next session. That pin satisfies
`AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY`, so a host setting it runs Codex and knows
which tier it holds. [Entrypoint
verification](../system/entrypoint-verification.md) says what that claims.

## The files you may edit

Codex reads two files from `/etc/codex`, and both are yours to edit
with `sudo`:

| File | Holds |
|---|---|
| `/etc/codex/requirements.toml` | what Codex holds every session to, whatever the session sets: the sandbox-mode pin, the approval policy, the login method, the hooks that hand files back per turn, and the commands refused outright |
| `/etc/codex/managed_config.toml` | the defaults applied ahead of any user config: telemetry off, the update check off, a quiet TUI (no animation, no desktop notification), and two commented keys for a custom instructions file and a custom API endpoint |

An edit survives an upgrade, which leaves the live file in place: a newer copy
lands beside it as `.rpmnew` on a package upgrade, and a from-source install
keeps the existing file and says whether it matches the shipped one. Codex
reads the live file alone, so a key a new release adds is not in effect until
you carry it over. `ai-tools status` reports each managed file that differs
from the shipped copy under `/usr/share/ai-tools/codex`, so a host does not
lose track of an edit:

```text
  codex: /etc/codex/requirements.toml differs from the shipped copy
      codex reads the live file alone: a key this release adds is not in it, and what it declares is the host's
      shipped copy: /usr/share/ai-tools/codex/requirements.toml
```

Neither file changes what the session may reach. A Codex release that takes
other keys refuses to start, naming the key, and the remedy is editing the file
to that release's keys.

## Shared skills and the orientation text

The shared skills every agent reads reach Codex through `/etc/codex/skills`,
which the package points at the shared root `/opt/ai-tools/skills`. A host
that already holds something there keeps it: a directory of your own gets
the shared skills linked into it under free names, and a link elsewhere is left
as it is. The shared orientation text is linked
as `/opt/ai-tools/.codex/AGENTS.md`, the instructions Codex reads first
in every session.

## A Codex you installed yourself

`/usr/local/bin/codex` answers to the name `codex` ahead of a copy you
installed under your own account, the same way the Claude Code wrapper shadows
one, because `ai-tools-admin operators add` orders your shell's `PATH`
root-owned-first. `ai-tools status` reports a shell where another `codex` would
win, since typing the name there starts an unconfined one as you. See
[Sessions](../sessions/index.md).

That copy is configured by your own files, not by `/etc/codex`, and none
of this project's confinement is around it. Do not carry the settings this
package pins into it — `danger-full-access` in particular means, on a plain
install, exactly what its name says. [Setting names](setting-names.md) states
what each one is doing here and what it would do there.
