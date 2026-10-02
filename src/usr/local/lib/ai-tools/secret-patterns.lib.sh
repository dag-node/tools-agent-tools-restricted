#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/secret-patterns.lib.sh
# The secret-name classifier for the ai-tools sandbox: one loader and one matcher, *sourced* (never executed) by every
# component that decides whether a basename is a credential file -- the root helpers that change a tree, the claim's
# advisory mark and the launch wrapper's drift line -- so the matcher cannot drift between them. Which consumer refuses
# on which loader outcome, and why the operator's file replaces the baseline, are secret-handling.rule.md's.
#
# The pattern list is the operator's `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, owned by the operator 600
# inside the 700 .config/ai-tools (PROJECTS_HOME comes from the operator identity the caller resolves
# via operator.lib.sh), which the root helpers read on the operator's behalf. It REPLACES the defaults
# in _AI_TOOLS_DEFAULT_SECRET_PATTERNS rather than adding to them. The loader has three outcomes: a file that is absent
# or holds only comments loads the defaults at status 0; a readable file loads its own patterns at status 0; a file
# that is PRESENT and cannot be read as a regular file loads the defaults and returns 1, so a consumer that ignores
# the status never classifies on an empty set, and a helper that changes a tree refuses rather than walking it on a set
# the operator did not write.
#
# Do not edit these defaults on a deployed host. The file is rpm-owned and not %config, so an upgrade overwrites it
# and a local edit is lost without a .rpmsave copy. The list is the PUBLIC baseline -- the names credential files carry
# across software in general -- and does not hold any name specific to one deployment: a project-
# or organization-specific name goes in the operator's 600 config, and a name missing from the general baseline goes
# upstream as a pull request.
#
# Config-file format: one pattern per line; '#' comments and blank lines ignored; surrounding whitespace trimmed.
# Patterns are basename globs matched case-insensitively (.ENV, Server.KEY, ID_RSA, …).

