---
paths:
  - "src/usr/local/lib/ai-tools/conf.lib.sh"
  - "src/usr/local/lib/ai-tools/providers.lib.sh"
  - "src/usr/local/lib/ai-tools/agents.d/**"
  - "src/usr/local/lib/ai-tools/integrations.d/**"
  - "src/usr/local/lib/ai-tools/session-env.d/**"
  - "src/usr/local/lib/ai-tools/admin-commands.d/**"
---

# Provider manifests, enablement, and integrations

The toolchain and launch layers provision providers without naming any: which providers exist,
and how each is provisioned, comes from per-package manifests gated by `operator.conf`, resolved
by `providers.lib.sh`. Two provider kinds share the mechanism:

- **Agents** (`ai-tools-agents-*`) — the AI coding agents. `ai-tools-bootstrap`/`nvm-update` install
  each enabled agent's npm package and symlink its launcher (see [updater](updater.rule.md)).
- **Integrations** (`ai-tools-integration-*`) — host-toolchain layers. `ai-tools-run` sources each
  enabled integration's session-env fragment (see [launch](launch.rule.md)).

## Manifests

Each installed member package ships one manifest, `/usr/local/lib/ai-tools/{agents,integrations}.d/
<name>.conf`, `644 root:root`. `<name>` (the basename) is the token an operator writes in
`AI_TOOLS_AGENTS` / `AI_TOOLS_INTEGRATIONS`. It is `KEY=value` data — **parsed, never sourced**, the
same posture as `operator.conf`/`skip-dirs.lib.sh`, so a malformed or tampered manifest cannot
execute code in the privileged scripts that read it:

