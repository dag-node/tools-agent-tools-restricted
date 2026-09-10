# Running agents under service accounts on one host

```bash
sudo ai-tools-admin operators add svc-ci                  # enrol the service account
ai-tools projects claim --for svc-ci /srv/projects/api    # claim a project on its behalf
sudo -u svc-ci -H bash -lc 'cd /srv/projects/api && claude'   # the account runs its own session
```

The first line makes `svc-ci` an operator: it records the name in `/etc/ai-tools/operator.conf`,
adds the account to the `ai-ops` group, and seeds its own allowlist under `~/.config/ai-tools`.
The second line claims a project for it. A claim needs `sudo`, which a service account without a
password cannot answer, so an operator who holds a sudo grant claims once with `--for` and the
entry lands in the service account's allowlist. From then on the account launches `claude` in
that project by itself, and every file the agent writes comes back owned by `svc-ci`. The third
line is how an administrator tries that from a shell; a CI job or a unit running as `svc-ci` runs
`claude` the same way.

An operator is any login account enrolled like this, a person or a service account alike. The
model exists so that agents can work on tasks under limited accounts on one host: each account
has its own allowlist and owns its own results, while one sandbox account does the work.
[naming-conventions.md](naming-conventions.md) states what an operator and an allowlist are, and
[project-lifecycle.md](project-lifecycle.md) covers `--for` and the commands that take it.

## What a service account can do on its own

- **Run sessions** in every project claimed for it. Group membership applies to a new login
  session, so enrol the account before its first job starts.
- **See its projects and the host**: `ai-tools projects` lists its allowlist, and
  `ai-tools status` reports the sandbox's health.
- **Park and unpark its own projects** with `ai-tools projects disable` and `projects enable`.
- **Stop every session on the host** with `ai-tools stop`, which does not ask for a password. It
  is the shutdown rung of the escalation ladder in the shipped governance framework
  ([framework.md](../src/usr/share/ai-tools/skills/ai-tools-capable-systems-governance/references/framework.md),
  installed at `/opt/ai-tools/skills/ai-tools-capable-systems-governance/references/framework.md`),
  and it is granted without a password so that an unattended monitor can reach it.
- **Not claim, clone, unclaim, lock down or reclaim.** Each of those reaches a root helper over
  `sudo`. The refusal names the command an operator with a sudo grant runs for it.

The account needs a home directory, since its allowlist lives under `~/.config/ai-tools`.

## What every operator shares

- **One sandbox account.** Every session runs as `ai-tools`, whichever operator launched it. A
  session works in the project it was launched in, from the launching account's allowlist, and
  the operators' allowlists are usually disjoint. The kernel does not keep one operator's projects
  out of another's session, so operators are one trusting team.
- **The agent's state.** Claude Code's history and sessions live in one directory for the host,
  as does session scratch under `/tmp`.
- **One session per project at a time.** Two sessions in one working tree share its files and its
  git index. A second agent on the same repository works in its own clone
  (`ai-tools projects clone`).
- **The toolchain.** A daily timer in the sandbox account's own `systemd --user` instance
  updates Node and the agent packages once for the host; it runs as `ai-tools`, and the relabel
  that follows an update runs as root. `ai-tools status` reports the result to any operator.
- **The commit identity.** The agent commits with the name and email set at bootstrap, whichever
  operator's project the commit lands in.
- **The clone area.** Any operator creates clones under `/var/opt/ai-tools/sandbox-projects`. A
  clone belongs to the operator who created it and uses that operator's git credentials, so
  `projects clone` does not take `--for`.
- **The stop.** `ai-tools stop` ends every operator's sessions, not only the caller's
  ([session-stop.md](session-stop.md)).

## What stays private to each operator

- **The allowlist.** `~/.config/ai-tools/allowed-projects` is readable by its owner alone.
  Another operator's `--for` run reaches it through a root helper, and the sandbox account does
  not read it at all.
- **The launch gate.** `claude` starts only in a project the launching account's own allowlist
  lists.
- **Ownership of the agent's work.** A file the agent writes comes back to the operator whose
  allowlist covers its path; a secret-named file comes back readable by that operator alone. When
  two allowlists list the same path, the operator who owns the directory on disk wins.
- **Access to the tree.** A claim grants the operator read and write on the project through an
  ACL, so the operator stays out of the `ai-tools` group.

## Where to read more

- `ai-tools-admin(8)` for enrolling and removing operators; `operator.conf(5)` and
  `allowed-projects(5)` for the two files an enrolment writes.
- [ref-section-x6a9](../CLAUDE.md#ref-section-x6a9) for what the model leaves out on purpose:
  operators are trusted, and sessions are not isolated from one another.
