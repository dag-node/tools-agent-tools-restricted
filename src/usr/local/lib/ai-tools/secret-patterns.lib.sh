#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/secret-patterns.lib.sh
# The secret-name classifier for the ai-tools sandbox: one loader and one path predicate, *sourced* (never executed)
# by every component that decides whether a path is a credential file -- the root helpers that change a tree,
# the claim's advisory mark and the launch wrapper's journal line -- so the classification cannot drift between them.
# Which consumer refuses on which loader outcome is secret-handling.rule.md's.
#
# The pattern list is the operator's `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, owned by the operator 600
# inside the 700 .config/ai-tools (PROJECTS_HOME comes from the operator identity the caller resolves
# via operator.lib.sh), which the root helpers read on the operator's behalf. Its patterns are ADDED to the defaults
# in _AI_TOOLS_SECRET_PATTERNS__DEFAULTS, so no file classifies fewer names than the baseline. The loader has two
# outcomes: a file that is absent or readable loads the defaults and the file's patterns at status 0; a file that is
# PRESENT and cannot be read as a regular file loads the defaults alone and returns 1, so a helper that changes a tree
# refuses rather than walking it on a set without the names the operator wrote.
#
# Two lists leave a matched path open, and each covers the path it names and not its subtree: the baseline's own,
# _AI_TOOLS_SECRET_PATTERNS__BASELINE_EXEMPT_PATHS, and the operator's `!` lines, which name absolute paths. A pattern
# of the operator's own that matches a baseline-exempt path locks it, since the operator named it after the baseline
# did; a line repeating a baseline entry is the baseline's, and leaves the exemption in force.
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

# The operator's exemptions and the operator's own patterns -- the file's patterns less those repeating a baseline entry
# -- the loader fills, assigned here so a caller that reads before the first load does not read either.
_AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()
_AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS=()

# Built-in baseline, in force for every operator, beside the patterns their own file adds. Basename-safe globs only (no
# bare 'config' that would match innocuous files); matching is case-insensitive, so one stem covers its case variants.
# The .NET entries are anchored to a name (appsettings/web/connectionstrings/…) or an environment segment rather than
# to an extension -- secret-handling.rule.md states what a broad '*.*.json' catch-all would quarantine.
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
# secret-patterns config (one pattern per line, '#' comments and blanks skipped, whitespace trimmed), after the built-in
# defaults. The config path is resolved at the call: AI_TOOLS_SECRET_PATTERNS_FILE overrides it (a test hook), else
# `<PROJECTS_HOME>/.config/ai-tools/secret-patterns`, so a caller resolves the operator first
# (ai_tools_operator__resolve_owner for the path's owner, or ai_tools_operator__load_operator) -- a load made
# before the resolve reads the defaults and marks the set loaded, so the operator's file is never read. Returns 0
# with the defaults and the file's patterns, the defaults alone when the file is absent. Returns 1 when the path is
# present and is not a readable regular file -- a directory, a dangling symlink, a FIFO, a read access(2) refuses --
# with the defaults alone, AI_TOOLS_SECRET_PATTERNS__UNREADABLE naming the file, and MSG-S4T9 printed. The file's `!`
# lines fill _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS; each malformed one prints MSG-T4W8 with its line number
# and leaves the status as it is. Each pattern that is not a baseline entry, compared case-insensitively, also fills
# _AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS. Re-callable: each call reloads.
ai_tools_secret_patterns__load() {
    AI_TOOLS_SECRET_PATTERNS__PATTERNS=("${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}")
    AI_TOOLS_SECRET_PATTERNS__UNREADABLE=""
    _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()
    _AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS=()
    local line default status=0
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
                    for default in "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}"; do
                        [[ "${line,,}" == "${default,,}" ]] && continue 2
                    done
                    _AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS+=("${line}")
                done < "${file}"
            } 2>/dev/null; then
            :
        else
            AI_TOOLS_SECRET_PATTERNS__PATTERNS=("${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}")
            _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()
            _AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS=()
            malformed_line_numbers=()
            AI_TOOLS_SECRET_PATTERNS__UNREADABLE="${file}"
            status=1
        fi
    fi
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=1
    if (( status )); then
        _ai_tools_secret_patterns__error MSG-S4T9 "the secret-patterns file ${file} is present and cannot be read as a regular file -- the shipped baseline classifies alone, and a helper that changes a tree refuses; make it a readable file, or remove it"
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

# ai_tools_secret_patterns__format_unreadable_report: print one line naming the operator's secret-patterns file when it
# is present and cannot be read, and return 0; print nothing and return 1 otherwise. That is the one state
# in which the set in force lacks the operator's patterns: the baseline classifies alone for that operator's sessions,
# and every helper that acts on that operator's trees refuses until the file is fixed. Where the launch wrapper records
# the line is secret-handling.rule.md's.
ai_tools_secret_patterns__format_unreadable_report() {
    [[ -n "${_AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED:-}" ]] || ai_tools_secret_patterns__load 2>/dev/null || true
    [[ -n "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE:-}" ]] || return 1
    printf 'secret patterns: %s is present and cannot be read -- the shipped baseline classifies alone, and the claim, handback and lockdown helpers refuse until it is a readable file or removed\n' \
        "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}"
}

# ai_tools_secret_patterns__is_secret_path <path>: return 0 when the last component of <path> matches a loaded secret
# pattern and <path> is not exempt, 1 otherwise. A consumer passes the canonical path it acts on, absolute,
# or the canonical path of each component it classifies: an operator's `!` line is compared with the whole path,
# and a baseline exemption with its last components. A baseline exemption does not open a path one of the operator's own
# patterns matches. Loads patterns on first call.
ai_tools_secret_patterns__is_secret_path() {
    local path="$1"
    _ai_tools_secret_patterns__is_secret_basename "${path##*/}" || return 1
    _ai_tools_secret_patterns__is_operator_exempt_path "${path}" && return 1
    if _ai_tools_secret_patterns__is_baseline_exempt_path "${path}" \
            && ! _ai_tools_secret_patterns__is_basename_matched "${path##*/}" \
                "${_AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS[@]}"; then
        return 1
    fi
    return 0
}

# _ai_tools_secret_patterns__is_secret_basename <basename>: return 0 if the basename matches any loaded secret pattern
# (case-insensitive glob), 1 otherwise. Loads patterns on first call.
_ai_tools_secret_patterns__is_secret_basename() {
    [[ -n "${_AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED:-}" ]] || ai_tools_secret_patterns__load
    _ai_tools_secret_patterns__is_basename_matched "$1" "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}"
}

# _ai_tools_secret_patterns__is_basename_matched <basename> [<pattern>...]: return 0 if the basename matches one
# of the patterns (case-insensitive glob), 1 otherwise, and 1 for an empty list. Saves and restores the caller's
# nocasematch setting so callers that rely on case-sensitive [[ ]]/case statements are unaffected.
_ai_tools_secret_patterns__is_basename_matched() {
    local base="$1" pat rc=1 _prev
    shift
    # `shopt -p nocasematch` exits non-zero when the option is OFF (the default); `|| true` keeps the snapshot without
    # tripping the caller's `set -e`.
    _prev="$(shopt -p nocasematch || true)"
    shopt -s nocasematch
    for pat in "$@"; do
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