- agents: `npm_package` (the registry package), `launcher` (the bin symlinked at
  `/opt/ai-tools/bin/<launcher>`, and the name `ai-tools-run` matches an executable against to
  decide whether it may launch), `display_name` (what the launch banner and the unit description
  call it), `handback` (which side converges ownership — below), `entrypoint_fcontext` and
  `config_dir` (the two paths it declares to SELinux — below), `skills_dir` / `subagents_dir`
  (where inside its config directory it reads each shared asset kind, so the shared copies can be
  symlinked in — see [shipped-assets](shipped-assets.rule.md)), `memory_file` (the filename that
  agent's product reads as user-scope instructions, where the shared orientation text is linked),
  `default_enable`, and — optionally — the three release-verification fields below.
- integrations: `default_enable`, and optionally the three keys the SELinux layer reads —
  `build_output_dirs` (the directory names that hold the toolchain's build output, which
  `relabel.lib.sh` reads from every installed manifest through
  `ai_tools_installed_integrations_declaring` and maps to the build-output type),
  `selinux_layout_module` (the policy module that types them at creation, loaded with the
  integration), and `selinux_groups` (the optional groups the toolchain needs, which the status
  reports name when not loaded). What each is for is in [dotnet](dotnet.rule.md).

`ai-tools-providers(5)` is the operator's statement of every key, and a manifest's own header is a
pointer to it: a manifest is package data replaced on upgrade, so a description that lives in the
file is one an upgrade rewrites for no settings change, and one that lives in the page reaches every
host with the package. The same placement rule holds for the config files an operator holds
(*A config file's header is a pointer*, below).
- either kind: `admin_summary`, the one-line description `ai-tools-admin --help` prints for the
  command domain this package contributes (below). Optional; a package that does not contribute a
  domain has no use for it, and a domain whose manifest omits it is still listed.

Either kind may also ship `session-env.d/<name>.env.sh`, keyed by the same `<name>` — one flat
namespace across both kinds, so a provider name is unique host-wide. A package with root-only
administration of its own additionally ships `admin-commands.d/<name>`, keyed the same way, which
is the `<name>` domain of `ai-tools-admin`. A package with commands of
its own may additionally ship `filters.d/<name>.rules`, keyed the same way, carrying the
token-saving rules for those commands (see [filters](filters.rule.md)). That set is read by an
agent's filter hook rather than by `ai-tools-run`, and it is not gated on provider enablement — a
rule is inert unless the agent runs the command it matches — so it is a rule-set name rather than
a provider capability.

`ai-tools-base` owns the four directories (`agents.d`, `integrations.d`, `session-env.d`,
`admin-commands.d`), ships `providers.lib.sh`, and owns both readers — the `ai-tools-run` shim and
the `ai-tools-admin` dispatcher; each member package ships only its own files into them.

## The `handback` capability — which side converges ownership

Files the agent writes are born `SANDBOX_USER`-owned, and the ownership handback returns them to
the operator (see [ownership-and-hooks](ownership-and-hooks.rule.md)). That handback needs a
**driver**, and only the agent knows whether it has one, so the manifest declares it:

- **`handback=hooks`** — the agent runs the hooks itself, per tool call and per turn (Claude
  Code's `PostToolUse`/`Stop`/`SessionStart`/`SessionEnd` entries in `settings.json`).
  `ai-tools-run` leaves the handback to the agent.
- **anything else** (`handback=none`, an unrecognized value, an absent key) — no driver, so
  `ai-tools-run` sweeps the project itself once the session exits: every `SANDBOX_USER`-owned path
  under the project directory (heavy trees skipped, `.git` walked — the `reclaim` selector in
  `skip-dirs.lib.sh`) is offered to `ai-tools-chown` through the handback socket. Convergence is
  per session rather than per turn; the end state is the same.

`ai_tools_agent_sweeps_at_exit <declaration>` is the pure verdict, and it is an **allowlist**:
only the exact literal `hooks` switches the sweep off, so an agent that declares any other value gets the
sweep — a redundant walk is the recoverable error, an operator tree left sandbox-owned is not.

The sweep only chooses which paths to **offer**; each one still passes `ai-tools-chown`'s
allowlist, exclusion, secret, and born-owner re-validation as root, so it cannot reach a path the
hooks could not. It runs from an `EXIT` trap, so an interrupted shim (Ctrl-C, `SIGTERM`) still
converges; a `SIGKILL` leaves the tree to the next session's sweep or `ai-tools --reclaim`.

## `entrypoint_fcontext` and `config_dir` — the agent declares its own paths

Two paths per agent must carry a type this policy defines, and both belong to the agent rather
than to the base, so the base SELinux module declares **neither** and the manifest carries both:

| manifest field | path | type | without it |
|---|---|---|---|
| `entrypoint_fcontext` | the launcher binary (a file-context regex; `[^/]+` spans the Node version directory) | `ai_tools_exec_t` | no domain transition — the session would run unconfined, so `ai-tools-run` refuses to launch |
| `config_dir` | the agent's control-plane directory, one component under `/opt/ai-tools` | `ai_tools_home_t` | the confined session cannot write its own state (the home root is `usr_t`) |

`ai-tools-relabel-agent` registers each as a local `semanage fcontext` rule and relabels what it
matches (see [updater](updater.rule.md)). A second agent package therefore brings both its binary
and its state directory into this policy without touching the base.

`config_dir` is more than a label: the agent's package **owns that directory** and the files in it
(`settings.json`, the hooks), while the base pins its mode (`CP_AGENT_CONFIG_MODE`,
setgid+sticky) and resolves the set of them (`ai_tools_agent_config_dirs` in
`control-plane.lib.sh`) for the installer, the labelling, the managed-asset seeding, and the
permission test. The agent's session-env fragment pins the same directory as its config variable
(`CLAUDE_CONFIG_DIR`), so the manifest and the fragment must agree.

Two constraints keep that from being a label-anything primitive, and both live in
`relabel.lib.sh`, not in the manifest:

- **The types are pinned there**, never in a manifest. An agent declares *which path* is which,
  never *what label* a path gets.
- **Each declaration must be containable**: the entrypoint pattern to an anchored literal head
  under `/opt/ai-tools/.nvm/versions/node/`, with no `..` and none of the regex constructs (`|`,
  groups) that could make it match elsewhere; the config directory to one plain component under
  the sandbox home. `tests/unit/relabel.sh` drives both predicates.

The rule's lifecycle follows the package: applied by the agent package's `%post` (and by
`install.sh`, `ai-tools-bootstrap`, the relabel watcher, and `ai-tools-admin system entrypoints relabel`), dropped by its
`%preun` on final erase via `ai-tools-relabel-agent --remove <agent>`.

## `release_manifest_url` / `release_key` / `release_fingerprint` — the agent declares its own provenance

An agent whose vendor publishes signed per-release checksums declares three optional fields, and
`entrypoint-verify.lib.sh` then proves the installed entrypoint is the binary that vendor published
— independently of how it was delivered (see [updater](updater.rule.md) for where the check runs
and what gates on it):

| field | value |
|---|---|
| `release_manifest_url` | the vendor's per-release checksum manifest, with a single `{version}` slot |
| `release_key` | the OpenPGP key that signs it, a file the agent's own package ships |
| `release_fingerprint` | the fingerprint(s) that key must have — a **list**, in the grammar below |

Three properties keep this a declaration rather than a lever:

- **The key is shipped, never fetched.** A key pulled from the host that served the manifest proves
  only that whoever served one served the other — npm's own weakness, and the reason
  [updater](updater.rule.md) defers pinning the registry signing key. Both the manifest and the key
  are plain rpm-owned files (`0644 root:root`, **not** `%config`), so they change only when a signed
  package installs new ones; no host process rewrites them, and the pin ultimately rests on the
  package signature.
- **The fingerprint is declared apart from the keyring** and asserted against `gpgv`'s output, so a
  keyring swapped for another *valid* key is still refused. It is a list because a vendor key
  rotation would otherwise be an outage: the package ships old and new keys in one keyring and both
  fingerprints, then drops the old pair once upstream has.
- **A template with no `{version}` slot is refused**, not fetched as-is. One manifest for every
  version would read as "verified" while checking a release it never looked at.

An agent declaring none of them is unverified — the state every agent is in until its vendor
publishes something to check against.

**These fields identify the signer, not the release, so they do not track versions.** One key signs
every Claude Code release, and the entrypoint's own per-version checksum lives elsewhere — in the
root-written pin (`/var/opt/ai-tools/state/entrypoint-pin.d/<agent>`), refreshed automatically by
the relabel watcher on every legitimate update. The two halves have deliberately different
lifecycles, which is what keeps a static trust anchor from needing per-release maintenance:

| | changes when | written by | on a mismatch |
|---|---|---|---|
| the manifest fields | the vendor rotates its signing key | a signed rpm, never the host | *cannot verify*, with the `dnf update` as its remedy |
| the pin | every agent update | root, from the relabel watcher | *tamper* — the launch fails closed |

So an operator edits neither in the normal path. A key rotation is absorbed by shipping both keys
and both fingerprints for the overlap, and until that package lands the host reports unverified
rather than compromised — the direction that keeps a vendor's key ceremony from becoming an outage.

## The shared config grammar (`conf.lib.sh`)

Every `KEY=value` file in the project — `/etc/ai-tools/operator.conf` and every manifest — is read
by one parser, `conf.lib.sh`, which `operator.lib.sh`, `skip-dirs.lib.sh`, and `providers.lib.sh`
all source. One grammar means a key reads the same whichever component reads it:

```
KEY=value            quotes optional; whitespace around the key and `=` trimmed
KEY="a b"            one layer of matched quotes stripped
KEY=a, b  c          list items separate on commas AND whitespace, freely mixed
KEY=value   # why    `#` at the start of a value or after whitespace ends it; inside
                     quotes it is literal, so a value containing one is written "a#b"
KEY=                 PRESENT with an empty value — distinct from an ABSENT key
```

A repeated key takes its last assignment; a line with no `=` is ignored. Files are **parsed, never
sourced**, so a malformed or tampered one yields a bad value, never executed code.

The **path-list** files share that grammar rather than defining their own.
`ai_tools_conf_path_entry` reads one `allowed-projects` line — whole-line and end-of-line
comments, and one quote layer for a path carrying a space or a literal `#`, with a leading `!`
preserved so an exclusion stays distinguishable after the quotes come off. Every reader of that
file — the launch wrapper, the CLI, the owner resolver in `operator.lib.sh`, and each root helper
that walks or labels a project (`ai-tools-chown`, `-setgid`, `-setfacl`, `-unclaim`, `-lockdown`,
`-relabel`) — takes it from here, which is exactly why the rule lives in one place: a parser
copied into each is a parser that drifts, and a line the wrapper resolves but a helper does not
is a project the agent can launch in whose files stay sandbox-owned, or a carve-out the wrapper
refuses that a walk grants. Each reader requires the library rather than falling back to a
private parser; the resolver's load is fail-closed by consequence, since without the parser no
line denotes an entry and no path is covered. The CLI,
the relabel helper, and the launch wrapper's post-claim confirm additionally decide **membership**
through `ai_tools_conf_allowlist_has_entry`/`_has_exclusion` (and `_matching_lines` /
`_exclusion_lines` for the raw lines), which parse each line with the same grammar and compare
realpath-normalized values, so a commented or quoted entry is never mistaken for unlisted.

The same library owns the **editing** of that file — `_state`, `_add`, `_remove`, `_enable`,
`_disable` — because all three of its writers (the CLI, the `ai-tools-allowlist` root helper, and
`install.sh`) must agree with its readers about what a line matches. A writer with its own matcher
is a project that stays reachable after a "removal". The state model those functions implement,
and the rules they enforce on every caller, are in [cli](cli.rule.md).

`ai_tools_conf_read` returns present/absent separately from the value, which is what makes
`KEY=` (an explicit "none") distinguishable from an omitted key — the distinction the gating below
turns on. `ai_tools_conf_list` overwrites its target array **only** when the key is present, so an
override key overrides and an absent one leaves the caller's default standing (how the `SKIP_*`
categories in [ownership-and-hooks](ownership-and-hooks.rule.md) keep their built-in defaults).

**Splitting pins `IFS` locally.** The parser is sourced into scripts that set the strict-mode
`IFS=$'\n\t'` (`nvm-update.sh`, `claude.sh`), where an inherited `IFS` would read `"a b"` as one
item — for a provider allowlist that reads as "no such provider", a wrong verdict that disables a
configured agent with only a warning. `tests/unit/conf.sh` drives the splitter under that IFS.

### `operator.conf` across an upgrade

Two rpm directives govern a config file that a package ships and the host later edits, and the
choice between them decides what `dnf update` does on a running host:

| directive | file in place afterwards | parked copy | consequence |
|---|---|---|---|
| `%config` | the package's | the host's, as `.rpmsave` | the host's settings stop applying |
| `%config(noreplace)` | the host's | the package's, as `.rpmnew` | the new version's options stay dormant |

`operator.conf` takes `%config(noreplace)`, so an upgrade enables only what the host asked for.
A host that set `AI_TOOLS_FILTERS=` to turn filtering off still has it off afterwards; under
`%config` that line would move to a file no resolver reads and filtering would come back on. A dormant
option is recoverable at any time, and a silently reverted setting is not. `settings.json` takes
the directive for the same reason, which is why a newly shipped hook is installed but stays
uninvoked until its declaration is merged ([claude-settings](claude-settings.rule.md)).

The cost is that reconciling the `.rpmnew` is manual, so it is signposted rather than automated:
each package's `%post` prints the pointer whenever one is present, and `sudo ai-tools-admin system
post-upgrade` names the options the new version documents that the file does not mention, shows the
difference, and offers to clear the copy. It leaves this file unchanged. An additive merge
could append an option block the file lacks, but it could never correct the prose of one already
there, so `operator.conf(5)` is the single current statement of what an option means and the file
points at the man page rather than restating it.

### A config file's header is a pointer

Every config file an operator holds keeps its reference in a section 5 page, for one of two
reasons. The shipped templates, `operator.conf` and `custom-claude-endpoint.conf`, are
`%config(noreplace)`, so a prose change to one reaches an upgraded host only as an `.rpmnew` the
operator reconciles by hand. The per-operator files, `allowed-projects` and `secret-patterns`, are
seeded once, by `ai-tools-admin operators add` (the two `*_seed` functions in `conf.lib.sh`), and
no upgrade rewrites them: the header an operator's file carries is the one that shipped on the day
that account was enrolled, for as long as the account exists. A header written into any of the
four therefore states what the file is, the one rule a reader needs before writing a line, example
lines or one brief line per option beside its commented default, and the page that holds the
reference — `operator.conf(5)`, `custom-claude-endpoint.conf(5)`, `allowed-projects(5)`,
`secret-patterns(5)` — and the grammar, the semantics and the worked examples live in the page,
which the package replaces on every upgrade. A commented default (`#KEY=`) stays in a template: it
is a setting, and it is what `ai_tools_conf_keys` counts as *mentioned*, which keeps `system
post-upgrade` from announcing every option as new.

A config header is read in a terminal, which does not reflow it, so it holds to 72 columns, ragged
right, with no comment line ending on an article, a conjunction, a preposition, or a wh-word — the
words `msg.lib.sh` carries to the next line when it wraps a runtime message, and the rule the
checker's default `comment-tie` check holds every source comment to. The checker's
`--config-header` mode reports both, and `tests/unit/man.sh` runs it over the four headers. `tests/unit/man.sh` caps each seeded header, asserts it names its page and does not
register an entry, and reads each page's own examples through the parser that file is read with
(`ai_tools_conf_path_entry`, `ai_tools_load_secret_patterns`), so an example the manual shows is
one the file accepts. The one claim that stays in a header whatever its page says is the fail
direction a reader must know before writing a line — for `secret-patterns`, that a pattern listed
there **replaces** the built-in baseline ([secret-handling](secret-handling.rule.md)), which
`tests/unit/secret-patterns.sh` asserts on the seeded text.

### Deferred: `operator.conf.d/`

A drop-in directory read after `operator.conf` would end the reconciliation question outright: the
package would own the defaults and the documentation, the host only its own fragments, and the two
would never share a file.

Nine options do not earn it. A `.d` directory is not one convention but several — `sysctl.d` takes
the last assignment, `sshd_config.d` the first — so its semantics cannot be inferred from having
seen another, and it becomes one more thing to learn before an upgrade is predictable. That price
is worth paying against a file large enough to make hand-merging error-prone, and not before.

## Enablement is fail-closed

`operator.conf` `AI_TOOLS_AGENTS` / `AI_TOOLS_INTEGRATIONS` (provider names, in the grammar above)
gates each kind:

- **key present** → enabled = exactly the listed names (an allowlist; an empty value = none).
  `default_enable` is ignored, so an operator's explicit list always wins.
- **key absent** → enabled = installed providers with `default_enable=yes` (the baseline). Both
  keys ship commented in the template, so a fresh or upgraded host (whose `%config(noreplace)` file
  may predate them) runs the baseline.
- **config unreadable, malformed, or untrusted** → treated as absent (the baseline; never
  "enable all").
- **a listed name with no installed manifest** → reported and skipped, never guessed.

A `default_enable=yes` is the shipping package's claim that its provider leaves host surface
unchanged beyond the sandbox (Claude Code); a surface-widening one ships `default_enable=no` and is enabled
only when an operator names it (dotnet). This is the fail-closed default-when-unset rule.

## The sandbox cannot widen its own surface

The inputs above decide which agents get installed and what environment a session is handed, and
the code that reads them runs **as `SANDBOX_USER`** (`ai-tools-run`, `nvm-update`). So each input is
honored only while `ai_tools_conf_is_trusted` holds for it — it exists, is not a symlink, is owned
by root, and is writable by neither group nor other — and so is the **directory** holding it, since
a group-writable directory lets a non-root writer unlink a root-owned file and put its own in that
name. Each refusal moves to *less* access and is reported (stderr for the operator, journald for
the trail), never silently:

| untrusted input | verdict |
|---|---|
| `operator.conf` | ignored → the baseline (which only enables what a package marked `default_enable=yes`) |
| a manifest directory | that whole provider kind is refused |
| one manifest | that one provider is skipped |
| `session-env.d` or a fragment | that fragment is not sourced |
| `admin-commands.d` | no contributed command dispatches at all |
| one command fragment | that one domain does not dispatch |
| `/usr/local/lib/ai-tools` itself | no integration env at all (`ai-tools-run`'s bootstrap check) |

A refusal reports the owner uid and the mode the predicate read, against what it requires
(`ai_tools_conf_untrusted_reason`). That uid is the owner on disk only in the initial user
namespace: in any other, a host uid the namespace does not map reads as the overflow uid `65534`
while `stat` exits 0, so a root-owned input is refused on a reading that is not its owner.
`ai_tools_conf_uid_map_is_identity` reads `/proc/self/uid_map`, and the reason names the
translation where it applies, so the investigation starts at the namespace and not at the file's
mode or label. The `--user` unit rule in [updater](updater.rule.md) keeps this project's own units
from creating such a namespace; the reason is what a refusal says when one exists anyway.

Trust bootstraps on the lib directory, which `ai-tools-run` checks inline before sourcing anything
from it — the predicate that checks everything else lives inside it. `0751 root:SANDBOX_GROUP` on
that directory is therefore load-bearing, not housekeeping, and
`tests/integration/perms.sh` asserts it along with the four provider directories.

The last two rows carry the predicate one step further out than the rest of this table: what they
gate is not what a confined session receives but what **root executes**, since `ai-tools-admin`
execs a fragment as root. The reader there is root, so the check does not protect a confined
reader: the file it would run sits in a directory the sandbox account can reach, and a planted or
replaced fragment would be a root command of the agent's choosing.

This is enforced from both ends, and both halves are required: `tests/unit/providers.sh` and
`tests/unit/admin-commands.sh` drive each untrusted state through the resolver and the dispatch and
assert each fails closed (catching a host someone has already broken), while
`tests/boundary/providers.sh` probes the deployed surface **as the agent** and asserts none of it is
agent-writable (catching the agent trying to break it).

## Resolution

`providers.lib.sh` splits a pure verdict from the I/O, mirroring `confinement.lib.sh`:

- `ai_tools_provider_is_enabled <name> <default_enable> <allowlist_active> <allowlist>` — the pure
  enablement decision, no I/O, unit-tested over the truth table (`tests/unit/providers.sh`).
- `ai_tools_agent_sweeps_at_exit <handback-declaration>` — the pure handback-driver decision
  (above), likewise no I/O and unit-tested.
- `ai_tools_enabled_agents` — prints `name<TAB>npm_package<TAB>launcher` per enabled installed agent.
- `ai_tools_enabled_integrations` — prints one enabled installed integration name per line.
- `ai_tools_installed_integrations_declaring <key>` — prints `name<TAB>value` for every
  **installed** integration whose trusted manifest carries `<key>`, enabled or not, under the same
  trust rules. For a field that describes a toolchain present on the host rather than what a
  session receives.
- `ai_tools_agents_empty_verdict` — for a caller whose `ai_tools_enabled_agents` printed an empty
  set, one `fault`/`none` line saying why, every refused path named with what the predicate read.
  The resolver reports a refusal on stderr only, so a caller reading its stdout sees an empty set
  for a tampered manifest directory and for a host with no agent package alike; `nvm-update` ends
  the first as a fault and logs the second (see [updater](updater.rule.md)). An allowlist naming
  agents none of which resolved is a fault too: the operator asked for agents the run does not
  maintain.
- `ai_tools_agent_manifest_field <name> <key>` — one further field of a trusted manifest, for a
  caller that has already resolved which agent it has. The name is allowlisted to a plain
  identifier before it becomes a path, so it cannot address a file outside the manifest directory.
- `ai_tools_provider_manifest_field <name> <key>` — the same read across both manifest kinds, for a
  caller holding a provider name without knowing which kind carries it (`ai-tools-admin` reads
  `admin_summary` this way). The namespace is flat, so at most one kind holds the name; integrations
  are tried first.
- `ai_tools_provider_gate <conf-key>` — how a kind's enabled set is being decided (`allowlist` /
  `baseline` / `untrusted`), read-only and side-effect free. The resolvers read it, and so does
  `ai-tools --providers` (see [cli](cli.rule.md)), so an operator asking what is enabled and a
  session being launched consult one implementation.

Data-only stdout (safe in `$(...)`); enabled-but-uninstalled names and every trust refusal go to
stderr, and to journald when `log.lib.sh` is loadable.
`AI_TOOLS_{AGENTS,INTEGRATIONS}_DIR` and `AI_TOOLS_OPERATOR_CONF` are root-only test hooks.

`conf.lib.sh` is a **required** dependency: without it `providers.lib.sh` can neither parse a
manifest nor tell a trusted input from a planted one, and guessing either is the fail-open this
seam exists to prevent. It therefore returns non-zero and does not define any resolver, so every consumer loads
it as `source … && declare -F <resolver>` and falls back when that fails — Node-only for
`ai-tools-bootstrap`, npm-only for `nvm-update`, no integration env for `ai-tools-run`.

## The `session-env.d` seam

A fragment `/usr/local/lib/ai-tools/session-env.d/<name>.env.sh` appends to two arrays the
launcher owns — `session_environment_options` (`--setenv=` entries) and `session_path_entries`
(PATH tail) — which `ai-tools-run` emits into the transient unit. Both provider kinds use it:
`ai-tools-run` sources each enabled **integration**'s fragment, then the resolved **agent**'s,
so the agent's pins are authoritative over an integration's. See [launch](launch.rule.md) for
where that sits in the launch sequence.

This is where per-agent environment lives, rather than as manifest fields: an agent's pins are
arbitrary `KEY=value` shell, and a fragment is a mechanism the seam already has.

The seam is **best-effort**, not the fail-closed tier `msg.lib`/`confinement.lib` hold: a missing
or untrusted lib, directory, or fragment leaves the integration env empty and the confined launch
unaffected, because the integration env is additive, not load-bearing — "fail closed" here means
*no integration*. Everything it sources is gated by the trust rules
above; a fragment self-gates on its host tool, so it is inert on a host without the toolchain even
when enabled.

A fragment runs in `ai-tools-run`'s own scope, so it appends to the two arrays and stops there: it
must not exec, prompt, read stdin (the loop feeding it is on a process substitution), or depend on
the caller's environment, and it unsets its own temporaries. The **agent** fragment
(`source_session_env_fragment "${agent_name}"`) is sourced by a direct call in `ai-tools-run`'s main
shell rather than in that loop, which is what lets the two sanctioned exceptions below reach the
launch: an `export` it makes persists into the `systemd-run` invocation, and an `exit` it takes
refuses the launch (it runs before the unit is created and before the session-end sweep trap, so the
refusal is clean).

### A fragment may resolve operator configuration of its own

A fragment is where an agent turns operator configuration into session environment, and the
`claude-code` one does exactly that for a custom API endpoint (`claude-endpoint.lib.sh`). Two
properties of that pattern belong to the seam rather than to any one provider:

- **A credential is read sandbox-side and imported by name.** A token the *operator* cannot read
  (a `640 root:ai-tools` file, pointed at from `operator.conf`) is resolved in the fragment, which
  runs as the sandbox account, and forwarded as a name-only `--setenv=NAME` — the same
  value-off-the-command-line discipline `ai-tools-run` uses for the forwarded environment, and the
  reason `export` is a sanctioned fragment exception.
- **A configured-but-invalid option `exit`s the launch.** The fragment is sourced before the unit
  is created and before the session-end sweep trap, so an `exit` there is a clean fail-closed with
  no session started — the second sanctioned exception.

The endpoint's own keys, validation, precedence, and the boundary it does *not* claim are in
[agent-claude-code](agent-claude-code.rule.md).

## The `admin-commands.d` seam

The same shape one privilege level up: a provider package contributes its own **domain of
`ai-tools-admin`**, so `ai-tools-base` dispatches administration for integrations it ships without.
The spelling that surface takes — bare-word domains, the verb after the noun, and which names base
keeps — is in [cli-grammar](cli-grammar.rule.md); the mechanism is here.

A domain is an executable at `/usr/local/lib/ai-tools/admin-commands.d/<name>`, `0750 root:root`,
in a `0755 root:root` directory base owns. The basename is the domain token, the same `<name>` the
provider takes in `agents.d`/`integrations.d` and in `operator.conf`, so a host has one name for a
provider everywhere. `ai-tools-admin` discovers the set, and both its dispatch and its `--help` read
that one list:

- **Dispatch is an `exec`, not a `source`.** The fragment runs as its own process with the remaining
  arguments, keeping its own `set -euo pipefail`, root guard and logging, and cannot collide with
  the dispatcher's function names. It is also what keeps a fragment runnable directly — the dotnet
  package's `%post` execs its own at that path rather than through the dispatcher.
- **The gate is integrity, not enablement.** `ai_tools_conf_is_trusted` must hold for the fragment
  and for the directory; a basename outside `[a-z][a-z0-9-]*` is skipped before it is joined to a
  path; and a fragment claiming a base name is refused rather than merged. Every refusal is reported
  and leaves the command surface smaller. **Installation** is what makes a command exist, since
  `AI_TOOLS_INTEGRATIONS` decides what a confined *session* receives and an administrator
  configuring a provider is a different question — what a command *reports* still names the
  enablement state.
- **One untrusted entry refuses the whole set.** Per-file skipping alone would run the entries that
  still pass and leave a root-executable file the sandbox account can rewrite sitting where root
  looks for commands, with no finding obliging anyone to act. Base's own commands are unaffected, so
  the host stays administrable, and the refusal names the remedy: a packaged command installs
  root-owned and unwritable by anyone else, so that state is either a command installed by hand or a
  change to the host — `rpm -qf` names the package to reinstall, and how the file came to be
  writable is worth knowing. Re-permissioning it in place is **not** the remedy: it would re-bless
  content whoever could write the file may already have rewritten.
- **The summary is manifest data.** `--help` prints each domain with the `admin_summary` from that
  provider's manifest, read through `ai_tools_provider_manifest_field` (which applies the trust
  predicate and the same name allowlist as `ai_tools_agent_manifest_field`). No fragment is
  executed to ask it what it is, so building the help reads manifests alone and does not run
  contributed code.
- **`system bootstrap --scope full` iterates the enabled set** and runs each enabled integration's
  own `bootstrap` through this seam, reporting an enabled integration that contributes none. That is
  the one place the two gates meet: installation decides the command exists, enablement decides it
  is run.

The 0750 fragment mode and the world-readable directory answer two different questions: the agent
must not read or run a root command, while `--help` — answered ahead of the root check — must list
the same domains for any caller that the dispatch would accept.

### The interface a contributed command declares

Trust decides *who wrote* a fragment; the declaration decides whether the file is a command of this
seam at all. It is a **conformance contract, not a security boundary** — what stops a file the agent
wrote is the trust predicate — and it is read, never executed, so a report is built by reading alone,
without forking or running the fragment. A conforming fragment is a script (`#!`) carrying three declarations
in its first 20 lines:

| declaration | what it states |
|---|---|
| `# ai-tools-admin-command: <domain>` | the domain it is installed as |
| `# ai-tools-admin-api-min-version: <major>.<minor>` | the least interface version it needs from `ai-tools-admin` |
| `# ai-tools-admin-verbs: <verb> ...` | the top-level verbs it answers (the shared list grammar) |

Each does work base would otherwise have to guess at:

- **`command`** makes a fragment self-identifying, so a root-owned executable that merely ends up in
  the directory — a stray tool, an editor's backup, one provider's command copied under another
  provider's name — does not claim to be a command and is not run as one.
- **`api-min-version`** is a **floor**, not a stamp of what the fragment was built against: a
  provider ships in a package that upgrades independently of base and does not re-declare it per
  release, so `1.0` means "any `ai-tools-admin` implementing 1.0 or later can run me" and stays true
  as this project moves. `ADMIN_COMMAND_API` is the single version base holds, and the comparison is
  the one Apache httpd makes against a module's Module Magic Number: the **major must match** (a
  different major is a different contract) and the **minor must be at least** the declared floor.
  Retirement therefore lives in the major digit rather than in a second constant. A minor revision
  only adds — base learning to *call* a new verb is additive, since a fragment that does not declare
  it is skipped — so a breaking change is the only thing that moves the major, and a provider adding
  a verb *to itself* moves neither digit.
