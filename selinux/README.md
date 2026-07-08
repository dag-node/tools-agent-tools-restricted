# Optional SELinux confinement — `ai_tools_t`

An extra **mandatory access control** layer for the Claude Code sandbox, separate
from and on top of the DAC (ownership/permission) model in the main install. It
confines the agent to its own SELinux domain with a **path boundary**:

| Type | Applied to | `ai_tools_t` may |
|---|---|---|
| `ai_tools_t` | the agent process (`claude.exe` as the `SANDBOX_USER` UID) | — |
| `ai_tools_exec_t` | the versioned `claude.exe` launcher | entrypoint (drives the transition) |
| `ai_tools_project_t` | approved project dirs (per allowlist) | read/write (incl. all git ops) |
| `ai_tools_home_t` | `/opt/ai-tools/.claude` | read/write its own state |
| everything else (e.g. other `/home` files = `user_home_t`) | — | **no access** once enforcing |

This is what stops the agent inadvertently touching **unrelated** files: once
`ai_tools_t` is enforcing, it can write `ai_tools_project_t` and `ai_tools_home_t`
but not `user_home_t`, `etc_t`, other users' files, etc. DAC still applies
underneath — both layers must allow an access.

## Enforcing by default, prebuilt

The core module ships **prebuilt** (`ai_tools.pp`) and **enforcing**, so a normal
install loads it with no toolchain. The transition **fails open** — if `claude.exe`
ever loses its label (e.g. a Node upgrade before `relabel`), no transition fires
and claude simply runs unconfined; it never breaks.

You cannot confine a complex app (Node + git + the Bash tool) correctly by
guessing rules — the rule set must be *observed*. The policy here was completed
that way: load **permissive** (`permissive ai_tools_t;` in `ai_tools.te`), log what
`ai_tools_t` does, fold those denials in, then remove that line to enforce. To
re-open that loop, uncomment `permissive ai_tools_t;`, recompile, and reload; the
installer detects the mode from the source and reports it.

## Layout

```
selinux/
  install-selinux.sh   load / rebuild / relabel / enable-group / remove (run from here)
  README.md            this guide
  policy/              policy source + the shipped prebuilt core
                         ai_tools.{te,fc,if}, the optional ai_tools_{systemd,pkgmgmt,
                         netadmin,podman}.{te,fc,if}, ai_tools.pp, Makefile,
                         helper-domain.te.draft; build scratch lands in policy/tmp/
  avc/                 bring-up + diagnostics (run during policy authoring)
                         avc-denials.sh, avc-testsuite.sh, avc-analyze.sh,
                         diag-nvm-update.sh; capture logs in avc/audits/, marker
                         avc/.avc-last-run
```

Filenames below (`ai_tools.te`, `ai_tools.pp`, …) live under `policy/`; the bring-up
scripts under `avc/`. `install-selinux.sh` stays at `selinux/` and resolves both.

## Building from source (optional)

The shipped core needs no toolchain. `selinux-policy-devel` is required only to
**recompile** the core after editing `ai_tools.te`/`.fc`, or to build an optional
group (groups are not shipped prebuilt):

```bash
sudo dnf install selinux-policy-devel
```

## 1. Load and label

```bash
cd selinux
sudo ./install-selinux.sh install
```

This loads the prebuilt `ai_tools.pp` (enforcing) — or recompiles it first if you
answer yes to the prompt — labels `/opt/ai-tools/.claude` (`ai_tools_home_t`) and
the `claude.exe` entrypoint, and labels every project in
`~/.config/ai-tools/allowed-projects` as `ai_tools_project_t`.

Verify:

```bash
semodule -l | grep ai_tools                 # module present
matchpathcon /opt/ai-tools/.claude          # -> ai_tools_home_t
claude --version                            # launch once
ps -eo label,cmd | grep -m1 '[c]laude'      # process label -> ...:ai_tools_t
```

## 2. Bring-up to enforcing (audit2allow loop)

While permissive, **exercise every path the agent uses**, so the kernel logs the
full rule set. Two scripts automate this — split by privilege, because the agent
can exercise the surface but cannot read the audit log, and root can read the log
but should not be the one acting as the agent:

