#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/secret-patterns.lib.sh
# Shared secret-name pattern set for the ai-tools sandbox. This file is *sourced*
# (never executed) by the root helpers ai-tools-chown and ai-tools-lockdown so
# both decide whether a basename is a credential file by the SAME rules from the
# SAME source -- the matcher cannot drift between them.
#
# The authoritative pattern list lives in a user-owned config file under the operator's
# home, `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, owned by the operator 600
# (PROJECTS_HOME comes from the operator identity the caller resolves via operator.lib.sh).
# The user edits it; ai-tools -- neither its owner nor in its group, and unable to enter the
# 700 .config/ai-tools dir -- can neither read nor write it; the root helpers read it on the
# user's behalf.
# This mirrors how allowed-projects is owned and consumed. A config file REPLACES the
# defaults rather than adding to them, and the defaults below apply when it is absent or
# parses to an empty set, so classification never silently degrades to an empty pattern set.
#
# Do not edit the defaults below on a deployed host. The file is rpm-owned and not %config,
# so an upgrade overwrites it and a local edit is lost without a .rpmsave copy. The list is
# the PUBLIC baseline -- the names credential files carry across software in general -- and
# does not hold any name specific to one deployment. A change belongs in one of two other
# places: a project- or organization-specific name goes in the operator's 600 config above,
# and a name missing from the general baseline goes upstream as a pull request. The baseline
# is incomplete by construction, since it tracks conventions that keep appearing.
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

# Built-in baseline, in force whenever the operator's config file is missing or parses to an
# empty set -- the state on a host where that operator has never written a pattern. Basename-safe globs
# only (no bare 'config' that would match innocuous files); matching is case-insensitive, so one
# stem covers its case variants. The .NET entries are anchored to a name
# (appsettings/web/connectionstrings/…) or an environment segment rather than to an extension --
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

# ai_tools_load_secret_patterns: populate the global AI_TOOLS_SECRET_PATTERNS array from the
# operator's secret-patterns config (one pattern per line, '#' comments and blanks skipped,
# whitespace trimmed). The config path is resolved lazily here: AI_TOOLS_SECRET_PATTERNS_FILE
# overrides it (a test hook), else `<PROJECTS_HOME>/.config/ai-tools/secret-patterns` -- so a
# caller that has resolved an operator first (ai_tools_resolve_owner for the path's owner, or
# ai_tools_load_operator) reads that operator's file. Falls back to the built-in defaults when
# the file is unreadable or parses to an empty set. Idempotent.
ai_tools_load_secret_patterns() {
    AI_TOOLS_SECRET_PATTERNS=()
    local line
    local file="${AI_TOOLS_SECRET_PATTERNS_FILE:-${PROJECTS_HOME:-}/.config/ai-tools/secret-patterns}"
    if [[ -r "${file}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
            line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
            [[ -z "${line}" || "${line}" == '#'* ]] && continue
            AI_TOOLS_SECRET_PATTERNS+=("${line}")
        done < "${file}"
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
