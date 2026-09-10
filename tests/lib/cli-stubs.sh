#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/lib/cli-stubs.sh
# A `sudo` shim and stub root helpers, so a test observes what the ai-tools CLI ASKS a root helper to do without any
# helper running. The CLI reaches every helper as `sudo <fixed path> <args>` and resolves `sudo` by name on PATH,
# so a shim placed first on the PATH of the operator the test runs the CLI as intercepts every call: it appends
# `<helper> <cwd> <args...>` (tab-separated) to a call log, then execs a stub of that helper when one exists and exits 0
# otherwise. The shim does not elevate the CLI -- it already runs unprivileged as the projects user, and a shim
# on that user's own PATH runs as that user too -- which is why the CLI does not carry a hook for this, and why this
# header is its whole description.
#
# The shim also answers the two other shapes the CLI sends through sudo: the grant probe `sudo -n -l [-u <user>]
# <helper>` (answered as "grant present": exit 0, the helper echoed), and the run-as-owner form `sudo -u <user> -H --
# <cmd>` (run directly, as the invoker).
#
# The stubs answer only what the CLI PARSES from a helper:
#   ai-tools-lockdown   prints the secret-scan count line and one `[file]` line per path listed
#                       in <root>/stubs/lockdown.secrets (empty or absent: a clean tree), the form
#                       secret_gate reads; it leaves the tree as it is.
#   ai-tools-allowlist  the --for registry: --print cats <root>/for-allowlist, and --add/--remove/
#                       --enable/--disable edit it through the deployed conf.lib.sh, so the target's
#                       registry behaves as the real helper's would.
#   ai-tools-safedir    adds or removes the safe.directory entry in $AI_TOOLS_GITCONFIG,
#                       which the CLI re-reads for idempotency.
# Every other helper is record-only.
#
# cli_stubs_install <root>   writes the shim and stubs under <root>; sets CLI_STUB_PATH (prepend
#                            to PATH), CLI_STUB_LOG, CLI_STUB_SECRETS. <root> must be exec-capable
#                            and the caller chowns it to the user the CLI runs as.
# cli_stub_reset             truncates the log and the secrets list.
# cli_calls <helper>         prints the log lines for <helper>, fields after the cwd only
#                            (tab-separated args).
# cli_called <helper> [ere]  0 when <helper> was called and, with <ere>, some call's args match it.
# cli_call_count <helper>    the number of calls.
# cli_log_empty              0 when no helper was called.
# cli_call_index <helper> [ere]  the 1-based log line of the first matching call, for ordering.
# cli_stub_secrets <path>... makes the lockdown stub report these paths as secret-matching.

cli_stubs_install() {
    local root="$1"
    CLI_STUB_PATH="${root}/stub-bin"
    CLI_STUB_DIR="${root}/stubs"
    CLI_STUB_LOG="${root}/sudo-calls.log"
    CLI_STUB_SECRETS="${CLI_STUB_DIR}/lockdown.secrets"
    mkdir -p "${CLI_STUB_PATH}" "${CLI_STUB_DIR}"
    : > "${CLI_STUB_LOG}"
    : > "${CLI_STUB_SECRETS}"

    cat > "${CLI_STUB_PATH}/sudo" <<EOF
#!/usr/bin/env bash
# sudo shim written by tests/lib/cli-stubs.sh: records helper calls; it does not elevate the caller.
set -u
STUBS="${CLI_STUB_DIR}"
LOG="${CLI_STUB_LOG}"
if [[ "\${1:-}" == -n && "\${2:-}" == -l ]]; then
    shift 2
    [[ "\${1:-}" == -u ]] && shift 2
    printf '%s\n' "\${1:-}"
    exit 0
fi
if [[ "\${1:-}" == -u ]]; then
    shift 2
    [[ "\${1:-}" == -H ]] && shift
    [[ "\${1:-}" == -- ]] && shift
    exec "\$@"
fi
bin="\$1"; shift
name="\${bin##*/}"
{
    printf '%s\t%s' "\${name}" "\${PWD}"
    for a in "\$@"; do printf '\t%s' "\${a}"; done
    printf '\n'
} >> "\${LOG}"
if [[ -x "\${STUBS}/\${name}" ]]; then
    exec "\${STUBS}/\${name}" "\$@"
fi
exit 0
EOF

    cat > "${CLI_STUB_DIR}/ai-tools-lockdown" <<EOF
#!/usr/bin/env bash
set -u
secrets="${CLI_STUB_SECRETS}"
if [[ -s "\${secrets}" ]]; then
    n="\$(wc -l < "\${secrets}")"
    printf 'ai-tools-lockdown: %d secret-matching path(s) under %s:\n' "\${n}" "\${PWD}" >&2
    while IFS= read -r p; do printf '  [file] %s\n' "\${p}" >&2; done < "\${secrets}"
fi
exit 0
EOF

    cat > "${CLI_STUB_DIR}/ai-tools-allowlist" <<EOF
#!/usr/bin/env bash
set -u
source /usr/local/lib/ai-tools/conf.lib.sh
file="${root}/for-allowlist"
action=""; target=""
while (( \$# )); do
    case "\$1" in
        --operator) shift 2 ;;
        --print)    action=print; shift ;;
        --add|--remove|--enable|--disable) action="\${1#--}"; target="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "\${action}" in
    print) cat "\${file}" ;;
    add|remove|enable|disable) "ai_tools_conf_allowlist_\${action}" "\${file}" "\${target}" ;;
    *) exit 2 ;;
esac
EOF

    cat > "${CLI_STUB_DIR}/ai-tools-safedir" <<'EOF'
#!/usr/bin/env bash
set -u
remove=false; path=""
for a in "$@"; do
    case "${a}" in
        --remove) remove=true ;;
        *) path="${a}" ;;
    esac
done
gc="${AI_TOOLS_GITCONFIG:?}"
if ${remove}; then
    git config --file "${gc}" --fixed-value --unset-all safe.directory "${path}" 2>/dev/null || true
else
    git config --file "${gc}" --add safe.directory "${path}"
fi
EOF

    chmod 0755 "${CLI_STUB_PATH}/sudo" "${CLI_STUB_DIR}"/ai-tools-*
}

cli_stub_reset() { : > "${CLI_STUB_LOG}"; : > "${CLI_STUB_SECRETS}"; }

cli_stub_secrets() { printf '%s\n' "$@" > "${CLI_STUB_SECRETS}"; }

cli_calls() {
    local helper="$1"
    awk -F'\t' -v h="${helper}" '$1==h { out=""; for (i=3; i<=NF; i++) out = out (i>3 ? "\t" : "") $i; print out }' \
        "${CLI_STUB_LOG}"
}

cli_call_count() { cli_calls "$1" | wc -l | tr -d ' '; }

cli_called() {
    local helper="$1" ere="${2:-}"
    if [[ -z "${ere}" ]]; then
        [[ "$(cli_call_count "${helper}")" -gt 0 ]]
    else
        cli_calls "${helper}" | grep -qE -- "${ere}"
    fi
}

cli_log_empty() { [[ ! -s "${CLI_STUB_LOG}" ]]; }

cli_call_index() {
    local helper="$1" ere="${2:-.}"
    awk -F'\t' -v h="${helper}" -v re="${ere}" \
        '$1==h { out=""; for (i=3; i<=NF; i++) out = out (i>3 ? "\t" : "") $i; if (out ~ re) { print NR; exit } }' \
        "${CLI_STUB_LOG}"
}
