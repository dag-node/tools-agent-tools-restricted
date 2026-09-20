# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/claude-code.pins.env.sh
# Session pins for the claude-code agent. ai-tools-run sources this into EVERY session of the account while claude-code
# is enabled -- a codex session included -- after every enabled integration, so an in-session claude child finds its
# state directory wherever it starts. Each pin exists because the sandbox home is deliberately not agent-writable at its
# root; the reason beside each pin is the mechanism, and agent-claude-code.rule.md carries the summary.
#
#   CLAUDE_CONFIG_DIR    Claude Code saves .claude.json (login, onboarding, per-project trust)
#                        by writing a temp file beside it and renaming, which needs write on the
#                        CONTAINING directory. /opt/ai-tools/.claude (3770, setgid+sticky) grants
#                        exactly that, while the sticky bit keeps the control files it does not
#                        own undeletable. Unpinned it would resolve under the 2751 home root,
#                        where the rename is refused and every session demands a fresh login.
#
#   NODE_COMPILE_CACHE   Node caches compiled modules under os.tmpdir() by default, on the shared
#                        host /tmp. Entries left there by an earlier unconfined run carry
#                        user_tmp_t, a type the session's domain has no rule for, so Node's own
#                        open() of its cache is denied and the session dies at startup. The
#                        .cache subtree is ai_tools_home_t (ai_tools.fc) and agent-managed.
#
#   DISABLE_AUTOUPDATER  The Node program tree is read-only to the session by SELinux policy (under
#                        DAC alone the sandbox account owns it), so an in-session `npm install -g`
#                        self-update cannot write the npm prefix. The nvm-update timer maintains
#                        the toolchain out of band instead, which also keeps the toolset stable for
#                        the whole session.
#
# Pins contract (see providers.rule.md): a pin is a `--setenv=NAME=value` safe in a session of any agent -- a state
# directory, an updater switch, a cache -- with no credential, no endpoint and no PATH entry; everything routed to this
# agent's sessions alone stays in claude-code.env.sh. Append to session_environment_options only; do not exec, export,
# prompt, or read stdin.
# shellcheck disable=SC2154  # the array belongs to the sourcing launcher

session_environment_options+=(
    "--setenv=CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude"
    "--setenv=NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache"
    "--setenv=DISABLE_AUTOUPDATER=1"
)
