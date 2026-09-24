# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck shell=bash
# /usr/local/lib/ai-tools/session-env.d/typesafe.env.sh
# Session environment for the typesafe integration: the credential file and the usage log the decide command is pointed
# at with `--config` and `--usage-log`, which the ai-tools-decide skill passes from these two variables. ai-tools-run
# sources this when `integration-typesafe` is named in /etc/ai-tools/operator.conf (AI_TOOLS_INTEGRATIONS). It
# self-gates on the credential file's presence, so a host whose package is gone while the name stays sets neither
# variable, and a session outside the integration passes an empty `--config` that the command refuses with exit 3.
#
# The two values are paths, never the credential: the command reads the key from the file at call time, as the sandbox
# account, so the key is in no session's environment and does not reach a child process (typesafe.rule.md). A file
# whose key is commented still sets the variables; the command then reports the file as not configured and exits 3,
# which is how an operator disables the call while keeping the name.
#
# Fragment contract (see providers.rule.md): append to session_environment_options and session_path_entries, unset your
# own temporaries, and do not exec, prompt, or read stdin.
# shellcheck disable=SC2154  # the array belongs to the sourcing launcher

[[ -f /etc/ai-tools/endpoints/typesafe.conf ]] || return 0

session_environment_options+=(
    "--setenv=AI_TOOLS_TYPESAFE_CONF=/etc/ai-tools/endpoints/typesafe.conf"
    "--setenv=AI_TOOLS_TYPESAFE_USAGE_LOG=/opt/ai-tools/integrations/typesafe/usage.log"
)
