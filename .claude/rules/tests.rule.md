---
paths:
  - tests/**
---

# Test organization and invariants

Tests live under `tests/`, split by category, with one shared harness. `tests/run.sh
[unit|integration|boundary|all]` dispatches; every category needs root, so it is invoked
via `sudo` (the harness derives the unprivileged project user from `SUDO_USER`).

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

## Categories

**`unit`** — hermetic logic tests of the deployed helpers (`ai-tools-chown`, `-setgid`,
`-setfacl`, `-unclaim`, `-lockdown`). Each runs the **installed** helper (so it exercises
the real, token-substituted artifact) against a `/tmp` testdir and a dummy allowlist,
asserting the algorithm: allowlist gating, the owner guard (acts only on projects-user- or
sandbox-account-owned paths) where it applies, ACL/setgid/permission transforms, the
secret/exclusion/prune skips, and -- for `-lockdown` -- the proactive sweep that locks
**pre-existing user-owned** secrets (files `600`, dirs `700`, `<you>:SANDBOX_GROUP`) which
the reactive `-chown` never reaches, plus its refusal to run as the sandbox account. No live
daemon, no SELinux dependency, no wrapper. Run as root (needed to set arbitrary ownership
and create third-party-owned fixtures). A fixture tree is `chown`ed to the projects user
before the run, or the owner guard skips it. `secret-patterns.sh` is the odd one out: it
sources the shared classifier library (`secret-patterns.lib.sh`) and forces the built-in
default pattern set, pinning the matcher itself — credential names match case-insensitively,
while plain configs and build artifacts the toolchain must read do not.

**`integration`** — checks that need a completed install and the running system
(`perms.sh`, `wrapper.sh`, `hooks.sh`, `symlink-helper.sh`, `handback.sh`, `cli.sh`,
`claude-run.sh`): installed-artifact ownership/modes, sudoers syntax, the wrapper launched
end-to-end, the handback `socket → daemon → helper` chain (including its negative paths —
unknown verb, non-absolute arg, and an out-of-allowlist CHOWN all refused), the CLI
principal guard (refuses root and the sandbox account), `claude-run`'s `CLAUDE_EXEC` /
`CLAUDE_PROJECT_DIR` re-validation (a bad value is refused before any session launches),
systemd units, and SELinux labels. The
handback chain cannot use the `AI_TOOLS_ALLOWLIST` override — the live daemon execs helpers
with its own environment, so the helper reads the **real** allowlist. The hooks test puts its
fixtures in a self-cleaning subdir **inside the project the suite is run from**, reusing that
project's existing allowlist entry (the session runs in it); it confirms the run-dir is
allowlisted and **skips** otherwise, and under enforcing labels the fixture
`ai_tools_project_t` so the confined chown can act on it. The wrapper test stays hermetic by
pointing `HOME` at a `/tmp` testdir (the wrapper keys its allowlist off `${HOME}`) and runs
the wrapper under `setsid`, so it never touches the real allowlist or fires a claim prompt.
Run as root.

**`boundary`** — confinement assertions executed **as the agent** (`sudo -u SANDBOX_USER`)
(`access.sh`, `sudo.sh`): the agent cannot read the secret-pattern library or write the
control plane, the sandbox account holds no sudo rights (both NOPASSWD rules belong to the
projects user and drop privilege), an `ai_tools_t` process is denied what the policy
forbids, etc. These deliberately probe the current environment from the sandbox account's
vantage point.

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
