# SPDX-License-Identifier: AGPL-3.0-only
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
# session_path_entries, unset your own temporaries, and do not exec, prompt, or read stdin. This
# fragment additionally EXPORTS ANTHROPIC_AUTH_TOKEN when a custom endpoint supplies one (the
# credential-off-cmdline pattern) -- the one sanctioned caller-environment mutation, so the paired
# name-only --setenv imports it without the value reaching any command line.
# shellcheck disable=SC2154  # both arrays belong to the sourcing launcher

session_environment_options+=(
    "--setenv=CLAUDE_CONFIG_DIR=/opt/ai-tools/.claude"
    "--setenv=NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache"
    "--setenv=DISABLE_AUTOUPDATER=1"
)

# Custom API endpoint (operator.conf CLAUDE_BASE_URL_FILE -> /etc/ai-tools/endpoints/<file>). Routes
# the session at a non-default ANTHROPIC_BASE_URL with its auth token and model labels. Only valid,
# uncommented options are injected; a configured-but-invalid option REFUSES the launch (exit 1)
# rather than route the session partially or wrongly -- this fragment is sourced in ai-tools-run's
# own shell before the unit is created and before the session-end sweep trap, so exiting here is a
# clean fail-closed with no session started. The token is imported by name (value off the command
# line). See claude-endpoint.lib.sh and providers.rule.md.
# shellcheck source=/dev/null
if source /usr/local/lib/ai-tools/claude-endpoint.lib.sh 2>/dev/null \
        && declare -F ai_tools_claude_resolve_endpoint_setenv >/dev/null 2>&1; then
    if ! ai_tools_claude_resolve_endpoint_setenv session_environment_options /etc/ai-tools/operator.conf; then
        ai_tools_msg_error \
            "ai-tools-run: a custom Claude Code endpoint is configured but has an invalid option --" \
            "refusing to launch (see the warning above). Fix the file named by CLAUDE_BASE_URL_FILE" \
            "in /etc/ai-tools/operator.conf, or comment CLAUDE_BASE_URL_FILE out to use the default."
        exit 1
    fi
elif ai_tools_conf_read /etc/ai-tools/operator.conf CLAUDE_BASE_URL_FILE 2>/dev/null \
        && [[ -n "${_ai_tools_conf_value}" ]]; then
    # The resolver lib did not load but an endpoint IS configured: refuse rather than route the
    # session at the default endpoint the operator did not ask for (same fail-closed-when-configured
    # posture the custom system prompt takes in claude.sh).
    ai_tools_msg_error \
        "ai-tools-run: a custom Claude Code endpoint is configured but its resolver library is" \
        "unavailable -- refusing to launch rather than ignore it. Reinstall ai-tools."
    exit 1
fi
