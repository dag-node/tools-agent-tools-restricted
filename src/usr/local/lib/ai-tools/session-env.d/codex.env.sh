# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/codex.env.sh
# Session environment for the codex agent. ai-tools-run sources this last, after every enabled integration, so the pin
# is authoritative for the session. One pin, and it exists because the sandbox home is deliberately not agent-writable
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
# What this fragment does not carry: a CODEX_MANAGED_* variable (the vendor's npm shim sets them, and the binary behaves
# the same without them) and a credential -- the API-key path is a root-placed auth.json in CODEX_HOME, so there is no
# token to import by name. The defaults a session starts with (the mode pin, the approval policy, the opt-outs,
# the update check) are codex's own managed files under /etc/codex, which codex reads itself.
#
# Fragment contract (see providers.rule.md): append to session_environment_options and session_path_entries, unset your
# own temporaries, and do not exec, prompt, or read stdin.
# shellcheck disable=SC2154  # the array belongs to the sourcing launcher

session_environment_options+=(
    "--setenv=CODEX_HOME=/opt/ai-tools/.codex"
)
