# Claude Code options

Catalog of the Claude Code settings and environment variables that shape an agent session,
what the sandbox sets by default, and what an operator MAY add. The authoritative,
version-current references are Claude Code's own docs:

- Settings keys: <https://code.claude.com/docs/en/settings>
- Environment variables: <https://code.claude.com/docs/en/env-vars>

## Where options are set

A session's configuration comes from three places in this project:

| Layer | File | Owner | Scope |
|---|---|---|---|
| Control-plane defaults | `/opt/ai-tools/.claude/settings.json` (user layer) | `root:ai-tools`, agent cannot edit | every session |
| Structural pins | `claude-run`'s `--setenv` allowlist | `root:ai-tools`, agent cannot edit | every session |
| Per-project overrides | `<project>/.claude/settings.json` (project layer) | operator (agent-writable tree) | one project |

Claude Code merges these by precedence: managed policy > command line > local project >
project > user. The control-plane `settings.json` is the **user** layer, so a project layer
overrides its single-valued keys (`env`, `disableAutoMode`) but cannot remove its merged-set
keys (`permissions.deny`, `hooks`). See
[`.claude/rules/claude-settings.rule.md`](../.claude/rules/claude-settings.rule.md).

A machine-wide, unoverridable lock uses managed policy
(`/etc/claude-code/managed-settings.json`); the sandbox does not ship it, because that file
applies to every Claude Code user on the host, not only the sandbox account.

## Set by the sandbox

| Option | Value | Where | Purpose |
|---|---|---|---|
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | `settings.json` `env` | Opts out of telemetry, error reporting, `/feedback` upload, and the quality survey in one variable. |
| `disableAutoMode` | `"disable"` | `settings.json` | Removes `auto` from the `Shift+Tab` cycle and rejects `--permission-mode auto`, so a session confirms actions rather than acting autonomously. |
| `DISABLE_AUTOUPDATER` | `1` | `claude-run` `--setenv` | The agent's Node tree is not agent-writable; updates run out-of-band via the toolchain updater. |
| `HOME`, `PATH`, `CLAUDE_CONFIG_DIR`, `NODE_COMPILE_CACHE`, `SHELL` | sandbox paths | `claude-run` `--setenv` | Structural pins coupled to the sandbox layout — do not override. |
| `TERM`, `COLORTERM`, `LANG`/`LC_*`, `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`, `XDG_RUNTIME_DIR` | forwarded from operator | `claude-run` `--setenv` | Terminal, locale, and outbound-proxy shaping imported by name from the operator's environment. |

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` subsumes `DISABLE_TELEMETRY`,
`DISABLE_ERROR_REPORTING`, `DISABLE_FEEDBACK_COMMAND`, and
`CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`, so those four need not be set individually. It does
not touch essential Anthropic API traffic or the WebFetch domain safety check. There is no
`DISABLE_FEEDBACK` variable (the `/feedback` opt-out is `DISABLE_FEEDBACK_COMMAND`).

## Options an operator MAY add

Set these in a project's `.claude/settings.json` (the `env` block for environment variables,
top-level for keys) to tune one project without altering the shipped control plane. The
structural pins above are the exception — overriding `HOME`/`PATH`/`CLAUDE_CONFIG_DIR`
breaks the session layout.

### Auth and model

| Option | Effect |
|---|---|
| `ANTHROPIC_MODEL` | Override the default model (e.g. `claude-opus-4-8`). |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Separate model for subagents — the main cost lever (pair an Opus main with a Haiku/Sonnet subagent). |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Cap output length per response. |
| `model` (key) | Default-model override as a settings key rather than an env var. |

### Privacy and cost

| Option | Effect |
|---|---|
| `DISABLE_COST_WARNINGS` | Suppress per-session cost warnings (billing managed centrally). |
| `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_FEEDBACK_COMMAND` | Individual opt-outs already covered by the shipped umbrella. |
| `feedbackSurveyRate` (key, 0–1) | Probability the quality survey appears when eligible; `0` suppresses it. |

### Updates

| Option | Effect |
|---|---|
| `DISABLE_UPDATES` | Block all update paths — stricter than the shipped `DISABLE_AUTOUPDATER`. |

### Prompt caching

| Option | Effect |
|---|---|
| `DISABLE_PROMPT_CACHING` | Disable caching globally. |
| `ENABLE_PROMPT_CACHING_1H` | Opt into a 1-hour cache TTL. |
| `FORCE_PROMPT_CACHING_5M` | Force a 5-minute cache TTL. |

### Tool timeouts and limits

Often the fix when a Bash or MCP call hangs.

| Option | Effect |
|---|---|
| `BASH_DEFAULT_TIMEOUT_MS`, `BASH_MAX_TIMEOUT_MS` | Default and maximum Bash command timeout. |
| `BASH_MAX_OUTPUT_LENGTH` | Bash output truncation limit. |
| `MCP_TIMEOUT`, `MCP_TOOL_TIMEOUT` | MCP server-startup and tool-execution timeouts. |
| `MAX_MCP_OUTPUT_TOKENS` | Cap MCP tool output. |

### UI and terminal

| Option | Effect |
|---|---|
| `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` | Leave the terminal title unchanged. |
| `CLAUDE_CODE_HIDE_CWD` | Hide the working directory in the startup banner. |
| `USE_BUILTIN_RIPGREP` | Use the bundled ripgrep instead of a system one. |
| `showThinkingSummaries` (key) | `true` re-shows thinking blocks (hidden by default since 2.1.69). |
| `verbose` (key) | Show full Bash and command output. |

### Behavior

| Option | Effect |
|---|---|
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | Revert to fixed thinking budgets. |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY` / `autoMemoryEnabled` (key) | Disable auto memory. |
| `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS` / `includeGitInstructions` (key) | Drop the built-in git-workflow guidance from the system prompt. |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT` | Use the standard 200K context instead of 1M. |
| `cleanupPeriodDays` (key) | How long transcripts are retained locally (default 30). |
| `attribution` (key) | Control the git commit / PR attribution trailers; empty string hides them. |
| `autoMode` (key) | Customize the auto-mode classifier's `allow`/`soft_deny`/`hard_deny` rules (applies only where auto mode is selectable — the shipped default disables it). |

### Debugging and observability

| Option | Effect |
|---|---|
| `ANTHROPIC_LOG=debug` | Enable API request logging. |
| `OTEL_LOGS_EXPORTER`, `OTEL_METRICS_EXPORTER`, `OTEL_TRACES_EXPORTER` | Configure or disable (`none`) OpenTelemetry exporters. |
| `OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_TOOL_CONTENT` | Emit prompts / tool I/O in OTel spans. |

## Machine-wide locks (not shipped)

To make a setting unoverridable by any project or session, place it in managed policy at
`/etc/claude-code/managed-settings.json` (root-owned, world-readable). This is host-global —
it governs every Claude Code user on the machine, not just the sandbox account — so the
sandbox leaves it to the host administrator rather than shipping it.
