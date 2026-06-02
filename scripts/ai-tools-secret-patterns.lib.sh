#!/usr/bin/env bash
# /usr/local/lib/ai-tools/secret-patterns.lib.sh
# Shared secret-name pattern set for the ai-tools sandbox. This file is *sourced*
# (never executed) by the root helpers ai-tools-chown and ai-tools-lockdown so
# both decide whether a basename is a credential file by the SAME rules from the
# SAME source -- the matcher cannot drift between them.
#
# The authoritative pattern list lives in a user-owned config file:
#     @INSTALL_HOME@/.config/ai-tools/secret-patterns
# owned @INSTALL_USER@:@INSTALL_USER@ 600. The user edits it; ai-tools -- neither
# its owner nor in its group, and unable to enter the 700 .config/ai-tools dir --
# can neither read nor write it; the root helpers read it on the user's behalf.
# This mirrors how allowed-projects is owned and consumed. When the file is
# absent or yields no usable patterns, the built-in defaults below apply, so
# classification never silently degrades to "match nothing".
#
# Config-file format: one pattern per line; '#' comments and blank lines ignored;
# surrounding whitespace trimmed. Patterns are basename globs matched
# case-insensitively (.ENV, Server.KEY, ID_RSA, …).

# Sourced more than once in a single shell (e.g. a helper that re-sources): the
# readonly declarations below would abort under set -e on the second pass. Return
# early. Use an if-statement, not `[[ ]] && return` -- the latter returns 1 when
# the guard var is unset and trips the sourcing shell's set -e.
if [[ -n "${_AI_TOOLS_SECRET_PATTERNS_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_SECRET_PATTERNS_LIB=1

readonly AI_TOOLS_SECRET_PATTERNS_FILE="@INSTALL_HOME@/.config/ai-tools/secret-patterns"

# Built-in fallback, used only when the config file is missing or empty. Kept in
# sync with scripts/secret-patterns.conf (install.sh seeds the config file from
# it) and with the inline list this replaced in ai-tools-chown.sh. Basename-safe
# globs only (no bare 'config' etc. that would match innocuous files); matching
# is case-insensitive, so a single stem covers its case variants. The .NET config
# patterns are anchored to a name (appsettings/web/connectionstrings/…) or an
# environment segment, deliberately NOT broad '*.*.json'/'*.*.config' catch-alls
# that would also quarantine build artifacts the toolchain must read
# (deps.json, runtimeconfig.json, project.assets.json, MyApp.dll.config).
readonly -a _AI_TOOLS_DEFAULT_SECRET_PATTERNS=(
    '.env' '.env.*' 'env' '.environment' '.environment.*' 'environment'
    'secret' 'secrets' 'usersecrets' 'private' 'secret.*' 'secrets.*' '*.secret'
    '*.credential' 'credential' 'credentials' 'credentials.*'
    'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' 'authorized_keys'
    '*.ppk' '*.pem' '*.key' '*.priv' '*.p12' '*.pfx' '*.crt' '*.pkcs12'
    '*.jks' '*.keystore' '*.p8' '*.asc' '*.gpg'
    'kubeconfig' '.pgpass' '.git-credentials' '.dockercfg' '.htpasswd'
    '.npmrc' '.pypirc' '.netrc'
    'connectionstrings.*.json' 'ConnectionString.*.config'
    'commonsettings.*.json' 'CommonSettings.*.config'
    'appsettings.*.json' 'AppSettings.*.config' 'web.*.config' 'App.*.config'
    '*.DEV.*' '*.STAGE.*' '*.PROD.*' '*.C1_DEV.*' '*.C2_STAGE.*' '*.C3_PROD.*'
    '*.Development.*' '*.Staging.*' '*.Production.*'
)

# ai_tools_load_secret_patterns: populate the global AI_TOOLS_SECRET_PATTERNS
# array from AI_TOOLS_SECRET_PATTERNS_FILE (one pattern per line, '#' comments and
# blanks skipped, whitespace trimmed). Falls back to the built-in defaults when
# the file is unreadable or contains no patterns. Idempotent.
ai_tools_load_secret_patterns() {
    AI_TOOLS_SECRET_PATTERNS=()
    local line
    if [[ -r "${AI_TOOLS_SECRET_PATTERNS_FILE}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
            line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
            [[ -z "${line}" || "${line}" == '#'* ]] && continue
            AI_TOOLS_SECRET_PATTERNS+=("${line}")
        done < "${AI_TOOLS_SECRET_PATTERNS_FILE}"
    fi
    [[ "${#AI_TOOLS_SECRET_PATTERNS[@]}" -gt 0 ]] \
        || AI_TOOLS_SECRET_PATTERNS=("${_AI_TOOLS_DEFAULT_SECRET_PATTERNS[@]}")
    _AI_TOOLS_PATTERNS_LOADED=1
}

# ai_tools_is_secret_basename <basename>: return 0 if the basename matches any
# loaded secret pattern (case-insensitive glob), 1 otherwise. Loads patterns on
# first call. Saves and restores the caller's nocasematch setting so callers
# that rely on case-sensitive [[ ]]/case statements are unaffected.
ai_tools_is_secret_basename() {
    local base="$1" pat rc=1 _prev
    [[ -n "${_AI_TOOLS_PATTERNS_LOADED:-}" ]] || ai_tools_load_secret_patterns
    # `shopt -p nocasematch` exits non-zero when the option is OFF (the default);
    # `|| true` keeps the snapshot without tripping the caller's set -e.
    _prev="$(shopt -p nocasematch || true)"
    shopt -s nocasematch
    for pat in "${AI_TOOLS_SECRET_PATTERNS[@]}"; do
        if [[ "${base}" == ${pat} ]]; then
            rc=0
            break
        fi
    done
    eval "${_prev}"
    return "${rc}"
}
