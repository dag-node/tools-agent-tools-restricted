---
paths:
  - "selinux/**"
  - "src/opt/ai-tools/bin/claude-run.sh"
---

# Session confinement (namespaces, SELinux, `/tmp`)

The kernel-level isolation `claude-run` applies to each session unit, the SELinux
domain transition that confines it, and the `/tmp` model. Launch mechanics
(env, WorkingDirectory, sudoers) are in [launch](launch.rule.md).

## `RestrictNamespaces=yes` — the namespace filter

`RestrictNamespaces=yes` installs a seccomp filter blocking creation and joining of
every namespace type for the entire session process tree. This is the minimal
allow-list, and the set the agent needs is empty: an unprivileged process (the agent
holds no capabilities) can only ever create a *user* namespace by itself, since every
other type (`cgroup`/`ipc`/`mnt`/`net`/`pid`/`uts`) requires `CAP_SYS_ADMIN`, reachable
only *through* a user namespace. Blocking `user` blocks all the rest transitively;
`=yes` makes that explicit and, unlike a `~user` denylist, fail-closes against any
namespace type a future kernel adds.

The load-bearing effect is closing `clone(CLONE_NEWUSER)`: an agent-accessible user
namespace lets a process appear as uid 0 inside it — the precondition for exploiting
kernel bugs that require root-in-userns and for overlay mounts that confuse
application-layer access checks. seccomp runs at syscall entry, before the SELinux LSM
hook, so this is also the only *enforcing* layer for user-ns creation: SELinux cannot
block it on this policy (the `process2` class carries no `create_user_ns` permission;
see ESC-001 in `ai_tools.te`). SELinux type enforcement survives into any namespace, so
the residual risk is kernel-CVE surface, not file-access bypass.

System-wide user namespaces stay enabled (Firefox and rootless Podman need them); the
filter is per-session and touches no sysctl, so other workloads are unaffected. One
trade-off: `=yes` is incompatible with running unprivileged `bubblewrap` *inside* the
session (bwrap must create user+mnt namespaces), which the deferred bwrap phase must
resolve.

## `NoNewPrivileges` — explicit and always in effect

The unit sets `NoNewPrivileges=yes` for clarity, and the session runs under
`PR_SET_NO_NEW_PRIVS` regardless: `RestrictNamespaces=yes` installs its seccomp filter
via that flag, and NNP is a precondition for seccomp, not a setting the unit can opt
out of. The bounded `ai_tools_t` transition completes under NNP because the policy
grants `process2:nnp_transition` to the authorised source domains (`ai_tools.te`);
without that grant, setting NNP (explicitly or via the filter) sends the session
unconfined.

NNP drops `sudo`'s SUID bit, so the hooks reach root operations through the handback
socket bridge rather than `sudo` (see [handback-bridge](handback-bridge.rule.md)).

## SELinux domain transition

In `--pty` service mode the user manager performs the `exec`, so the SELinux
transition is keyed on the manager's domain — `init_t` on RHEL/Rocky 9 targeted — via
`domtrans_pattern(init_t, ai_tools_exec_t, ai_tools_t)` in `ai_tools.te` (an
`unconfined_t` rule is retained for a direct exec). The live manager domain and its
role are verifiable on the box (`ps -eZ | grep 'systemd --user'`); the policy
authorises both `unconfined_r` and `system_r` for `ai_tools_t`, so the transition fires
regardless of which role the manager holds. The manager's domain also needs `search` on
`ai_tools_project_t` for the `WorkingDirectory` chdir.

### Fail-closed confinement preflight

