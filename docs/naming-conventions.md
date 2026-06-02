# Naming conventions — user/group/home identities

This codebase coordinates several distinct identities. Historically they were
all called "user" (and the maintainer's literal login `xd` leaked in), which is
ambiguous: "user" could mean the human who installs and invokes the tool, that
human's group or home, the unprivileged sandbox service account the agent runs
as, or the generic POSIX notion of any host user. This file is the single
source of truth for which name denotes which identity. Every functional
identifier and every reference in prose must use exactly one of these.

## The identities

### Projects user — the real login/installing/invoking account

The real account that owns the projects, belongs to `wheel`, runs
`sudo ./install.sh`, and launches the `claude` wrapper. It is whoever ran sudo
(`${SUDO_USER}`). Named for what defines it — it owns the approved project trees
the agent works in. Deliberately **not** "human user": the actor may be an
automation, not a person. Restored files are owned by this account.

| Facet | Shell variable | Install-time token | Prose term |
|-------|----------------|--------------------|------------|
| account | `PROJECTS_USER` | `@PROJECTS_USER@` | "the projects user" |
| home dir | `PROJECTS_HOME` | `@PROJECTS_HOME@` | "the projects user's home" |
| primary/private group | `PROJECTS_GROUP` | `@PROJECTS_GROUP@` | "the projects user's group" |

`@PROJECTS_USER@`/`@PROJECTS_GROUP@`/`@PROJECTS_HOME@` are substituted by
`install.sh` from `PROJECTS_USER`/`PROJECTS_GROUP`/`PROJECTS_HOME` (derived from
`${SUDO_USER}`). The token form and the shell-variable form denote the **same**
entity; they differ only in whether the file is a runtime script (variable) or a
shipped template (token).

The projects user's private group is always written
`@PROJECTS_USER@:@PROJECTS_GROUP@` (`PROJECTS_USER:PROJECTS_GROUP`). Do not spell
it `PROJECTS_USER:PROJECTS_USER` even though RHEL User-Private-Groups make the
two coincide.

### Sandbox user — the unprivileged service account the agent runs as

The dedicated, no-login system account (`ai-tools`) that Claude Code executes
as. Owns nothing of the IDE user's; can sudo only the two narrow root helpers.

| Facet | Shell variable | Install-time token | Prose term |
|-------|----------------|--------------------|------------|
| account | `SANDBOX_USER` | `@SANDBOX_USER@` | "the sandbox user" |
| group | `SANDBOX_GROUP` | `@SANDBOX_GROUP@` | "the sandbox group" |

`@SANDBOX_USER@`/`@SANDBOX_GROUP@` substitute to `ai-tools` at install time, so
the account name is a config knob in owner strings (`OWNER`, `EXPECTED_OWNER`,
`sudo -u`, etc.). The literal `ai-tools` is **retained** in identifiers that are
not the account itself and are coupled to other contracts:

- filesystem paths — `/opt/ai-tools`, `~/.config/ai-tools`
- SELinux types and modules — `ai_tools_t`, `ai_tools_conf_t`, `ai_tools.te`, …
- root-helper binary names — `ai-tools-chown`, `ai-tools-lockdown`,
  `ai-tools-claude-symlink`

Renaming those would break paths, policy, and the sudoers grant; they stay
literal regardless of `SANDBOX_USER`.

### Role aliases built from the above

- `SECRET_OWNER = @PROJECTS_USER@:@PROJECTS_GROUP@` — owner a quarantined secret is locked
  to (revokes the sandbox user's read).
- `OWNER = @PROJECTS_USER@:@SANDBOX_GROUP@` — owner restored on agent-written,
  non-secret paths.

### No cross-group membership

The projects user is **not** a member of the sandbox group, and the sandbox user
is not in the projects user's group. The `PROJECTS_USER:SANDBOX_GROUP` ownership
split is what makes that unnecessary: on a restored path the projects user
accesses it through the **owner** bits and the sandbox user through the **group**
bits. This keeps each side to one permission tier and avoids granting the
projects user blanket read of the sandbox group's files (e.g. `.claude` session
state).

## Generic / fixed terms that are NOT these identities

### Generic host user (`scripts/path_dedup.sh`)
"normal users", "user-tier", "user-trust", "explicit user wrappers",
"all users", "userspace app", `_T2_USER_BIN` refer to **any** account that
sources `/etc/profile.d` — not the IDE user and not the sandbox user. Left as
generic "user"; a clarifying comment marks it as such.

### Fixed external identifiers — never renamed
- SELinux types/concepts: `user_home_t`, `user_home_dir_t`, `user_tmp_t`,
  `unconfined_u`, `semanage user/login` ("SELinux-user").
- `git config user.email`; the `useradd` command; systemd `--user` /
  `journalctl --user`; `unshare --user` / `create_user_ns`; `$USER`, `$HOME`,
  `loginctl`.

### Test assertion fields (`test.sh`)
`exp_owner`/`act_owner` (formerly `exp_user`/`act_user`) plus `*_group`/`*_mode`
are the **file's** owner/group/mode from `stat`, parametrized — not an identity.