# Sourced more than once in a single shell (e.g. a helper that re-sources): the readonly declarations would abort
# under `set -e` on the second pass. Return early. Use an if-statement, not `[[ ]] && return` -- the latter returns 1
# when the guard var is unset and trips the sourcing shell's `set -e`.
if [[ -n "${_AI_TOOLS_SECRET_PATTERNS_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_SECRET_PATTERNS_LIB=1

# Built-in baseline, in force whenever the operator's config file is missing or parses to an empty set -- the state
# on a host where that operator has never written a pattern. Basename-safe globs only (no bare 'config' that would match
# innocuous files); matching is case-insensitive, so one stem covers its case variants. The .NET entries are anchored
# to a name (appsettings/web/connectionstrings/…) or an environment segment rather than to an extension --
# secret-handling.rule.md states what a broad '*.*.json' catch-all would quarantine.
readonly -a _AI_TOOLS_DEFAULT_SECRET_PATTERNS=(
    '.env' '.env.*' '*.env' 'env' '.envrc' '.environment' '.environment.*' 'environment'
    'secret' 'secrets' 'usersecrets' 'private' 'secret.*' 'secrets.*' '*.secret'
    '*.credential' 'credential' 'credentials' 'credentials.*'
    'password' 'passwords' 'password.*' 'passwords.*'
    'apikey' 'apikeys' 'api_key' 'api_keys' '*.apikey'
    'token' 'tokens' '.token' '*.token'
    'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' 'authorized_keys'
    '*.ppk' '*.pem' '*.key' '*.priv' '*.p12' '*.pfx' '*.pkcs12'
    '*.jks' '*.keystore' '*.p8' '*.gpg' '*.kdbx' '*.ovpn'
    'secring' 'secring.*' 'privkey' 'privkey.*'
    'kubeconfig' '*.kubeconfig' '.pgpass' '.git-credentials' '.dockercfg' '.htpasswd'
    '.npmrc' '.pypirc' '.netrc' '.boto' '.s3cfg' '.my.cnf' 'my.cnf' '.mylogin.cnf'
    '.vault-token' 'vault_pass' 'vault_pass.*'
    '*.tfvars' '*.tfstate' '*.tfstate.backup'
    'service-account.json' 'service-account-*.json' '*-service-account.json'
    'client_secret.json' 'client_secret_*.json' 'application_default_credentials.json'
    '*.publishsettings' '*.pubxml.user' '*.mobileprovision'
    'connectionstrings.*.json' 'ConnectionString.*.config'
    'commonsettings.*.json' 'CommonSettings.*.config'
    'appsettings.*.json' 'AppSettings.*.config' 'web.*.config' 'App.*.config'
    '*.DEV.*' '*.STAGE.*' '*.PROD.*'
    '*.Development.*' '*.Staging.*' '*.Production.*'
)

# _ai_tools_secret_patterns_error <code> <message>: print the code on its own line, then the message under this
# library's prefix, to stderr -- the plain-mode shape every helper's warn() prints and assert_msg reads
# (messaging.rule.md). This library has no msg.lib.sh: it is sourced by root helpers that report before any library
# loads.
_ai_tools_secret_patterns_error() {
    printf '%s\nsecret-patterns: %s\n' "$1" "$2" >&2
}

# ai_tools_load_secret_patterns: populate the global AI_TOOLS_SECRET_PATTERNS array from the operator's secret-patterns
# config (one pattern per line, '#' comments and blanks skipped, whitespace trimmed). The config path is resolved
# at the call: AI_TOOLS_SECRET_PATTERNS_FILE overrides it (a test hook), else
# `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, so a caller resolves the operator first (ai_tools_resolve_owner
# for the path's owner, or ai_tools_load_operator) -- a load made before the resolve reads the defaults and marks
# the set loaded, so the operator's file is never read. Returns 0 with the file's patterns, or with the built-in
# defaults when the file is absent or parses to an empty set. Returns 1 when the path is present and is not a readable
# regular file -- a directory, a dangling symlink, a FIFO, a read access(2) refuses -- with the defaults loaded all
# the same, AI_TOOLS_SECRET_PATTERNS_UNREADABLE naming the file, and MSG-S4T9 printed. Re-callable: each call
# reloads.
ai_tools_load_secret_patterns() {
    AI_TOOLS_SECRET_PATTERNS=()
    AI_TOOLS_SECRET_PATTERNS_UNREADABLE=""
    local line status=0
    local file="${AI_TOOLS_SECRET_PATTERNS_FILE:-${PROJECTS_HOME:-}/.config/ai-tools/secret-patterns}"
    if [[ -e "${file}" || -L "${file}" ]]; then
        # `-f` before the open: a FIFO at the path would block the open, and a directory or a dangling link is refused
        # for what it is, with no read error to interpret.
        if [[ -f "${file}" && -r "${file}" ]] && {
                while IFS= read -r line || [[ -n "${line}" ]]; do
                    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
                    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
                    [[ -z "${line}" || "${line}" == '#'* ]] && continue
                    AI_TOOLS_SECRET_PATTERNS+=("${line}")
                done < "${file}"
            } 2>/dev/null; then
            :
        else
            AI_TOOLS_SECRET_PATTERNS=()
            AI_TOOLS_SECRET_PATTERNS_UNREADABLE="${file}"
            status=1
        fi
    fi
    [[ "${#AI_TOOLS_SECRET_PATTERNS[@]}" -gt 0 ]] \
        || AI_TOOLS_SECRET_PATTERNS=("${_AI_TOOLS_DEFAULT_SECRET_PATTERNS[@]}")
    _AI_TOOLS_PATTERNS_LOADED=1
    if (( status )); then
        _ai_tools_secret_patterns_error MSG-S4T9 "the secret-patterns file ${file} is present and cannot be read as a regular file -- the shipped baseline classifies instead, and a helper that changes a tree refuses; make it a readable file, or remove it to keep the baseline"
    fi
    return "${status}"
}

# ai_tools_secret_patterns_file: print the config path the loader reads for the operator resolved so far, whether or not
# it exists. One resolution shared by the loader and by any caller that reports WHICH file is in force, so a report
# cannot name a path other than the one that was read.
ai_tools_secret_patterns_file() {
    printf '%s\n' "${AI_TOOLS_SECRET_PATTERNS_FILE:-${PROJECTS_HOME:-}/.config/ai-tools/secret-patterns}"
}

# ai_tools_secret_patterns_drift: print how the set in force differs from the shipped baseline, as one line naming
# the file, what it ADDS, and what of the baseline it DROPS. Prints nothing and returns 1 when the two agree -- which is
# also the missing-file and empty-file case, since the loader falls back to the baseline there, so a host that has
# written no patterns is silent. What the difference costs a host, and where the launch wrapper records it, are
# secret-handling.rule.md's.
#
# Compared as a SET (sorted, de-duplicated), so a reordered or repeated copy of the baseline reads as agreement. Each
# list is capped, because the report is a prompt to re-read the file rather than a replacement for reading it. A file
# that is present and cannot be read prints its own line and returns 0: the baseline is in force, which is not
# what the operator wrote, and every helper that acts on that operator's trees is refusing until it is fixed.
ai_tools_secret_patterns_drift() {
    [[ -n "${_AI_TOOLS_PATTERNS_LOADED:-}" ]] || ai_tools_load_secret_patterns 2>/dev/null || true
    if [[ -n "${AI_TOOLS_SECRET_PATTERNS_UNREADABLE:-}" ]]; then
        printf 'secret patterns: %s is present and cannot be read -- the shipped baseline is in force, and the claim, handback and lockdown helpers refuse until it is a readable file or removed\n' \
            "${AI_TOOLS_SECRET_PATTERNS_UNREADABLE}"
        return 0
    fi
    local -a live baseline added dropped
    mapfile -t live < <(printf '%s\n' "${AI_TOOLS_SECRET_PATTERNS[@]}" | LC_ALL=C sort -u)
    mapfile -t baseline < <(printf '%s\n' "${_AI_TOOLS_DEFAULT_SECRET_PATTERNS[@]}" | LC_ALL=C sort -u)
    [[ "${live[*]}" != "${baseline[*]}" ]] || return 1
    mapfile -t added < <(LC_ALL=C comm -23 <(printf '%s\n' "${live[@]}") <(printf '%s\n' "${baseline[@]}"))
    mapfile -t dropped < <(LC_ALL=C comm -13 <(printf '%s\n' "${live[@]}") <(printf '%s\n' "${baseline[@]}"))
    printf 'secret patterns: %s replaces the shipped baseline -- adds %d%s; drops %d%s\n' \
        "$(ai_tools_secret_patterns_file)" \
        "${#added[@]}"   "$(_ai_tools_secret_patterns_list added)" \
        "${#dropped[@]}" "$(_ai_tools_secret_patterns_list dropped)"
    return 0
}

# Render an array name as " (a, b, c, +N more)", or nothing when it is empty. Capped at 12: a journald line is read
# at a glance, and the file itself is the place to read the whole set.
_ai_tools_secret_patterns_list() {
    local -n _arr="$1"
    local -i cap=12 n="${#_arr[@]}"
    (( n )) || return 0
    local shown
    shown="$(printf '%s, ' "${_arr[@]:0:cap}")"; shown="${shown%, }"
    if (( n > cap )); then
        printf ' (%s, +%d more)' "${shown}" "$(( n - cap ))"
    else
        printf ' (%s)' "${shown}"
    fi
}

# ai_tools_is_secret_basename <basename>: return 0 if the basename matches any loaded secret pattern (case-insensitive
# glob), 1 otherwise. Loads patterns on first call. Saves and restores the caller's nocasematch setting so callers
# that rely on case-sensitive [[ ]]/case statements are unaffected.
ai_tools_is_secret_basename() {
    local base="$1" pat rc=1 _prev
    [[ -n "${_AI_TOOLS_PATTERNS_LOADED:-}" ]] || ai_tools_load_secret_patterns
    # `shopt -p nocasematch` exits non-zero when the option is OFF (the default); `|| true` keeps the snapshot without
    # tripping the caller's `set -e`.
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
