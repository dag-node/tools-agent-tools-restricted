# `managed-settings.json`

Reference host-wide Claude Code managed policy (`/etc/claude-code/managed-settings.json`):
the highest-precedence settings layer, so its keys override — and cannot be overridden by —
the sandbox's shipped user layer (`/opt/ai-tools/.claude/settings.json`) or a project's
`.claude/settings.json`. Source-only: the package never installs it (it governs every
Claude Code user on the host), so an administrator copies it into place.

See [`docs/claude-options.md`](../../../docs/claude-options.md) for what each key does.