- **`verbs`** is a capability list base **reads rather than probes**: `system bootstrap --scope full`
  asks whether a provider has a `bootstrap` before running anything, so an integration whose commands
  are something else is reported as having no provisioning to do rather than as having failed. It is
  not argument validation — what a verb accepts is the fragment's own dispatch to answer, and a base
  second-guessing it would drift out of agreement with it.

There is deliberately no date and no "written against" version: the package that installs the
fragment carries both, and a hand-maintained copy of either would drift from it.

Beyond the declaration, a contributed command holds the conventions every command on this binary
does — it refuses a non-root caller, answers `--help` ahead of that refusal, exits `0`/`1`/`2` on
the same split `ai-tools-admin(8)` documents, and keeps a `bootstrap` idempotent and answerable
without a terminal, since full-scope provisioning runs it unattended. Those are behaviour rather
than text, so they are contracted here and asserted by the provider's own tests.

## The integration this project ships

`dotnet` (`ai-tools-integration-dotnet`) is the one member package of the integration kind. It
uses every seam above — a manifest with `default_enable=no`, a session-env fragment, a filter rule
set, and a contributed `dotnet` domain — and what each of those does for .NET, together with the
SELinux groups the runtime needs under enforcing, is in [dotnet](dotnet.rule.md).

## Boundaries