A session that fails to transition into `ai_tools_t` runs *unconfined*, and because
`ai-tools` maps to `unconfined_u` the module cannot forbid that (the ESC-001 base-policy
floor; `user_u` was rejected because it breaks the `ai-tools`→root sudo). A wrapper
cannot observe its successor's post-`exec` domain, so `claude-run` verifies the
transition's two inputs *before* launch: the entrypoint's label (`matchpathcon` vs
`stat -c %C`) and the `systemd --user` manager's domain (`/proc/<pid>/attr/current`).
It logs both on every launch (journald, `claude-run` tag). When SELinux is enforcing
and confinement is expected (the module's file-contexts are installed), it refuses to
launch if the binary is mislabelled (→ `relabel`) or the manager domain is not one
`ai_tools.te` has a `domtrans_pattern` for (→ add the rule, `rebuild`). The check is a
no-op where the SELinux layer is absent, so DAC-only and permissive boxes are
unaffected.

## `/tmp` model

`PrivateTmp` is not used; the session shares the host `/tmp`. systemd `PrivateTmp` is a
no-op for an unprivileged `--user` manager: it cannot pivot a private `/tmp` for the
payload (the unit starts, but the payload still sees the shared `/tmp` — claude's
runtime dir stays visible and no private bind mount appears in the payload's
`mountinfo`). claude keeps its runtime at a fixed `/tmp/claude-<uid>`, does not honour
`TMPDIR`, and reuses the dir across sessions. `claude-run` does not touch that
directory: removing it would race claude's exists-then-`mkdir` check against another
live same-uid session, failing startup with `EEXIST mkdir /tmp/claude-<uid>`.

The enforced `/tmp` isolation is ordinary Unix permissions plus the `ai_tools_tmp_t`
type: a dir claude creates is born `ai_tools_tmp_t` via the `tmp_t:dir` →
`ai_tools_tmp_t` type_transition, which `ai_tools_t` fully manages but which keeps it
off other domains' `tmp_t`/`user_tmp_t` files. Per-session `/tmp` isolation would
require a privileged (`--system`) manager that mounts and pivots `PrivateTmp` for the
payload during unit setup.

Node's V8 compile cache is the one piece of session scratch kept OUT of `/tmp` —
pinned to `ai_tools_home_t` via `NODE_COMPILE_CACHE` (see [launch](launch.rule.md)) — because
its default `/tmp/node-compile-cache` otherwise collides with `user_tmp_t` leftovers and
other uids, and an entry carrying `user_tmp_t` denies node's own `open()` under
enforcing, killing the session at startup.

### Optional `pam_namespace` polyinstantiation (host dependency)

Some hardened hosts additionally run `pam_namespace` polyinstantiation of `/tmp` and
`/var/tmp` (`/etc/security/namespace.conf`, e.g. `method=level`) — an optional,
non-default measure. The sandbox neither requires nor configures it, does not assume it
is present, and works correctly with or without it. When present, each SELinux level
gets its own `/tmp` instance bind-mounted into the session's mount namespace, adding
per-level isolation. Operational notes for that case:

- The instance is slave-propagated and invisible from the host init namespace; root
  reaches it only via `/proc/<pid>/root/tmp` of a live session (the
  `/tmp/tmp-inst/<context>_<user>` path does not resolve outside the namespace).
- It is keyed by level, not session, so same-level sessions still share one `/tmp` and
  serialise on `/tmp/claude-<uid>`.
- It lives in tmpfs and is cleared on reboot.
- A stale `user_tmp_t` dir left in the instance by an earlier unconfined run blocks
  startup under enforcing (`ai_tools_t` has no `user_tmp_t:dir` access → `EEXIST`); clear
  it via `/proc/<pid>/root/tmp` or a reboot.

## Optional SELinux groups and the namespace filter

Enabling an optional policy group (`install-selinux.sh enable-group <name>`) widens
what SELinux permits but does not lift the seccomp filter. Of the optional groups only
`podman` creates namespaces (rootless containers need user+mnt+pid+ipc+net+uts), so
`RestrictNamespaces=yes` blocks it even with the podman group loaded — the SELinux grant
is necessary but not sufficient. Supporting rootless podman means re-allowing the user
namespace, which *is* ESC-001, so it is not a clean partial relaxation. `claude-run`
emits an actionable NOTICE at launch when the podman group is loaded while the filter is
active.

After editing policy source, rebuild and reload the loaded module with
`sudo selinux/install-selinux.sh rebuild`.
