# Security Policy

Agent Tools Restricted is a confinement tool: its purpose is to keep an autonomous
coding agent inside a defined trust boundary. A hole in that boundary is the most
serious class of bug this project can have, and reports of one are taken accordingly.

## Reporting a vulnerability

**Do not open a public issue for a suspected vulnerability.**

- Preferred: **GitHub private vulnerability reporting** — *Security* tab →
  *Report a vulnerability* on this repository.
- Alternative: email **tools@dagnode.com** with subject prefix `[SECURITY]`.

Include what you can: EL version, `getenforce` output, installed package versions
(`rpm -q ai-tools-base ai-tools-nodejs claude-code-restricted`), reproduction steps,
and your assessment of impact. A proof of concept helps but is not required.

This is currently a single-maintainer project. Reports are acknowledged within
**5 business days** and you'll receive an assessment or follow-up questions within
**14 days**. Please allow a coordinated disclosure window before publishing;
reporters are credited in the fix's release notes unless they ask not to be.

## Scope

In scope — anything that breaks a documented security invariant (`CLAUDE.md`,
"Security model"):

- The sandbox account (`ai-tools`) obtaining sudo, root, or operator (`ai-ops`)
  privileges by any path.
- Escaping or bypassing the session confinement (the transient systemd unit's
  properties, the `ai_tools_t` SELinux domain, `NoNewPrivileges`).
- Writing, replacing, or disabling the control plane (settings, hooks,
  `claude-run`, the updater, the locked `bin/` symlink) as the sandbox account.
- Authentication bypass or verb-table escape in the `ai-tools-handback` socket
  daemon, or an elevated helper acting outside the allowlist.
- Bypassing the protected-paths backstop (an elevated helper acting on a system
  directory).
- Defeating secret handling: a secret-named file remaining agent-readable after
  handback or lockdown.
- Launching a session outside the allowlist, or as a non-operator, through the
  shipped wrapper.
- A fail-open where the design documents fail-closed (e.g. launching unconfined
  when the entrypoint label is missing).

Out of scope (documented boundaries, not vulnerabilities — see the root `README.md`
"On the boundary" and `CLAUDE.md`):

- The allowlist not being a kernel-enforced **read** boundary: the agent reading
  world-readable or group-readable files, like any unprivileged account, is the
  documented posture. (A mount-namespace boundary is tracked as future work.)
- Actions performed by a trusted party: root, or an enrolled `ai-ops` operator
  acting within their own grants.
- The DAC-only posture on hosts with SELinux disabled.
- Vulnerabilities in the agent software itself (Claude Code), Node.js, or nvm —
  report those upstream; this project's job is containing them.

## Supported versions

Pre-1.0: security fixes land on `develop` and ship in the next tagged release; only
the latest release is supported.