Two limits of this seam are deliberate, stated so neither reads as an oversight:

**The provider namespace is flat.** A name is unique host-wide, not per kind: an agent and an
integration both called `foo` are one token in two different gating keys and share one fragment,
`session-env.d/foo.env.sh`. Every manifest and fragment is root-owned, so a collision is a
packaging mistake — a provider cannot capture another's fragment without root — which makes it a
correctness wart rather than a hole, and a naming convention (`ai-tools-agents-<name>` /
`ai-tools-integration-<name>`, so the clash is visible where it would be made) the lightest
mechanism that answers it. No enforcement code.

**An agent is an npm package on the sandbox's Node toolchain.** `npm_package` is in practice
required (a manifest lacking it does not provision an agent), `ai-tools-bootstrap`/`nvm-update` install it
with `npm install -g`, and `ai-tools-run` accepts an executable only under
`/opt/ai-tools/.nvm/versions/node/<semver>/bin/`. That assumption lives in exactly two places —
**provisioning** (which command installs the agent and where its launcher lands) and **exec
validation** (which paths may start a session) — and nowhere else in the seam.

### Fitting a second agent runtime

A non-npm agent is an open direction, not a closed one: the host-managed .NET toolchain already
sits in this seam as an integration, so a thin .NET agent is the near case. What it would add, and
what it would leave alone:

