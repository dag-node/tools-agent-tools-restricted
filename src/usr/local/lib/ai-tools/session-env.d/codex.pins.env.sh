# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/codex.pins.env.sh
# Session pins for the codex agent. ai-tools-run sources this into EVERY session of the account while codex is enabled
# -- a claude-code session included -- after every enabled integration, so an in-session codex child finds its state
# directory wherever it starts. One pin, and it exists because the sandbox home is deliberately not agent-writable
# at its root; agent-codex.rule.md carries the summary.
#
#   CODEX_HOME   Codex writes its state under this directory: its login (auth.json), its session
#                logs and memories (sqlite), its shell snapshots, and a tmp/ tree of symlinks to
#                its own binary that it appends to a tool's PATH. Unpinned it resolves to
#                $HOME/.codex under the 2751 home root, where the directory cannot be created.
#                /opt/ai-tools/.codex (3770, setgid+sticky) grants exactly that write, while the
#                sticky bit keeps the root-placed hook scripts, and a root-placed auth.json,
#                undeletable by the session.
#
# Codex does not ship a codex.env.sh beside this file: it has no variable that reaches its own sessions alone.
# A CODEX_MANAGED_* variable is not carried (the vendor's npm shim sets them, and the binary behaves the same without
# them), and there is no credential to import by name -- the API-key path is a root-placed auth.json in CODEX_HOME.
# The defaults a session starts with (the mode pin, the approval policy, the opt-outs, the update check) are codex's own
# managed files under /etc/codex, which codex reads itself.
#
# Pins contract (see providers.rule.md): a pin is a `--setenv=NAME=value` safe in a session of any agent -- a state
# directory, an updater switch, a cache -- with no credential, no endpoint and no PATH entry. Append
# to session_environment_options only; do not exec, export, prompt, or read stdin.
# shellcheck disable=SC2154  # the array belongs to the sourcing launcher

session_environment_options+=(
    "--setenv=CODEX_HOME=/opt/ai-tools/.codex"
)
