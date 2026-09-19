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

The package stays off until `AI_TOOLS_AGENTS` in `/etc/ai-tools/operator.conf`
names `codex`. The key names exactly the agents the host provisions and lets
start a session, so `AI_TOOLS_AGENTS="codex"` runs Codex alone. An agent's
package stays in the toolchain after you take it off the key, until the next
Node release replaces the toolchain; the two agents share one sandbox account,
and [Scope](../about/scope.md) states what that shares between them.
The bootstrap installs `@openai/codex` into the sandbox toolchain,
and the nightly toolchain update maintains it from then on. Start a session
in a claimed project by typing `codex`, as you type `claude`.

Codex needs a login before its first turn. The sandbox has no browser, so use
the device-code login from inside a session:

```bash
codex login --device-auth
```

The login is stored under `/opt/ai-tools/.codex`, the sandbox account's Codex
home, and every operator's session on the host uses that one identity.

## What a Codex session gets, and does not

A Codex session is confined as a Claude Code session is: it runs as the sandbox
account, in the confined SELinux domain, inside a claimed project,
and the files it writes come back to you. Codex's own sandbox is off, pinned
to the mode Codex calls `danger-full-access`, which its banner prints
as `YOLO mode`. [Setting names](setting-names.md) states why that is the safe
setting here and what the same name means on a plain install.

On an enforcing host a session logs the refusals every session logs, listed
in [ref-section-g7c5](../system/selinux.md#ref-section-g7c5), plus one
of Codex's own: a filesystem watch under its home, refused when the session
starts.

The commands a Claude Code session is refused are refused here too: the git
verbs that destroy uncommitted work (`git push --force`, `git reset --hard`,
`git clean`) and the commands that survey the host (`ps`, `df`, `id`, `rpm`,
and the like). A refused command is reported in the session with its reason;
an unattended `codex exec` reports it and finishes. The rows are the `[rules]`
table of `/etc/codex/requirements.toml`, each with its reason, and editing them
is yours. A row matches the habitual spelling of a command and no more;
what bounds a session is the sandbox account's own access.

The npm channel does not publish a signed per-release checksum, so Codex's
binary is pinned as installed: `ai-tools status` reports the pin, and a binary
that changes under the same version refuses the next session. That pin
satisfies `AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY`. [Entrypoint
verification](../system/entrypoint-verification.md) states what each tier
claims.

## The files you may edit

Codex reads two files from `/etc/codex`, and both are yours to edit
with `sudo`:

| File | Holds |
|---|---|
| `/etc/codex/requirements.toml` | what Codex holds every session to: the sandbox-mode pin, the approval policy, the login method, the hooks that hand files back, and the commands refused outright |
| `/etc/codex/managed_config.toml` | the defaults applied ahead of any user config: telemetry and the update check off, a quiet TUI, and two commented keys for a custom instructions file and a custom API endpoint |

An edit survives an upgrade: a package upgrade leaves the live file in place
and puts the newer copy beside it as `.rpmnew`, and a from-source install keeps
the file and says whether it matches the shipped one. `ai-tools status` reports
a managed file that differs from the shipped copy
under `/usr/share/ai-tools/codex`. Codex reads the live file alone, so a key
a new release adds is in effect once you carry it over.

## Shared skills and the orientation text

The shared skills reach Codex through `/etc/codex/skills`, which the package
points at `/opt/ai-tools/skills`; a directory already there keeps its own
entries and gets the shared skills linked in. The shared orientation text is
linked as `/opt/ai-tools/.codex/AGENTS.md`, the instructions Codex reads first
in every session.

## A Codex you installed yourself

`/usr/local/bin/codex` answers to the name `codex` ahead of a copy installed
under your own account, because `ai-tools-admin operators add` orders your
shell's `PATH` root-owned-first, and `ai-tools status` reports a shell
where the other copy would win. That copy runs unconfined as you and is
configured by your own files, not by `/etc/codex`: do not carry
`danger-full-access` into it. [Setting names](setting-names.md) states
what each pinned setting does here and what it would do there.
