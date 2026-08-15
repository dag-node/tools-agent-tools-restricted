---
paths:
  - "selinux/policy/*.te"
  - "selinux/policy/*.fc"
  - "selinux/policy/Makefile"
  - "selinux/install-selinux.sh"
  - "packaging/ai-tools.spec"
  - "selinux/README.md"
  - "src/opt/ai-tools/bin/ai-tools-run.sh"
  - "src/usr/local/lib/ai-tools/confinement.lib.sh"
  - "src/usr/local/lib/ai-tools/selinux-groups.lib.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
---

# Session confinement (namespaces, SELinux, `/tmp`)

The kernel-level isolation `ai-tools-run` applies to each session unit, the SELinux
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
cannot observe its successor's post-`exec` domain, so `ai-tools-run` probes the
transition's inputs *before* launch: the entrypoint's label (`matchpathcon` vs
`stat -c %C`), the `systemd --user` manager's domain (`/proc/<pid>/attr/current`), and
whether the core module's **file-contexts are live** — probed with `matchpathcon` on a
core-owned path (`/opt/ai-tools/.config` resolves to `ai_tools_home_t` only when the module
is loaded), classified by `ai_tools_confinement_module_present`. It is **not** read from the
module store with `semodule -l`: `ai-tools-run` runs as the sandbox account, which cannot read
the root-only store, so that read is a systematic false "no" — which on the unresolved-label
branch below would fail *open* (launch DAC-only where the module is actually loaded). The
`matchpathcon` probe reads the world-readable file-contexts, needs no privilege, and the agent
cannot influence it (file-contexts and the shim are root-owned). It logs the inputs on
every launch (journald, `ai-tools-run` tag). `ai-tools-run` performs that probing and I/O;
the launch-vs-refuse decision is the pure `ai_tools_confinement_verdict`
(`confinement.lib.sh`), so the policy is unit-tested apart from the probing
(`tests/unit/confinement.sh` drives the truth table with no SELinux host).

