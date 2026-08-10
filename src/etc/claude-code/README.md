# `managed-settings.json`

Reference host-wide Claude Code managed policy (`/etc/claude-code/managed-settings.json`):
the highest-precedence settings layer, so its keys override — and cannot be overridden by —
the sandbox's shipped user layer (`/opt/ai-tools/.claude/settings.json`) or a project's
`.claude/settings.json`. Source-only: the package never installs it (it governs every
Claude Code user on the host), so an administrator copies it into place.

See [`docs/claude-options.md`](../../../docs/claude-options.md) for what each key does.

## Point Claude Code at a custom Anthropic-compatible endpoint

For a **sandboxed** session (`ai-tools-agents-claude-code-restricted`), configure the endpoint
through the sandbox's own config, not here — that keeps the auth token out of world-readable
files. Uncomment the pointer in `/etc/ai-tools/operator.conf`:

```ini
CLAUDE_BASE_URL_FILE=/etc/ai-tools/endpoints/custom-claude-endpoint.conf
```

then set the endpoint in that file (`640 root:ai-tools`, edited with `sudo` — it may hold a
token, so it is not world-readable):

```ini
ANTHROPIC_BASE_URL=https://chat.customdomain.tld
ANTHROPIC_AUTH_TOKEN=your-token          # omit for a localhost proxy
ANTHROPIC_MODEL=claude-sonnet-4-5-20250929
ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5-20251001
```

The next session picks it up (`claude.sh` reads `operator.conf` at launch). Only these four
keys are read and each is validated; a configured-but-invalid value **refuses the launch**
rather than routing partially. With a custom proxy the model names are **labels the proxy maps**
to an underlying model, not necessarily real Anthropic model ids. See `operator.conf(5)` and the
endpoint file's own comments.

To set the same variables **host-wide** for every Claude Code user on the box (not just the
sandbox), put them in this file's `env` block instead. This layer is highest-precedence, so it
**overrides** the sandbox endpoint file above:

```json
{
    "env": {
      "ANTHROPIC_BASE_URL": "https://chat.customdomain.tld",
      "ANTHROPIC_AUTH_TOKEN": "--------",
      "ANTHROPIC_MODEL": "claude-sonnet-4-5-20250929",
      "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5-20251001"
    }
}
```
