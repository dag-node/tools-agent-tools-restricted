# Misleading agent setting names explained

[Agents](index.md) · [Claude Code](claude-code.md) · [Codex](codex.md) ·
**Setting names** — [all docs](../index.md)

Six settings across the two agents whose names cheerfully announce the opposite
of what they do here. What each one really means, and the single rule
that quietly decodes all of them.

> [!WARNING]
> What each permission mode does, and which one a session starts in, is
> the agent's own behaviour and changes between releases. Read the agent's
> official documentation for how these options work today.

A Codex session opens with a banner that has made more than one experienced
admin pause:

```text
approval: never
sandbox: danger-full-access
```

Neither line means what it appears to. `danger-full-access` is the setting
that leaves this host's confinement firmly closed, and `approval: never`
describes who Codex bothers to ask, not what it is allowed to touch. Each name
is the vendor's label for the vendor's own internal layer — and that layer is
not the one protecting your machine.

## The rule that decodes all six

**Every one of these names describes the agent's own internal layer. None
of them describes the boundary.**

What bounds a session is the same three things no matter what these knobs are
set to: the sandbox account it runs as, the SELinux domain it runs
in, and the systemd unit that starts it. Those three hold, regardless
of how permissive or strict a name sounds. A setting that looks like it throws
the doors open leaves those three exactly where they were, and so does one
that looks restrictive. Each merely decides how the agent behaves inside a box
those three keep shut.

Each of them answers one question: what does the agent do. [The boundary,
and what is out of scope](../about/scope.md) is the page that answers the other
one, about reach.

## The six

| Setting | Reads as | Means here |
|---|---|---|
| `sandbox: danger-full-access` (Codex) | the sandbox is off and anything goes | Codex does not add any sandbox of its own, which is exactly what leaves the host's confinement in charge. Codex's own sandbox is bubblewrap; that needs a user namespace this host refuses. Switching the vendor sandbox "on" is the change that would have to open that refusal. |
| `approval: never` (Codex) | no command is ever approved | Codex asks you about a command only where a rule in its requirements marks it `prompt`, and the shipped rules mark none. Maximally permissive inside its layer, not restrictive. The refused-command table is what mediates instead. |
| `read-only` in `allowed_sandbox_modes` (Codex) | sessions may run read-only | It is listed because Codex refuses the whole list without it. A session that selects it still lands on the managed default. |
| `decision = "forbidden"` (Codex) | one of several outcomes, some of them permissive | A rule takes `forbidden` or `prompt`, with `allow` absent from the grammar, so the table can only narrow a session and no row anywhere can grant anything. |
| `disableAutoMode: "disable"` (Claude Code) | a double negative — auto mode disabled, or the disabling itself disabled? | Auto mode is off. It is removed from the `Shift+Tab` cycle and `--permission-mode auto` is rejected, so the session confirms its actions. |
| `permissions.deny` on `ps`, `df`, `id`, `rpm` (Claude Code) | these commands are dangerous | They are ordinary and they succeed. They are denied because the harness auto-approves safe reads silently, and `deny` is the one layer that overrides that silence. |

## Why `danger-full-access` is the safe choice here

This is the one worth understanding rather than memorising. The name is doing
the heaviest lifting (and the most damage to calm nerves).

> [!WARNING]
> **The name is accurate outside this sandbox.** `danger-full-access` is safe
> on the host only because something else is holding the boundary: the session
> runs as a locked-down service account, in the `ai_tools_t` SELinux domain,
> inside a systemd unit that refuses namespaces, in a project you claimed. Set
> the same option on an ordinary Codex install — under your own login,
> with none of that around it — and it means exactly what it says: Codex runs
> commands with your full user privileges and no sandbox at any layer,
> against anything your account can reach. Do not carry this setting from here
> to a plain install.

Codex ships with a sandbox of its own, built on bubblewrap, which needs
an unprivileged user namespace. This host's session unit refuses namespaces
outright, and that refusal is load-bearing: it is what stops a session
appearing as root inside a namespace of its own making.

So there are two possible configurations. Pin `danger-full-access`, and Codex
does not add any extra layer while the host's confinement stands. Or let Codex
sandbox itself, which means opening the namespace refusal — giving up a real
control to gain a nominal one. The package takes the first, and the vendor
documents it as the recipe for running Codex inside an outer sandbox.

Codex's banner calls it `YOLO mode`. The name is Codex's, it describes Codex's
layer, and a session running under it is confined by the sandbox account,
the SELinux domain and the session unit exactly as any other.

(If the name still makes your eye twitch, that is a perfectly reasonable
reaction. Naming is hard. Naming across agent providers appears to be harder.)

## Where each one is written

| Agent | File | Yours to edit |
|---|---|---|
| Codex | `/etc/codex/requirements.toml` | yes, with `sudo` — see [Codex](codex.md) |
| Codex | `/etc/codex/managed_config.toml` | yes, with `sudo` — see [Codex](codex.md) |
| Claude Code | `/opt/ai-tools/.claude/settings.json` | root-owned control plane — see [Claude Code](claude-code.md) |

An edit to either Codex file survives an upgrade; a newer copy lands beside it
as `.rpmnew` and Codex reads the live file alone. The Claude Code settings are
part of the control plane, which root owns so that neither the agent
nor an operator rewrites a guardrail in place.

The confusion is real, shared across providers, and occasionally self-inflicted
by the very people who write the agents. The three things that keep the box
shut do not care what the settings are called.