```bash
# 1. AS THE AGENT, inside a confined claude in an approved project:
bash selinux/avc/avc-testsuite.sh     # create, modify, git (+ git mv), private temp,
                                  # secret-quarantine, allowed + denied network

# 2. AS <you> (root), once the turn ends (so the Stop sweep's NOTICE is logged too):
sudo bash selinux/avc/avc-analyze.sh  # splits denials into NEW vs EXPECTED BOUNDARY
```

`avc-testsuite.sh` **aborts unless it is running in `ai_tools_t`** — running it
unconfined would log nothing and the empty result would look like success. It
writes a start marker (`selinux/avc/.avc-last-run`); `avc-analyze.sh` reads it so
`ausearch -ts` starts at exactly the right instant. The analyzer classifies each
denial: **EXPECTED BOUNDARY** ones (the `user_home_t` / `config_home_t` /
non-`http_port_t` accesses `ai_tools.te` already `dontaudit`s) must stay denied,
and only the **NEW** ones are candidates to fold in.

The same thing by hand, if you prefer:

```bash
sudo ausearch -m AVC -su ai_tools_t -ts recent              # inspect raw denials
sudo ausearch -m AVC -su ai_tools_t -ts recent | audit2allow -R   # suggested rules
```

Fold the suggested allows into the **BRING-UP** section of `ai_tools.te` (prefer
the refpolicy interfaces `audit2allow -R` suggests over raw `allow` lines), then
rebuild and reload:

```bash
sudo ./install-selinux.sh rebuild     # recompile from source + reload (still permissive)
```

`rebuild` recompiles `ai_tools.pp` from the edited `.te`/`.fc`, reloads it, and
re-applies labels — the loop step after every source edit. (`install` does the same
but only recompiles if you answer its prompt, and it re-offers the optional groups.)

Repeat exercise → `audit2allow` → fold-in → reload until `ausearch` shows **no new
`ai_tools_t` denials** across a full session including git push and an update run.
Expect to add at least: exec of `sudo` and the transition that runs the two root
helpers (`ai-tools-chown`, `ai-tools-claude-symlink`), plus some temp-file /
`/proc/self` / socket access — these are deliberately left out of the shipped
skeleton so each lands as an *observed* rule, not a guess.

### What the first bring-up pass folded in (v0.2.0)

A raw `audit2allow` of a full session (git add/commit/push, file edits firing the
hook, Bash-tool commands) proposed ~130 allow rules. Most were **not** granted —
the tightening was deciding what the agent *needs* versus what some tool merely
*probed*. The split:

**Allowed** (genuine needs, via refpolicy interfaces where one fits):
- `sudo` + PAM, present only to run `sudo ai-tools-chown` from the hooks:
  `can_exec(sudo_exec_t)`, `auth_domtrans_chk_passwd` (so `/etc/shadow` is read in
  `chkpwd_t`, **not** in `ai_tools_t`), `logging_send_{audit,syslog}_msg`, faillock
  + pam runtime dirs, and the `setuid setgid chown fsetid dac_read_search`
  capabilities the drop-to-uid and the chown helper use.
- Private temp: a new type `ai_tools_tmp_t` with a `/tmp` `type_transition`, so the
  agent's scratch files are relabelled away from shared `tmp_t`/`user_tmp_t`.
- `execmem` (V8 JIT), `map` on the project/home types (Node/git mmap),
  `dev_read_sysfs`, fs/vm sysctls, the controlling pty, and execute on the hook
  scripts in `.claude`.

**Refused — `dontaudit`, never `allow`** (this is the boundary):
- **Reading other domains' process state.** The pass logged ~45 daemon domains
  (`sshd_t`, `sssd_t`, `postgresql_t`, `NetworkManager_t`, `container_t`,
  `unconfined_t`, …) with the identical `/proc/<pid>` read signature — a full
  process-table walk. `domain_dontaudit_read_all_domains_state` refuses the lot;
  the agent has no business reading every daemon's `cmdline`/`environ`/fds.
- **Listing the invoking user's home.** `user_home_t:dir search` *is* granted (the
  project nests under `/home/<you>/…`, so the agent must traverse to reach it), but
  `read` on `home_root_t` / `user_home_dir_t` / `user_home_t`, and reads of
  `config_home_t` (`~/.config`), are refused — that listing is how the agent would
  discover unrelated files.
