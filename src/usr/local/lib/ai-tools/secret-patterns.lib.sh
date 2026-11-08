#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/secret-patterns.lib.sh
# The secret-name classifier for the ai-tools sandbox: one loader and one path predicate, *sourced* (never executed)
# by every component that decides whether a path is a credential file -- the root helpers that change a tree,
# the claim's advisory mark and the launch wrapper's drift line -- so the classification cannot drift between them.
# Which consumer refuses on which loader outcome, and why the operator's file replaces the baseline, are
# secret-handling.rule.md's.
#
# The pattern list is the operator's `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, owned by the operator 600
# inside the 700 .config/ai-tools (PROJECTS_HOME comes from the operator identity the caller resolves
# via operator.lib.sh), which the root helpers read on the operator's behalf. It REPLACES the defaults
# in _AI_TOOLS_SECRET_PATTERNS__DEFAULTS rather than adding to them. The loader has three outcomes: a file that is
# absent or does not hold a pattern line loads the defaults at status 0; a readable file loads its own patterns
# at status 0; a file that is PRESENT and cannot be read as a regular file loads the defaults and returns 1,
# so a consumer that ignores the status never classifies on an empty set, and a helper that changes a tree refuses
# rather than walking it on a set the operator did not write.
#
# Two lists leave a matched path open. The baseline's own, _AI_TOOLS_SECRET_PATTERNS__BASELINE_EXEMPT_PATHS, applies
# while the defaults are in force and is dropped with them by an operator file that holds a pattern. The operator's `!`
# lines name absolute paths and apply whichever set is in force. Each covers the path it names and not its subtree.
#
# Do not edit these defaults on a deployed host. The file is rpm-owned and not %config, so an upgrade overwrites it
# and a local edit is lost without a .rpmsave copy. The list is the PUBLIC baseline -- the names credential files carry
# across software in general -- and does not hold any name specific to one deployment: a project-
# or organization-specific name goes in the operator's 600 config, and a name missing from the general baseline goes
# upstream as a pull request.
#
# Config-file format: one pattern per line; '#' comments and blank lines ignored; surrounding whitespace trimmed.
# Patterns are basename globs matched case-insensitively (.ENV, Server.KEY, ID_RSA, …). A line opening with `!(` is
# a negation glob and a pattern like any other. Any other line opening with `!` is an exemption, not a pattern: `!`
# and one canonical absolute path, compared byte for byte with the canonical path a consumer holds. An exemption line
# that does not name such a path is ignored and reported under MSG-T4W8.