The decision is **fail-closed once confinement is expected**. When SELinux is enforcing
and the module's file-contexts are active (`matchpathcon` resolves the entrypoint to
`ai_tools_exec_t`), it refuses to launch if the binary's live label is not
`ai_tools_exec_t` (→ `relabel`) or the manager domain is not one `ai_tools.te` has a
`domtrans_pattern` for (→ add the rule, `rebuild`; this one is advisory — an unreadable
domain does not block). When SELinux is enforcing but the label does **not** resolve, the
verdict splits on module presence: **module present** (the core file-contexts are live but the
entrypoint carries no `ai_tools_exec_t` rule — the agent's fcontext was never registered) means
confinement is installed yet the transition is unverifiable, so it refuses (`unverifiable`, →
`ai-tools --relabel` / `install-selinux.sh install`) rather than launch DAC-only and silently drop
confinement; **module absent** means the SELinux layer was never installed here, so it launches
(an intentional DAC-only deployment, cleared for a staged host with `semodule -r ai_tools` or
permissive mode). The check is a no-op where SELinux is not enforcing, so DAC-only and permissive
boxes are unaffected.

One residual the `matchpathcon` probe cannot see: a module **staged in the store but with its
file-contexts never loaded** into the running policy reads as "absent" (the core-owned path resolves
to its default type), so that narrow half-installed state launches DAC-only rather than refusing.
Detecting it requires reading the store, which the sandbox account cannot do — no unprivileged probe
can — and it is vanishingly rare (a normal `semodule -i` loads store and policy together). It is no
worse than the previous `semodule -l`-as-sandbox read, which reported "absent" for **every** host.

## `/tmp` model

`PrivateTmp` is not used; the session shares the host `/tmp`. systemd `PrivateTmp` is a
no-op for an unprivileged `--user` manager: it cannot pivot a private `/tmp` for the
payload (the unit starts, but the payload still sees the shared `/tmp` — claude's
runtime dir stays visible and no private bind mount appears in the payload's
`mountinfo`). claude keeps its runtime at a fixed `/tmp/claude-<uid>`, does not honour
`TMPDIR`, and reuses the dir across sessions. `ai-tools-run` does not touch that
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

The optional groups (`systemd`/`pkgmgmt`/`netadmin`/`podman`/`tmpmap`/`apphost`/`netcore`) are all off by
default and each carries a **stability** field in the registry (`experimental`/`stable`)
that decides how it is shipped and enabled. Both front doors draw the group set, descriptions,
and stability from one place — `selinux-groups.lib.sh`, so they cannot disagree:

- **Stable** groups (a single, tested rule, e.g. `tmpmap`) ship **prebuilt**
  (`ai_tools_<group>.pp`) alongside the core in `/usr/share/selinux/packages/ai-tools/`, and
  `sudo ai-tools-admin selinux enable-group <name>` `semodule`-loads the prebuilt `.pp` on an
  installed host, needing no source tree or `selinux-policy-devel`. `list-groups`/`disable-group`
  round it out (`disable-group` works for any loaded group).
- **Experimental** groups are unaudited drafts and are **not shipped prebuilt**;
  `ai-tools-admin enable-group` refuses one and points at the source workflow rather than
  loading an unaudited module. They are compiled and verified from a source checkout —
  `sudo selinux/install-selinux.sh enable-group <name>` (which compiles from `.te`/`.fc`, then
  loads) plus the `avc/` bring-up loop. Promoting one to stable means marking it `stable` in the
  registry, committing its prebuilt `.pp`, and adding it to the shipped set (spec, `install.sh`,
  `.gitignore`, `packaging/Makefile`).

Enabling an optional policy group widens what SELinux permits but does not lift the seccomp
filter. Of the optional groups only
`podman` creates namespaces (rootless containers need user+mnt+pid+ipc+net+uts), so
`RestrictNamespaces=yes` blocks it even with the podman group loaded — the SELinux grant
is necessary but not sufficient. Supporting rootless podman means re-allowing the user
namespace, which *is* ESC-001, so it is not a clean partial relaxation. `ai-tools-run`
emits an actionable NOTICE at launch when the podman group is loaded while the filter is
active.

After editing policy source, rebuild and reload the loaded module with
`sudo selinux/install-selinux.sh rebuild`.

## How the policy ships

The policy is its own subpackage, `ai-tools-selinux`, and `ai-tools-base` **recommends** it. Two
independent properties meet at that boundary:

- **Licence.** A compiled `.pp` embeds macro expansions from the SELinux reference policy, so it is
  `GPL-2.0-or-later` while the rest of the stack is `AGPL-3.0-only`. The `.te`/`.if`/`.fc` sources
  carry the same identifier (they call refpolicy interfaces that expand on compile); the surrounding
  tooling — `install-selinux.sh`, `selinux/avc/*.sh`, `selinux-groups.lib.sh` — is `AGPL-3.0-only`,
  holding no refpolicy content. The subpackage conveys the GPL text via `%license`, and the source
  tarball carries the policy sources and their `Makefile` so the SRPM accompanies each `.pp` with
  its corresponding source; `make dist` asserts that pairing and refuses to produce a tarball
  without it.
- **Degradation.** The weak dependency is what `ai_tools_confinement_verdict` already expects: a
  host without the subpackage has no module in the store, which is the intentional DAC-only
  deployment that launches, not the half-installed state that refuses. Dropping the policy costs
  confinement and nothing else.

The load and unload scriptlets live in the subpackage, with the payload, so no cross-subpackage
ordering question arises. `%post` runs `semodule -i` — into the running kernel policy, not only the
module store, since the entrypoint cannot be labelled until the module's types exist in the kernel —
at the default module priority, the same slot `install-selinux.sh` and `ai-tools-admin` address, so a
host holds one copy of each module. After the module load, `%post` also `restorecon`s the trees
that carry `ai_tools*` types (the handback daemon among them) and, when the handback socket is
already active — an upgrade — refreshes the live listener: `restorecon` fixes the daemon binary's
on-disk label, but the socket bound on tmpfs `/run/ai-tools` keeps its stale context and its
per-connection handler keeps running `unconfined_service_t`, so `daemon-reexec` + a socket restart
re-derive the listener context from the now-correct binary label (the same sequence
`install-selinux.sh` `_relabel_runtime` runs; see [handback-bridge](handback-bridge.rule.md)).
Without it a session's `connectto` to the handback socket is denied under enforcing and every hook
handback silently no-ops. On a fresh install the socket is not up yet — `ai-tools-base` `%posttrans`
starts it later, already correctly labelled — so the refresh no-ops there. `%postun` on final erase unloads every loaded `ai_tools*` module,
enumerated rather than named: a group's `.pp` is erased with the package while the compiled module
persists in the store, and a group compiled from a source checkout was never in the rpm database at
all.

The `%selinux_*` rpm macros are not used. `%selinux_requires` records the build host's
`selinux-policy` version as a `Requires`, which a `noarch` package cannot satisfy across both EL
targets; `%selinux_modules_install`/`_uninstall` operate at priority 200, splitting the module slot
against the two source-tree tools, and the uninstall half removes only the modules it names, which
would strand any group enabled on the host.
