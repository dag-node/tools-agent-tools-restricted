---
paths:
  - tests/**
---

# Test organization and invariants

Tests live under `tests/`, split by category, with one shared harness. `tests/run.sh
[unit|integration|boundary|all]` dispatches; every category needs root, so it is invoked
via `sudo` (the harness derives the unprivileged project user from `SUDO_USER`). It streams
each file's output live, then — on any failure — reprints the failing files and their `FAIL`
lines as an end-of-run summary, so a long run needs no scrolling; an all-green run prints no
summary and exits zero. A green file that recorded no `PASS` (every check skipped, or no
harness result line) and a category with no test files are listed in an end-of-run
`no coverage` notice, parsed from `finish()`'s result line: green-by-exit-status alone cannot
hide a run that proved nothing. The default stays lenient — a partial/dev install
legitimately skips — and `AI_TOOLS_TEST_STRICT=1` turns the notice into a failure. Strict is
the enforcing-host full-install gate (`sudo AI_TOOLS_TEST_STRICT=1 tests/run.sh all`); the
container selftest stays lenient because SELinux is legitimately absent there, so
`selinux.sh`'s all-skip is a documented limitation, not a broken prerequisite.

```
tests/
  lib/harness.sh   result counters, perm(), check_file(), the /tmp testdir + dummy-allowlist fixtures, teardown
  run.sh           dispatcher; aggregates by exit status
  unit/            hermetic helper-logic tests
  integration/     full-install checks (needs a deployed, running system)
  boundary/        confinement checks run as the agent (SANDBOX_USER)
```

The SELinux AVC bring-up tooling is **not** part of this suite: it lives with the policy it
supports, under `selinux/avc/` (`run.sh` does not dispatch it).

## Hermeticity contract

Every test works **only inside its own dedicated `/tmp` testdir** (`mktestdir` sets
`TESTDIR`), builds its fixtures there with **known content defined in the test**, never
reads or writes the operator's real files (notably the real
`~/.config/ai-tools/allowed-projects`), and removes everything it created on exit (the
harness `EXIT` trap). A test never relies on arbitrary pre-existing state, and never
touches a path outside its testdir boundary.

The deployed root helpers read a fixed allowlist path; a test points them at its own dummy
allowlist via the `AI_TOOLS_ALLOWLIST` environment override (`mk_allowlist` writes the
dummy and exports it). This override is a **root-only test hook**: `sudo` strips it
(`env_reset`, and it is not in `env_keep`) and the handback daemon execs the helpers with
its own environment, so neither the operator nor the agent can inject it in production —
only a root caller that sets the env and execs a helper directly (the test suite) can
redirect it.

The harness redirects the helpers' root-only **file log** the same way: it exports
`AI_TOOLS_LOG_DIR` (the third root-only hook, same rationale as `AI_TOOLS_ALLOWLIST`) at a
throwaway `/tmp` dir cleaned up on exit, so a helper a test execs directly writes its
`chown.log`/`setgid.log`/… lines there instead of appending to — or raising spurious
`ERROR` lines in (a negative-path test feeds a helper `/etc/passwd`, a missing group, a
bogus version) — the production `/var/log/ai-tools` trail. A helper the **live daemon**
execs (`integration/handback.sh`) keeps the real dir, since the daemon does not inherit the
override — the same limitation as `AI_TOOLS_ALLOWLIST`. The journald sink is unaffected, so
every line is still queryable by its per-component tag.

## Two-ended assertions

A security guarantee is covered by a **pair** of tests, not one, and the pair is what makes the
coverage meaningful:

- a **runtime** assertion that the refusal fires — drive the deployed code into the bad state
  (an untrusted config, a mislabelled entrypoint, a path outside the allowlist) and assert it
  resolves to *less* access and says so;
- a **boundary** assertion, executed **as the agent**, that the bad state is unreachable — the
  agent cannot write the file, directory, or binary whose corruption the refusal exists to catch.

Neither is sufficient alone. The runtime half catches a host someone has already broken (an
operator's `chmod`, a botched install, a tamper); the boundary half catches the agent trying to
break it. A guarantee with only the first is untested against its actual adversary; one with only
the second silently stops refusing the day the predicate regresses.

The provider seam is the worked example: `unit/providers.sh` drives each untrusted input through
the resolver and asserts the fail-closed verdict, while `boundary/providers.sh` probes the same
deployed files as the sandbox account and asserts none of them is agent-writable. A new guarantee
lands with both halves, in the category each belongs to.

## Categories

**`unit`** — hermetic logic tests of the deployed helpers (`ai-tools-chown`, `-setgid`,
`-setfacl`, `-unclaim`, `-safedir`, `-reclaim`, `-lockdown`). Each runs the **installed** helper (so it exercises
the real, token-substituted artifact) against a `/tmp` testdir and a dummy allowlist,
asserting the algorithm: allowlist gating, the owner guard (acts only on projects-user- or
sandbox-account-owned paths) where it applies, ACL/setgid/permission transforms, the
secret/exclusion/skip-list skips, and -- for `-lockdown` -- the proactive sweep that locks
**pre-existing user-owned** secrets (files `600`, dirs `700`, `<you>:SANDBOX_GROUP`) which
the reactive `-chown` never reaches, plus its refusal to run as the sandbox account. No live
daemon, no SELinux dependency, no wrapper. Run as root (needed to set arbitrary ownership
and create third-party-owned fixtures). A fixture tree is `chown`ed to the projects user
before the run, or the owner guard skips it. `secret-patterns.sh` is the odd one out: it
sources the shared classifier library (`secret-patterns.lib.sh`) and forces the built-in
default pattern set, pinning the matcher itself — credential names match case-insensitively,
while plain configs and build artifacts the toolchain must read do not. `check-version.sh`
departs the installed-helper pattern the other way: it runs a `TESTDIR` copy of
`packaging/check-version.sh` (a repo release-gate script, not a deployed artifact) against
fixture `VERSION`/spec files, pinning the tag grammar — final `vX.Y.Z` requires the
three-way match, `vX.Y.Z-rc.N` compares its base and relaxes only the `%changelog` match,
any other dashed tag is refused, a missing `%changelog` entry is fatal for every form.
`man.sh` is a pure text-sync check: the long-option sets of the CLI's `usage()` heredoc
and the `ai-tools(1)` man page must match in both directions (see [cli](cli.rule.md)),
validated from the repo sources (or the installed pair outside a checkout) without
executing the CLI.

`conf.sh` and `providers.sh` are the library pair behind the provider seam (see
[providers](providers.rule.md)). `conf.sh` pins the shared `KEY=value` grammar every
`operator.conf` key and every manifest is read with — quotes optional, commas and whitespace
both separating, inline comments ending a value, a present-but-empty key distinguishable
from an absent one — plus two properties whose breakage is silent in production: the
splitter must be **IFS-independent** (it is sourced into scripts that set `IFS=$'\n\t'`,
where an inherited IFS collapses a multi-item value into one bogus item), and
`ai_tools_conf_is_trusted` must refuse every state a non-root writer can create
(non-root-owned, group- or other-writable, a symlink), for directories as well as files.
`providers.sh` drives the enablement truth table and then, for each untrusted input in turn
— `operator.conf`, a manifest, a manifest directory — asserts the resolver moves to *less*
access and says so, never more.

`relabel.sh` pins the other manifest-supplied decision with a security consequence: the
entrypoint file-context predicate (`relabel.lib.sh`). A declared pattern becomes a `semanage`
rule granting `ai_tools_exec_t`, the confined domain's exec entrypoint, so the test drives every
way a pattern could name something outside the sandbox toolchain (traversal, alternation, a
foreign prefix) and asserts each is refused — plus that the type is the library's constant, never
manifest-supplied.

`selinux-groups.sh` pins the optional-group registry (`selinux-groups.lib.sh`, shared by
`ai-tools-admin selinux` and `install-selinux.sh`): the four-field accessors (including the
`stability` field, guarding the regression where a fourth pipe field bleeds into the reason), the
validity predicate the `enable-group` gate depends on (an unknown name is rejected), and the
`is_experimental` predicate agreeing with the field (it decides whether `enable-group` loads a
shipped module or refuses and points to the source workflow). And — because only **stable** groups
ship prebuilt — registry↔filesystem lockstep: every registered group has a `.te` source; a
**stable** group additionally has a **committed** `.pp` while an **experimental** group must have
**no committed** `.pp` (source-only, so a compiled dev copy left tracked is caught); and no policy
module on disk is missing from the registry. The lockstep half reads git track-state, so it needs
the checkout.

**`integration`** — checks that need a completed install and the running system
(`perms.sh`, `wrapper.sh`, `hooks.sh`, `symlink-helper.sh`, `handback.sh`, `cli.sh`,
`ai-tools-run.sh`, `systemd.sh`, `selinux.sh`): installed-artifact ownership/modes, sudoers
syntax, the wrapper launched end-to-end (its allowlist gate, `!`-exclusion refusal,
fail-closed load of `safe-paths.lib.sh`, and consultation of the protected-paths backstop on
the launch CWD), the handback `socket → daemon → helper` chain (including its negative paths —
unknown verb, wrong/empty/non-absolute/control-character args, and an out-of-allowlist CHOWN
all refused), the CLI principal guard (refuses root and the sandbox account), `ai-tools-run`'s
`AI_TOOLS_AGENT_EXEC` / `AI_TOOLS_PROJECT_DIR` re-validation (a bad value is refused before any
session launches — including a real sibling binary in the same versioned `bin` directory, which
is refused because no enabled agent manifest claims that launcher, and a non-semver version
directory) plus its pinned session-confinement properties
(`RestrictNamespaces`/`NoNewPrivileges`/`UMask`), the claude-code session-env pins
(`DISABLE_AUTOUPDATER`, `CLAUDE_CONFIG_DIR`, `NODE_COMPILE_CACHE` — asserted by **sourcing** the
fragment into the two arrays it is contracted to append to, so a fragment that stops appending or
appends to a renamed array fails rather than silently costing the session its environment), the
`settings.json` hook + deny-rule declarations, and SELinux labels (the `claude.exe` entrypoint and the handback daemon
binary). Every assertion about the shim lives in `ai-tools-run.sh` beside it — its input
validation, the unit properties it pins, and the session env it sources — so a change to the
shim has one file to answer to; `handback.sh` keeps the bridge and the entrypoint label.
`selinux.sh` asserts the confinement layer is actually enforcing: when the
`ai_tools` module is loaded the system is `Enforcing` and neither `ai_tools_t` nor
`ai_tools_handback_t` is marked permissive; it skips when the module is absent (the layer is
optional). `systemd.sh` is the single home for unit checks:
`systemd-analyze verify` on each shipped unit, plus enablement in the correct instance —
the `nvm-update` timer in the sandbox account's own `--user` instance, the relabel watcher
and handback socket in the system instance. The
handback chain cannot use the `AI_TOOLS_ALLOWLIST` override — the live daemon execs helpers
with its own environment, so the helper reads the **real** allowlist. The hooks test puts its
fixtures in a self-cleaning subdir **inside the project the suite is run from**, reusing that
project's existing allowlist entry (the session runs in it); it confirms the run-dir is
allowlisted and **skips** otherwise, and under enforcing labels the fixture
`ai_tools_project_t` so the confined chown can act on it. The wrapper test stays hermetic by
pointing `HOME` at a `/tmp` testdir (the wrapper keys its allowlist off `${HOME}`) and runs
the wrapper under `setsid`, so it never touches the real allowlist or fires a claim prompt.
Run as root.

`perms.sh` is the **single source** for the deployed-artifact permission assertions (every
installed file and directory's owner/group/mode): `install.sh` carries no parallel checker —
`sudo ./install.sh check-perms` execs `perms.sh`, and the install's verification phase reaches
it through `tests/run.sh all`. Adding or repermissioning an installed file means updating the
`check_file` list here, nowhere else.

**`boundary`** — confinement assertions executed **as the agent** (`sudo -u SANDBOX_USER`)
(`access.sh`, `providers.sh`, `sudo.sh`): the agent cannot read the secret-pattern library or write the
control plane, cannot reach the operator's credential stores (`~/.ssh`, `~/.gnupg`, …), and
holds no sudo rights — `sudo -l` reports it is not allowed to run sudo at all (both NOPASSWD
rules belong to the projects user and drop privilege), plus the account hygiene that invariant
leans on (nologin shell, locked password, non-membership in `ai-ops`). `providers.sh` asserts
the deployed half of "the sandbox cannot widen its own surface": none of `operator.conf`,
`conf.lib.sh`, `providers.lib.sh`, the three provider directories, the manifests and fragments
in them, or the `ai-tools-run` shim and the `bin` directory holding it is agent-writable, while
the NuGet restore cache the dotnet integration needs
**is** — both directions matter, since a read-only cache breaks the integration as surely as a
writable tools dir breaks the boundary. It is the counterpart to `unit/providers.sh`, which
asserts the runtime refusal; this one asserts the agent cannot reach the state that refusal
exists to catch. These probe **DAC and
account state** from the sandbox account's vantage — they run as the sandbox *user*, not inside
the `ai_tools_t` SELinux domain (a launched session), so they assert the filesystem/credential
boundary; the SELinux enforcing posture is asserted separately in `integration/selinux.sh`.

## Quirks

- **Setgid bits survive numeric `chmod`.** GNU coreutils `chmod` with an octal mode does
  not clear a directory's setgid/setuid bit; a testdir under a setgid parent inherits it.
  Assertions on the rwx bits use `perm()` (low 3 octal digits), not raw `stat %a`.
- **The wrapper prompts on `/dev/tty`, not stdin.** `</dev/null` does not suppress it;
  `setsid` (no controlling tty) does, so the wrapper takes its non-interactive default.
- **The wrapper keys off `${HOME}`** for the allowlist, so its test mocks the allowlist by
  pointing `HOME` at a `/tmp` testdir — no helper override needed there.
- **The wrapper detects a controlling terminal by opening `/dev/tty`,** not by the node's
  permission bits (which read `rw` even with no controlling tty). Under `setsid` the open
  fails, so every wrapper invocation in a test cleanly skips the claim prompt instead of
  acting on it — the integration wrapper test relies on this to never claim a project.
- **The handback path cannot cross `/tmp`.** `/tmp` and `/var/tmp` are polyinstantiated per
  session by `pam_namespace` (`/etc/security/namespace.conf`), so a fixture the test creates
  under `/tmp` is invisible both to the hook's own `sudo -u SANDBOX_USER` session (a fresh,
  empty `/tmp` instance) and to the host-namespace handback daemon — the hand-back silently
  no-ops. Any test that drives the live `hook → daemon → helper` chain puts its fixtures
  under the projects user's `${HOME}` (shared across namespaces), not in a `/tmp` testdir.
