# Optional SELinux confinement — `ai_tools_t`

An extra **mandatory access control** layer for the Claude Code sandbox, separate
from and on top of the DAC (ownership/permission) model in the main install. It
confines the agent to its own SELinux domain with a **path boundary**:

| Type | Applied to | `ai_tools_t` may |
|---|---|---|
| `ai_tools_t` | the agent process (`claude.exe` as the ai-tools UID) | — |
| `ai_tools_exec_t` | the versioned `claude.exe` launcher | entrypoint (drives the transition) |
| `ai_tools_project_t` | approved project dirs (per allowlist) | read/write (incl. all git ops) |
| `ai_tools_home_t` | `/opt/ai-tools/.claude` | read/write its own state |
| everything else (e.g. other `/home` files = `user_home_t`) | — | **no access** once enforcing |

This is what stops the agent inadvertently touching **unrelated** files: once
`ai_tools_t` is enforcing, it can write `ai_tools_project_t` and `ai_tools_home_t`
but not `user_home_t`, `etc_t`, other users' files, etc. DAC still applies
underneath — both layers must allow an access.

## Why it ships permissive

You cannot confine a complex app (Node + git + the Bash tool) correctly by
guessing rules — the rule set must be *observed*. So `ai_tools.te` contains
`permissive ai_tools_t;`: loading the module **blocks nothing**, it only logs what
`ai_tools_t` does. You complete the policy from those logs, then flip to enforcing
by removing that one line. The transition also **fails open** — if `claude.exe`
ever loses its label (e.g. a Node upgrade before `relabel`), no transition fires
and claude simply runs unconfined; it never breaks.

## Prerequisite

```bash
sudo dnf install selinux-policy-devel
```

## 1. Build, load, label

```bash
cd selinux
sudo ./install-selinux.sh install
```

This builds `ai_tools.pp`, loads it **permissive**, labels `/opt/ai-tools/.claude`
(`ai_tools_home_t`) and the `claude.exe` entrypoint, and labels every project in
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
full rule set:

```bash
# in an approved project, run claude and have it:
#   - write/edit a file       (fires the PostToolUse hook -> sudo ai-tools-chown)
#   - git status / diff / branch        (auto-allowed)
#   - git add / commit / mv / push      (the confirmed git ops)
#   - run a Bash tool command
# then, if a Node upgrade happens, let nvm-update run once too.
```

Collect what it *would* have denied and turn it into rules:

```bash
sudo ausearch -m AVC -ts recent | grep ai_tools_t          # inspect raw denials
sudo ausearch -m AVC -ts recent | audit2allow -R           # suggested refpolicy rules
```

Fold the suggested allows into the **BRING-UP** section of `ai_tools.te` (prefer
the refpolicy interfaces `audit2allow -R` suggests over raw `allow` lines), then
rebuild and reload:

```bash
sudo ./install-selinux.sh install     # rebuild + reload (still permissive)
```

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
  project nests under `/home/xd/…`, so the agent must traverse to reach it), but
  `read` on `home_root_t` / `user_home_dir_t` / `user_home_t`, and reads of
  `config_home_t` (`~/.config`), are refused — that listing is how the agent would
  discover unrelated files.
- Reading container storage (`container_file_t`) and executing the MTA
  (`sendmail_exec_t`); benign `statfs`/tty-attr noise.

**Fixed by labelling, not by allowing:** the pass also logged `usr_t` *writes* —
the agent writing its own HOME state (`/opt/ai-tools/.claude.json`, `.npm`,
`.cache`, `.local`). Those paths are now labelled `ai_tools_home_t` in
`ai_tools.fc`, so the writes land on a type the domain already manages. Granting
`usr_t` write was rejected: it would also hand the agent the read-only node tree.

## 3. Flip to enforcing

When the log is clean, remove the switch line from `ai_tools.te`:

```diff
- permissive ai_tools_t;
```

```bash
sudo ./install-selinux.sh install     # rebuild + reload -> ai_tools_t now enforcing
sudo ausearch -m AVC -ts recent | grep ai_tools_t   # confirm still clean under load
```

The rest of the system stays at its normal enforcing/targeted setting throughout;
only `ai_tools_t`'s own permissive flag changed.

## After a Node upgrade

A freshly installed `claude.exe` is unlabelled (fails open → unconfined). Re-apply:

```bash
cd selinux && sudo ./install-selinux.sh relabel
```

(If you later want this automatic, the root helper `ai-tools-claude-symlink` —
which already runs at upgrade time with the versioned path — is the natural place
to add a `restorecon` of the new `claude.exe`.)

## Adding a project later

`install.sh add-project <dir>` registers a project for the DAC layer but does not
label it for SELinux. After adding one, re-run:

```bash
cd selinux && sudo ./install-selinux.sh relabel
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
  locked `bin`, sticky `.claude`, and `xd:ai-tools` control files still stand; a
  given access must pass both layers.