# Sourced more than once in a single shell (e.g. a helper that re-sources): the readonly declarations would abort
# under `set -e` on the second pass. Return early. Use an if-statement, not `[[ ]] && return` -- the latter returns 1
# when the guard var is unset and trips the sourcing shell's `set -e`.
if [[ -n "${_AI_TOOLS_SECRET_PATTERNS__LOADED:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_SECRET_PATTERNS__LOADED=1

# The exemption state the loader fills, assigned here so a caller that reads before the first load does not read
# an exemption.
_AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE=0
_AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()

# Built-in baseline, in force whenever the operator's config file is missing or parses to an empty set -- the state
# on a host where that operator has never written a pattern. Basename-safe globs only (no bare 'config' that would match
# innocuous files); matching is case-insensitive, so one stem covers its case variants. The .NET entries are anchored
# to a name (appsettings/web/connectionstrings/…) or an environment segment rather than to an extension --
# secret-handling.rule.md states what a broad '*.*.json' catch-all would quarantine.
#
# An environment-segment pattern ends in this tail, so it leaves the web assets a build reads and writes alone --
# a script, a stylesheet, a source map: a vendored bundle is named for its build (react.production.min.js), webpack's
# configs are webpack.dev.js and webpack.prod.js, and one locked 600 fails the build or test that loads it.
# The classifier reads names, not content, so a secret inside a JS file is not found by any segment pattern,
# and config.js without one was never locked. The tail is an extended glob, which `[[ == ]]` matches whether or not
# the extglob option is set: `!(…)` matches the rest of the name unless it is one of the extensions or ends in `.`
# and one of them.
readonly _AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL='!(?(*.)@(js|mjs|cjs|css|map))'
readonly -a _AI_TOOLS_SECRET_PATTERNS__DEFAULTS=(
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
    "*.DEV.${_AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL}"
    "*.STAGE.${_AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL}"
    "*.PROD.${_AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL}"
    "*.Development.${_AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL}"
    "*.Staging.${_AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL}"
    "*.Production.${_AI_TOOLS_SECRET_PATTERNS__WEB_ASSET_EXCLUSION_TAIL}"
)

# Paths the baseline matches by name that a package or a project generator ships with ordinary content, and that a build
# reads: Angular's build and Material packages name source directories `private` and `tokens`, its library schematic
# ships a `*.prod.*` template, and its application schematic writes environment files a `fileReplacements` entry reads.
# An entry is a sequence of literal path components compared case-sensitively with the LAST components of the path,
# so it matches under any project root, a nested client directory and pnpm's `node_modules/.pnpm/<pkg>/node_modules`
# layout alike. An entry does not take a glob, and does not cover a path under the one it names.
readonly -a _AI_TOOLS_SECRET_PATTERNS__BASELINE_EXEMPT_PATHS=(
    'node_modules/@angular/build/private'
    'node_modules/@angular/material/core/tokens'
    'node_modules/@angular/material/core/density/private'
    'node_modules/@schematics/angular/library/files/tsconfig.lib.prod.json.template'
    'src/environments/environment.development.ts'
    'src/environments/environment.prod.ts'
)

# _ai_tools_secret_patterns__error <code> <message>: print the code on its own line, then the message under this
# library's prefix, to stderr -- the plain-mode shape every helper's warn() prints and assert_msg reads
# (messaging.rule.md). This library has no msg.lib.sh: it is sourced by root helpers that report before any library
# loads.
_ai_tools_secret_patterns__error() {
    printf '%s\nsecret-patterns: %s\n' "$1" "$2" >&2
}

# _ai_tools_secret_patterns__warn <code> <message>: the same shape as _ai_tools_secret_patterns__error, for a line
# the loader ignored while the set it loaded stands.
_ai_tools_secret_patterns__warn() {
    printf '%s\nsecret-patterns: %s\n' "$1" "$2" >&2
}

# _ai_tools_secret_patterns__is_exempt_path_valid <path>: 0 when <path> can equal a canonical path -- absolute, without
# an empty, `.` or `..` component, without a trailing `/`, and without `*`, `?` or `[`, which would read as a glob
# to a writer who meant one -- 1 otherwise.
_ai_tools_secret_patterns__is_exempt_path_valid() {
    local path="$1"
    [[ "${path}" == /?* ]] || return 1
    [[ "${path}" != *[*?[]* ]] || return 1
    [[ "${path}/" != *//* && "${path}/" != */./* && "${path}/" != */../* ]] || return 1
    return 0
}

# ai_tools_secret_patterns__load: populate the global AI_TOOLS_SECRET_PATTERNS__PATTERNS array from the operator's
# secret-patterns config (one pattern per line, '#' comments and blanks skipped, whitespace trimmed). The config path is
# resolved at the call: AI_TOOLS_SECRET_PATTERNS_FILE overrides it (a test hook), else
# `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, so a caller resolves the operator first
# (ai_tools_operator__resolve_owner for the path's owner, or ai_tools_operator__load_operator) -- a load made
# before the resolve reads the defaults and marks the set loaded, so the operator's file is never read. Returns 0
# with the file's patterns, or with the built-in defaults when the file is absent or does not hold a pattern line.
# Returns 1 when the path is present and is not a readable regular file -- a directory, a dangling symlink, a FIFO,
# a read access(2) refuses -- with the defaults loaded all the same, AI_TOOLS_SECRET_PATTERNS__UNREADABLE naming
# the file, and MSG-S4T9 printed. _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE is 1 wherever the defaults were loaded,
# which turns the baseline's exemptions on. The file's `!` lines fill _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS
# and do not count as patterns; each malformed one prints MSG-T4W8 with its line number and leaves the status as it is.
# Re-callable: each call reloads.
ai_tools_secret_patterns__load() {
    AI_TOOLS_SECRET_PATTERNS__PATTERNS=()
    AI_TOOLS_SECRET_PATTERNS__UNREADABLE=""
    _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()
    _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE=0
    local line status=0
    local -i line_number=0
    local -a malformed_line_numbers=()
    local file="${AI_TOOLS_SECRET_PATTERNS_FILE:-${PROJECTS_HOME:-}/.config/ai-tools/secret-patterns}"
    if [[ -e "${file}" || -L "${file}" ]]; then
        # `-f` before the open: a FIFO at the path would block the open, and a directory or a dangling link is refused
        # for what it is, with no read error to interpret.
        if [[ -f "${file}" && -r "${file}" ]] && {
                while IFS= read -r line || [[ -n "${line}" ]]; do
                    line_number+=1
                    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
                    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
                    [[ -z "${line}" || "${line}" == '#'* ]] && continue
                    # `!(` opens a negation glob, a pattern; an absolute path cannot open with `(`.
                    if [[ "${line}" == '!'* && "${line}" != '!('* ]]; then
                        if _ai_tools_secret_patterns__is_exempt_path_valid "${line#!}"; then
                            _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS+=("${line#!}")
                        else
                            malformed_line_numbers+=("${line_number}")
                        fi
                        continue
                    fi
                    AI_TOOLS_SECRET_PATTERNS__PATTERNS+=("${line}")
                done < "${file}"
            } 2>/dev/null; then
            :
        else
            AI_TOOLS_SECRET_PATTERNS__PATTERNS=()
            _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()
            malformed_line_numbers=()
            AI_TOOLS_SECRET_PATTERNS__UNREADABLE="${file}"
            status=1
        fi
    fi
    if [[ "${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}" -eq 0 ]]; then
        AI_TOOLS_SECRET_PATTERNS__PATTERNS=("${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}")
        _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE=1
    fi
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=1
    if (( status )); then
        _ai_tools_secret_patterns__error MSG-S4T9 "the secret-patterns file ${file} is present and cannot be read as a regular file -- the shipped baseline classifies instead, and a helper that changes a tree refuses; make it a readable file, or remove it to keep the baseline"
    fi
    for line_number in "${malformed_line_numbers[@]}"; do
        _ai_tools_secret_patterns__warn MSG-T4W8 "line ${line_number} of ${file} opens with '!' and does not name a canonical absolute path -- the line is ignored and the path it meant stays locked; write '!' and the path realpath prints, without * ? or ["
    done
    return "${status}"
}

# ai_tools_secret_patterns__get_file_path: print the config path the loader reads for the operator resolved so far,
# whether or not it exists. One resolution shared by the loader and by any caller that reports WHICH file is in force,
# so a report cannot name a path other than the one that was read.
ai_tools_secret_patterns__get_file_path() {
    printf '%s\n' "${AI_TOOLS_SECRET_PATTERNS_FILE:-${PROJECTS_HOME:-}/.config/ai-tools/secret-patterns}"
}

# ai_tools_secret_patterns__format_drift: print how the set in force differs from the shipped baseline, as one line
# naming the file, what it ADDS, and what of the baseline it DROPS. Prints nothing and returns 1 when the baseline is
# the set in force -- the case of a missing file and of a file without a pattern line, since the loader falls back
# to the baseline there, so a host that has written no patterns is silent. A `!` line is not a pattern and is not
# compared. What the difference costs a host, and where the launch wrapper records it, are
# secret-handling.rule.md's.
#
# Compared as a SET (sorted, de-duplicated). A file whose set equals the baseline's, reordered or repeated, prints
# a line of its own and returns 0: it holds the baseline's patterns, and its patterns replace the baseline's path
# exemptions, which the loader applies only while the defaults are in force. Each list is capped, because the report is
# a prompt to re-read the file rather than a replacement for reading it. A file that is present and cannot be read
# prints its own line and returns 0: the baseline is in force, which is not what the operator wrote, and every helper
# that acts on that operator's trees is refusing until it is fixed.
ai_tools_secret_patterns__format_drift() {
    [[ -n "${_AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED:-}" ]] || ai_tools_secret_patterns__load 2>/dev/null || true
    if [[ -n "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE:-}" ]]; then
        printf 'secret patterns: %s is present and cannot be read -- the shipped baseline is in force, and the claim, handback and lockdown helpers refuse until it is a readable file or removed\n' \
            "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}"
        return 0
    fi
    local -a live baseline added dropped
    mapfile -t live < <(printf '%s\n' "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}" | LC_ALL=C sort -u)
    mapfile -t baseline < <(printf '%s\n' "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}" | LC_ALL=C sort -u)
    if [[ "${live[*]}" == "${baseline[*]}" ]]; then
        (( _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE )) && return 1
        printf "secret patterns: %s lists the shipped baseline's patterns and replaces its path exemptions -- remove the file to restore them, or keep a path open with a '!' line\n" \
            "$(ai_tools_secret_patterns__get_file_path)"
        return 0
    fi
    mapfile -t added < <(LC_ALL=C comm -23 <(printf '%s\n' "${live[@]}") <(printf '%s\n' "${baseline[@]}"))
    mapfile -t dropped < <(LC_ALL=C comm -13 <(printf '%s\n' "${live[@]}") <(printf '%s\n' "${baseline[@]}"))
    printf 'secret patterns: %s replaces the shipped baseline and its path exemptions -- adds %d%s; drops %d%s\n' \
        "$(ai_tools_secret_patterns__get_file_path)" \
        "${#added[@]}"   "$(_ai_tools_secret_patterns__format_list added)" \
        "${#dropped[@]}" "$(_ai_tools_secret_patterns__format_list dropped)"
    return 0
}

# Render an array name as " (a, b, c, +N more)", or nothing when it is empty. Capped at 12: a journald line is read
# at a glance, and the file itself is the place to read the whole set.
_ai_tools_secret_patterns__format_list() {
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

# ai_tools_secret_patterns__is_secret_path <path>: return 0 when the last component of <path> matches a loaded secret
# pattern and <path> is not exempt, 1 otherwise. A consumer passes the canonical path it acts on, absolute,
# or the canonical path of each component it classifies: an operator's `!` line is compared with the whole path,
# and a baseline exemption with its last components. Loads patterns on first call.
ai_tools_secret_patterns__is_secret_path() {
    local path="$1"
    _ai_tools_secret_patterns__is_secret_basename "${path##*/}" || return 1
    _ai_tools_secret_patterns__is_operator_exempt_path "${path}" && return 1
    (( _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE )) && _ai_tools_secret_patterns__is_baseline_exempt_path "${path}" \
        && return 1
    return 0
}

# _ai_tools_secret_patterns__is_secret_basename <basename>: return 0 if the basename matches any loaded secret pattern
# (case-insensitive glob), 1 otherwise. Loads patterns on first call. Saves and restores the caller's nocasematch
# setting so callers that rely on case-sensitive [[ ]]/case statements are unaffected.
_ai_tools_secret_patterns__is_secret_basename() {
    local base="$1" pat rc=1 _prev
    [[ -n "${_AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED:-}" ]] || ai_tools_secret_patterns__load
    # `shopt -p nocasematch` exits non-zero when the option is OFF (the default); `|| true` keeps the snapshot without
    # tripping the caller's `set -e`.
    _prev="$(shopt -p nocasematch || true)"
    shopt -s nocasematch
    for pat in "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}"; do
        if [[ "${base}" == ${pat} ]]; then
            rc=0
            break
        fi
    done
    eval "${_prev}"
    return "${rc}"
}

# _ai_tools_secret_patterns__is_baseline_exempt_path <path>: 0 when <path> is an entry
# of _AI_TOOLS_SECRET_PATTERNS__BASELINE_EXEMPT_PATHS or ends in `/` and one, compared case-sensitively whatever
# the caller's nocasematch setting; 1 otherwise.
_ai_tools_secret_patterns__is_baseline_exempt_path() {
    local path="$1" entry rc=1 _prev
    _prev="$(shopt -p nocasematch || true)"
    shopt -u nocasematch
    for entry in "${_AI_TOOLS_SECRET_PATTERNS__BASELINE_EXEMPT_PATHS[@]}"; do
        if [[ "${path}" == "${entry}" || "${path}" == *"/${entry}" ]]; then
            rc=0
            break
        fi
    done
    eval "${_prev}"
    return "${rc}"
}

# _ai_tools_secret_patterns__is_operator_exempt_path <path>: 0 when <path> equals one of the operator's `!` paths,
# compared case-sensitively whatever the caller's nocasematch setting; 1 otherwise.
_ai_tools_secret_patterns__is_operator_exempt_path() {
    local path="$1" entry rc=1 _prev
    _prev="$(shopt -p nocasematch || true)"
    shopt -u nocasematch
    for entry in "${_AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS[@]}"; do
        if [[ "${path}" == "${entry}" ]]; then
            rc=0
            break
        fi
    done
    eval "${_prev}"
    return "${rc}"
}