- **A `runtime` field on the agent manifest** (`nodejs` when absent, so today's manifests are
  unchanged) selecting both halves of the assumption above. `npm_package` becomes the `nodejs`
  runtime's provisioning key rather than a universal one.
- **An exec root and a launcher shape per runtime.** The current rule is `<nvm>/versions/node/
  <semver>/bin/<launcher>`; the version directory pins the launcher to the toolchain version the
  updater installed. A dotnet global tool has no version directory, so its rule is its own exec
  root (`/opt/ai-tools/integrations/dotnet/tools/<launcher>`, root-owned and read-only to the agent — stricter
  than the nvm tree, which the sandbox account owns).

  A **host-packaged** runtime has neither property and must not be expressed as a root at all. Its
  binary lands in a shared system directory (`/usr/bin`), so admitting that directory as a prefix
  would let a manifest name any binary on the host — `/usr/bin/sudo` — as its entrypoint and have
  `relabel.lib.sh` grant it `ai_tools_exec_t`, the confined domain's exec entrypoint. The rule for
  such a runtime is therefore **exact-path**: one file, `/usr/bin/<launcher>` for that manifest's
  own claimed `launcher`, with no pattern language. So this is a containment rule **per runtime**,
  not one more entry in a list of roots, and the host-packaged rule is *stricter* than today's.

  What every rule must keep is the property the current one carries: an absolute, `..`-free path
  whose launcher an **enabled manifest claims**, decided only by input the agent cannot write — so
  a file the agent drops beside a launcher cannot start a session.
- **A provisioning branch** for that runtime (`dotnet tool install --tool-path` in place of
  `npm install -g`), invoked from the same enabled-agent loop `ai-tools-bootstrap` and
  `nvm-update` already run.
- **Its SELinux entrypoint file-context**, which the manifest already carries per agent, so a new
  entrypoint takes `ai_tools_exec_t` without touching the base policy.

Unchanged: enablement and its fail-closed trust rules, the `session-env.d` fragment (a .NET agent
inherits the dotnet integration's `DOTNET_ROOT`/NuGet-cache pins by enabling it), the `handback`
capability (an agent with no hook system declares `handback=none` and gets the shim's session-end
sweep), its own `config_dir` (mode, label, and ownership already follow the manifest), the
confinement unit, and the single `%ai-ops` sudoers grant.

None of it is built. The fields are named here so the first non-npm agent adds a runtime to the
seam rather than reshaping it.