- Reading container storage (`container_file_t`) and executing the MTA
  (`sendmail_exec_t`); benign `statfs`/tty-attr noise.

**Fixed by labelling, not by allowing:** the pass also logged `usr_t` *writes* —
the agent writing its own HOME state (`/opt/ai-tools/.npm`,
`.cache`, `.local`). Those paths are now labelled `ai_tools_home_t` in
`ai_tools.fc`, so the writes land on a type the domain already manages. Granting
`usr_t` write was rejected: it would also hand the agent the read-only node tree.

## 3. Flip to enforcing

When the log is clean, remove the switch line from `ai_tools.te`:

```diff
- permissive ai_tools_t;
```

```bash
sudo ./install-selinux.sh rebuild     # recompile from source + reload -> ai_tools_t now enforcing
sudo ausearch -m AVC -ts recent | grep ai_tools_t   # confirm still clean under load
```

The rest of the system stays at its normal enforcing/targeted setting throughout;
only `ai_tools_t`'s own permissive flag changed.

## 4. Verify enforcement (the negative test)

Bring-up proves the agent *can* do what it needs. The inverse — proving it *cannot*
do what it must not — is `avc-denials.sh`. It attempts every denied access on
purpose (the optional-group surfaces that are off: `systemctl`, `rpm`,
`firewall-cmd`, `podman`; and the in-core boundary: other domains' `/proc`, the
user's home, container storage, a non-`http` port, the MTA) and confirms each is
refused.

The catch: the boundary accesses are `dontaudit`'d, so under enforcing they are
blocked **silently** — `ausearch` shows nothing and an empty log looks like the
probe never ran. So the run-mode half brackets the probe with `semodule -DB` …
`semodule -B`, which disables/re-enables dontaudit **system-wide** for the window,
making those denials visible. A trap restores dontaudit on any exit, including
Ctrl-C.

Split by privilege, same as bring-up — root toggles dontaudit and reads the log,
the agent triggers the denials:

```bash
# 1. AS <you> (root), in a terminal:
sudo selinux/avc/avc-denials.sh           # -DB, prints the probe cmd, then WAITS

# 2. AS THE AGENT, in a confined claude (approved project):
bash selinux/avc/avc-denials.sh probe     # every attempt is expected to FAIL

# 3. back in terminal 1: press Enter   # ausearch + classify, then -B restores
```

It hands off to `avc-analyze.sh`, which now sorts denials into **three** buckets:
**EXPECTED BOUNDARY** (`dontaudit`'d in the core module), **EXPECTED
GROUP-DISABLED** (only an optional group would allow them — `enable-group <name>`,
*not* a core change), and **NEW** (a real gap to review). Group-surface denials
(`rpm_exec_t`, `systemd_systemctl_exec_t`, `firewalld_t`, …) land in the second
bucket instead of being misreported as NEW. A clean verification shows entries in
the two EXPECTED buckets and **nothing** under NEW or "ran (group enabled?)".

## After a Node upgrade

A freshly installed `claude.exe` is mislabelled (`bin_t`), so the
`unconfined_t → ai_tools_t` transition stops firing. `claude-run` **fail-closes** on this —
it refuses to launch rather than run unconfined — so a mislabelled entrypoint keeps the
agent safe while it waits to be relabelled.

The daily `nvm-update` timer relabels the new entrypoint automatically: after delegating the
sandbox update it runs `ai-tools-relabel-entrypoint` as root (a dedicated NOPASSWD rule),
which `restorecon`s every `claude.exe` under the nvm tree and verifies `ai_tools_exec_t`. So
a normal upgrade keeps the agent confined across version bumps with no manual step.

Relabel by hand only if you upgraded Node some other way, or if the timer's relabel failed
(`claude-run` will be refusing to launch and pointing you here):

```bash
ai-tools --relabel
```

To re-apply **all** labels after changing the policy (entrypoint + home-state + every
project), use the full sweep:

```bash
cd selinux && sudo ./install-selinux.sh relabel
```

Both paths **verify** the entrypoint label and remind you that a *running* claude keeps its
old context until you exit and relaunch.

## Adding a project later

`ai-tools --project-create <dir>` registers a **real** project for the DAC layer
but does not label it for SELinux. After adding one, re-run:

```bash
cd selinux && sudo ./install-selinux.sh relabel
```

**Sandbox** clones are different — they label themselves. Because every clone lives
under the fixed parent `/var/opt/ai-tools/sandbox-projects/`, a static fcontext rule
in `ai_tools.fc` maps the whole tree to `ai_tools_project_t`, and `ai-tools
--sandbox-create` runs `restorecon` on the new clone itself (the projects user is
`unconfined_t`, which the policy grants relabel to `ai_tools_project_t`). No manual
`relabel` is needed. The agent reaches clones through the `files_search_var`
traversal grant in `ai_tools.te` (search-only on `var_t`, the type of `/var`,
`/var/opt`, and the sandbox parent dirs).

This only works once the module is **loaded** — the static rule and the
`ai_tools_project_t` type ship in the `.pp`. After pulling these changes rebuild and
reload:

```bash
cd selinux && sudo ./install-selinux.sh rebuild
```

## Remove

```bash
cd selinux && sudo ./install-selinux.sh remove
```

Unloads the module, deletes the project fcontext rules, and `restorecon`s
`/opt/ai-tools/.claude`, the nvm tree, and each project back to default contexts.
DAC hardening (ownership/permissions/sticky `.claude`/locked `bin`) is untouched.

## Notes

- **Minimal surface:** five types (`ai_tools_t`, its entrypoint, project, home,
  private-tmp), one entrypoint transition, manage rights on exactly the project +
  home + tmp types, read/exec for the nvm tree, the `sudo`→helper path, outbound
  HTTPS, and a process baseline. Everything else is denied — and the accesses the
  agent *probed but does not need* (other domains' `/proc`, the user's home
  listing, container storage) are `dontaudit`'d so they stay denied AND quiet.
- **git is covered:** `ai_tools_project_t` manage rights include the dir
  create/rename/unlink that git needs (`index.lock`, refs, objects); `git` itself
  runs from `corecmd_exec_bin`. No git permission from the main install changes.
- **Belt and suspenders:** SELinux here does not replace the DAC model — the
  locked `bin`, sticky `.claude`, and `<you>:ai-tools` control files still stand; a
  given access must pass both layers.
- **Cross-distro type names:** the `require {}` block in `ai_tools.te` is a *hard*
  load-time dependency — a type that does not exist in the running base policy
  makes `semodule` fail for every user (`Failed to resolve typeattributeset`).
  Type names vary across `selinux-policy` versions (RHEL 9 vs UEK vs RHEL 10) and
  optional sub-packages, so the **extended-boundary** types in section (6) are
  deliberately kept *out* of `require {}` while their `dontaudit` rules stay
  commented. Known variations: `/etc/sudoers` is `etc_sudoers_t` on full RHEL 9
  policy but plain `etc_t` on this UEK build; `/run/user/<uid>` is `user_runtime_t`
  on RHEL 9 but `user_tmp_t` here; `container_var_run_t` exists only with
  `container-selinux`. Before uncommenting a section-(6) rule: confirm the type
  with `seinfo -t <type_t>`, add it to `require {}`, then rebuild. The
  `avc-analyze.sh` classifier carries both spellings — it only tags log lines, so
  unknown names there are harmless.
- **Sudoers stays inaccessible even where it is `etc_t`:** where `/etc/sudoers` is
  labelled plain `etc_t` (this UEK build), the MAC layer *allows* the read via
  `files_read_etc_files` — but **DAC still denies it**: `/etc/sudoers` is
  `0440 root:root` and `/etc/sudoers.d` is `0750 root:root`, while `ai-tools` is a
  non-root UID in no supplementary groups, so both return `EACCES` (verified with
  SELinux disabled for the test). What the UEK label costs is only the *MAC
  redundancy* for sudoers, not the protection itself; `/etc/shadow` (`shadow_t` +
  `0000`) keeps full dual-layer coverage everywhere. `avc-denials.sh` section H
  verifies the *outcome* (inaccessible), independent of which layer enforces it.
