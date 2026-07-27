# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/claude-code.env.sh
# Session environment for the claude-code agent. ai-tools-run sources this last, after every
# enabled integration, so these pins are authoritative for the session.
#
# Each pin exists because the sandbox home is deliberately not agent-writable at its root:
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
#                        .cache subtree is ai_tools_home_t and agent-managed.
#
#   DISABLE_AUTOUPDATER  The Node program tree is read-only to the session by SELinux policy, so
#                        an in-session `npm install -g` self-update cannot write the npm prefix.
#                        The nvm-update timer maintains the toolchain out of band instead, which
#                        also keeps the toolset stable for the whole session.
#
# Fragment contract (see providers.rule.md): append to session_environment_options and
# session_path_entries, unset your own temporaries, and do not exec, prompt, or read stdin.
# shellcheck disable=SC2154  # both arrays belong to the sourcing launcher

session_environment_options+=(
    "--setenv=CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude"
    "--setenv=NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache"
    "--setenv=DISABLE_AUTOUPDATER=1"
)
