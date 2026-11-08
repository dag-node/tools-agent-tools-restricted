#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/secret-patterns.sh
# Unit test for the shared secret-name classifier (secret-patterns.lib.sh), the single matcher ai-tools-chown
# and ai-tools-lockdown both source. Pins the SHIPPED default pattern set's behaviour hermetically: it sources
# the deployed library and forces the built-in defaults (independent of the operator's live secret-patterns config),
# then asserts the security-critical properties -- credential names match, matching is case-insensitive,
# and environment/name-anchored .NET configs match while plain configs and build artifacts the toolchain must read do
# NOT (a false positive quarantines a build input and breaks the build). Run as root via sudo (the suite contract); does
# not need privilege of its own.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
section "secret classifier: shared matcher defaults (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "secret classifier" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}"; then
    skip "secret classifier" "could not source ${LIB}"; finish; exit
fi

# Force the SHIPPED defaults so the test is independent of the operator's secret-patterns config: copy the built-in
# list, record the baseline as the set in force, as the loader does when it loads the defaults, and mark patterns
# loaded, so the matcher skips the config-file read.
force_baseline() {
    AI_TOOLS_SECRET_PATTERNS__PATTERNS=("${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}")
    _AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS=()
    _AI_TOOLS_SECRET_PATTERNS__OPERATOR_PATTERNS=()
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=1
}
force_baseline

# (1) Credential names are classified as secrets.
secret_ok=true
for n in .env .env.local id_rsa id_ed25519 authorized_keys server.key cert.pem backup.p12 \
         store.jks kubeconfig .pgpass .npmrc .netrc .git-credentials secrets credentials; do
    _ai_tools_secret_patterns__is_secret_basename "${n}" || { fail "should classify as secret: ${n}"; secret_ok=false; }
done
${secret_ok} && pass "credential names are classified as secrets"

# (2) Matching is case-insensitive (a single stem covers its case variants).
case_ok=true
for n in .ENV ID_RSA Server.KEY CERT.PEM KubeConfig; do
    _ai_tools_secret_patterns__is_secret_basename "${n}" || { fail "should match case-insensitively: ${n}"; case_ok=false; }
done
${case_ok} && pass "matching is case-insensitive"

# (3) Environment/name-anchored .NET configs ARE secrets.
dotnet_ok=true
for n in appsettings.Production.json appsettings.Development.json web.Release.config \
         App.Staging.config connectionstrings.dev.json CommonSettings.PROD.json; do
    _ai_tools_secret_patterns__is_secret_basename "${n}" || { fail "anchored .NET secret should match: ${n}"; dotnet_ok=false; }
done
${dotnet_ok} && pass "environment/name-anchored .NET configs are classified as secrets"

# (4) Plain configs and build artifacts the toolchain must read are NOT secrets. The default
#     set is deliberately anchored, not a broad *.*.json / *.*.config catch-all, so these
#     stay readable; a false positive here breaks builds.
build_ok=true
for n in appsettings.json web.config MyApp.deps.json MyApp.runtimeconfig.json \
         project.assets.json MyApp.dll.config package.json tsconfig.json README.md Makefile; do
    if _ai_tools_secret_patterns__is_secret_basename "${n}"; then
        fail "build artifact / innocuous file wrongly quarantined: ${n}"; build_ok=false
    fi
done
${build_ok} && pass "plain configs and build artifacts are NOT quarantined"

# (4b) The environment-segment patterns leave a script, a stylesheet and a source map alone: a vendored bundle is named
#      for its build, and a locked one fails the build that loads it. Every other extension after a segment stays
#      locked, so the controls beside the bundles are a config, a JSX and a TypeScript file carrying the same segments,
#      and the exclusion belongs to the segment patterns alone: a credential-named script matches its own pattern.
bundle_ok=true
for n in react.production.min.js react-dom.production.min.js REACT.PRODUCTION.MIN.JS vue.runtime.prod.js \
         app.development.mjs lib.dev.cjs theme.Production.css main.production.js.map site.STAGE.min.css \
         webpack.prod.js webpack.DEV.js config.production.js config.production.js.map; do
    if _ai_tools_secret_patterns__is_secret_basename "${n}"; then
        fail "script, stylesheet or source map after an environment segment wrongly quarantined: ${n}"; bundle_ok=false
    fi
done
for n in appsettings.Production.json Web.Release.config settings.Production.yaml db.PROD.ini \
         config.production.js.json app.production.jsx deploy.staging.ts environment.prod.ts \
         secrets.production.min.js SECRETS.PRODUCTION.MIN.JS credentials.dev.js; do
    _ai_tools_secret_patterns__is_secret_basename "${n}" \
        || { fail "a non-script file after an environment segment should match: ${n}"; bundle_ok=false; }
done
${bundle_ok} && pass "environment-segment patterns leave scripts, stylesheets and source maps alone, and lock the rest"

# (5) The seeded config file leaves classification unchanged. `ai-tools-admin operators add` writes that file
# at enrolment, before the operator has decided anything, so what it writes must parse to no pattern and leave
# the built-in baseline classifying alone -- a seed that parsed to a pattern would lock a name the operator never chose.
CONF_LIB="/usr/local/lib/ai-tools/conf.lib.sh"
if [[ -r "${CONF_LIB}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF_LIB}"
fi
if declare -F ai_tools_conf__get_secret_patterns_seed >/dev/null 2>&1; then
    seed_file="$(mktemp)"
    ai_tools_conf__get_secret_patterns_seed > "${seed_file}"
    AI_TOOLS_SECRET_PATTERNS_FILE="${seed_file}" ai_tools_secret_patterns__load
    if [[ "${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}" -eq "${#_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}" ]] \
            && _ai_tools_secret_patterns__is_secret_basename .env; then
        pass "the seeded config parses to no pattern, so the baseline stays in force"
    else
        fail "the seeded config changed the loaded pattern set (${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} patterns)"
    fi
    # The one claim the seeded header must always carry, asserted by the grep that follows it: the baseline always
    # applies, and an operator's pattern is added to it.
    if grep -qi 'baseline always applies' "${seed_file}" && grep -qi 'additive' "${seed_file}"; then
        pass "the seeded header states that the baseline always applies and a pattern adds to it"
    else
        fail "the seeded header does not state the additive rule: $(cat "${seed_file}")"
    fi
    rm -f "${seed_file}"
    # Restore the shipped defaults for the next case, which the operator-file load overwrote.
    force_baseline
else
    skip "seeded secret-patterns config" "conf.lib.sh defines no seed function"
fi

# (6) The additive set. The baseline is always in force and an operator's file adds to it, so a file naming one pattern,
# a baseline name among them, classifies every baseline name as well as its own and does not narrow the set to that one
# name. The launch wrapper's journal line, which reports an unreadable file alone, stays silent for every readable
# state. The preceding cases need no fixture on disk; this section is the first here that does, so it creates
# the testdir the harness tears down.
mktestdir
baseline_count="${#_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}"
additive_case() {  # <label> <expected-added-count> <line...> -- load the lines, expect the baseline plus the additions
    local label="$1" want="$2" rc=0 out; shift 2
    printf '%s\n' "$@" > "${TESTDIR}/patterns-additive"
    # shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
    AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-additive"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    ai_tools_secret_patterns__load 2>/dev/null || rc=$?
    if (( rc == 0 )) && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count + want )) \
            && ai_tools_secret_patterns__is_secret_path /home/op/src/api/.env \
            && ai_tools_secret_patterns__is_secret_path /home/op/src/api/server.pem \
            && ! out="$(ai_tools_secret_patterns__format_unreadable_report)" && [[ -z "${out}" ]]; then
        pass "${label}: every baseline name stays a secret beside the file's own, and the journal line is silent"
    else
        fail "${label}: rc=${rc} patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} (want ${baseline_count} + ${want}) report='${out:-}'"
    fi
}
additive_case "a file of comments" 0 '# only comments and blanks' ''
additive_case "a file naming one baseline name" 1 '.env'
additive_case "a file naming one name of its own" 1 'rclone.conf'
if ai_tools_secret_patterns__is_secret_path /home/op/.config/rclone/rclone.conf; then
    pass "an operator's own pattern classifies its name"
else
    fail "an operator's own pattern did not classify rclone.conf"
fi
# shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/no-such-file"
# Loaded in this shell first: the report runs in a `$(...)`, whose load would not reach this shell's set.
ai_tools_secret_patterns__load 2>/dev/null || true
if ! out="$(ai_tools_secret_patterns__format_unreadable_report)" && [[ -z "${out}" ]] \
        && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count )); then
    pass "an absent file loads the baseline alone, and the journal line is silent"
else
    fail "an absent file: patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} report='${out}'"
fi
unset AI_TOOLS_SECRET_PATTERNS_FILE
force_baseline

# (7) The classifier restores the caller's nocasematch setting (it flips it on internally).
shopt -u nocasematch
_ai_tools_secret_patterns__is_secret_basename .env >/dev/null || true
if ! shopt -q nocasematch; then
    pass "classifier restores the caller's nocasematch state"
else
    fail "classifier left nocasematch enabled -- leaks case-insensitive matching to the caller"
fi

# (8) A configured file that is PRESENT and the loader refuses to read is a state of its own, apart from absent
# and readable: the loader returns 1 under its code with the baseline alone loaded, so a caller ignoring the status
# classifies on the baseline and a helper that reads it refuses. The suite is root, which DAC lets read a file of any
# mode; the states a root reader meets are a directory, a dangling symlink and a FIFO, which the `-f` check refuses
# before an open that would block. Absent and readable stay status 0, which is what keeps a fresh enrolment
# walking.
unreadable_case() {  # <label> <path> -- drive the loader at <path>, expect status 1, the code, and the baseline loaded
    local label="$1" path="$2" rc=0 err
    AI_TOOLS_SECRET_PATTERNS_FILE="${path}"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    # Run in this shell, not a `$(...)`: the loader publishes its result in variables a subshell would lose.
    ai_tools_secret_patterns__load 2>"${TESTDIR}/loader-err" >/dev/null || rc=$?
    err="$(cat "${TESTDIR}/loader-err")"
    if (( rc == 1 )) && [[ "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}" == "${path}" ]] \
            && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count )) && _ai_tools_secret_patterns__is_secret_basename .env; then
        pass "${label}: the loader returns 1 with the baseline loaded"
    else
        fail "${label}: rc=${rc} unreadable='${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}' patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} (want 1, the path, ${baseline_count})"
    fi
    assert_msg MSG-S4T9 "${err}" "${label}: the loader names the file under its code"
}
mkdir -p "${TESTDIR}/patterns-dir"
unreadable_case "a directory at the path" "${TESTDIR}/patterns-dir"
ln -s "${TESTDIR}/no-such-target" "${TESTDIR}/patterns-dangling"
unreadable_case "a dangling symlink at the path" "${TESTDIR}/patterns-dangling"
if mkfifo "${TESTDIR}/patterns-fifo" 2>/dev/null; then
    unreadable_case "a FIFO at the path" "${TESTDIR}/patterns-fifo"
else
    skip "a FIFO at the path" "mkfifo failed in ${TESTDIR}"
fi
# The readable states stay status 0: an absent file loads the baseline, a real file the baseline and its own patterns.
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/no-such-file"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
if ai_tools_secret_patterns__load 2>/dev/null && [[ -z "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}" ]] \
        && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count )); then
    pass "an absent file loads the baseline at status 0"
else
    fail "an absent file: rc=$? unreadable='${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}' patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}"
fi
printf 'only-this\n' > "${TESTDIR}/patterns-one"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-one"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
if ai_tools_secret_patterns__load 2>/dev/null \
        && [[ "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}" == "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[*]} only-this" ]]; then
    pass "a readable file loads the baseline and its own patterns at status 0"
else
    fail "a readable file: patterns='${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}' (want the baseline, then only-this)"
fi
# The journal line names an unreadable file, since the baseline then classifies alone for the operator's sessions while
# their helpers refuse.
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-dir"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
if out="$(ai_tools_secret_patterns__format_unreadable_report 2>/dev/null)" && [[ "${out}" == *"cannot be read"* ]] \
        && [[ "${out}" == *"${TESTDIR}/patterns-dir"* ]]; then
    pass "the journal line names an unreadable file at status 0"
else
    fail "the journal line over an unreadable file: '${out}'"
fi
unset AI_TOOLS_SECRET_PATTERNS_FILE

# (9) The path predicate every consumer classifies with. Each exempt path is open where it is the tail of the canonical
# path -- under a project root, a nested client directory and pnpm's layout -- while a lookalike stays locked: a sibling
# name, a case variant, the exempt path as a parent of the path classified, the same last component outside the entry,
# and the bare name elsewhere. An exemption covers the path and not its subtree, so a credential beneath an exempt
# directory is locked by its own name.
section "secret classifier: path exemptions (unit)"
if ! declare -F ai_tools_secret_patterns__is_secret_path >/dev/null 2>&1; then
    skip "secret classifier path exemptions" "the library defines no ai_tools_secret_patterns__is_secret_path"
    finish; exit
fi
exempt_paths=(
    node_modules/@angular/build/private
    node_modules/@angular/material/core/tokens
    node_modules/@angular/material/core/density/private
    node_modules/@schematics/angular/library/files/tsconfig.lib.prod.json.template
    src/environments/environment.development.ts
    src/environments/environment.prod.ts
)
is_open() { ! ai_tools_secret_patterns__is_secret_path "$1"; }
force_baseline
# The control: the last component of each entry is a secret name to the baseline, so an exemption is what opens it.
control_ok=true
for entry in "${exempt_paths[@]}"; do
    _ai_tools_secret_patterns__is_secret_basename "${entry##*/}" \
        || { fail "control: the baseline does not match ${entry##*/}, so the exemption is not what this row tests"; control_ok=false; }
done
${control_ok} && pass "control: the baseline matches the last component of every exempt path by name"
open_ok=true
for entry in "${exempt_paths[@]}"; do
    for path in "/home/op/web/${entry}" "/home/op/api/ClientApp/${entry}" \
                "/home/op/web/node_modules/.pnpm/@angular+build@22.2.6/${entry}"; do
        is_open "${path}" || { fail "an exempt path stays locked: ${path}"; open_ok=false; }
    done
done
${open_ok} && pass "each exempt path is open under a project root, a nested client and pnpm's layout"
# A sibling name is not a secret name either, so it is held to the exemption list itself.
sibling_ok=true
for path in /home/op/web/node_modules/@angular/build/private2 /home/op/web/node_modules/@angular/build/xprivate \
            /home/op/web/xnode_modules/@angular/build/private /home/op/web/node_modules/@angular/build/private/x; do
    if _ai_tools_secret_patterns__is_baseline_exempt_path "${path}"; then
        fail "a sibling of an exempt path matches the exemption list: ${path}"; sibling_ok=false
    fi
done
${sibling_ok} && pass "a sibling name, a longer component and a path below an entry do not match the exemption list"
lookalike_ok=true
for path in /home/op/web/node_modules/@Angular/build/private \
            /home/op/web/node_modules/@angular/build/private/private /home/op/web/core/tokens \
            /home/op/web/node_modules/@angular/material/tokens /home/op/web/src/environments/environment.staging.ts \
            /home/op/web/environments/environment.prod.ts /home/op/private tokens \
            /home/op/web/node_modules/@angular/build/private/.env \
            /home/op/web/node_modules/@angular/material/core/tokens/credentials \
            /home/op/web/node_modules/@angular/material/core/density/private/secrets; do
    if is_open "${path}"; then
        fail "a lookalike of an exempt path, or a secret beneath one, is open: ${path}"; lookalike_ok=false
    fi
done
${lookalike_ok} && pass "lookalikes, case variants and the secrets beneath an exempt directory stay locked"
shopt -s nocasematch
if ai_tools_secret_patterns__is_secret_path /home/op/web/node_modules/@Angular/build/private; then
    pass "the exemption is case-sensitive under a caller's nocasematch"
else
    fail "a case variant of an exempt path is open under the caller's nocasematch"
fi
shopt -u nocasematch

# An operator's file adds to the baseline and leaves its exemptions in force, the same names among its patterns
# included. Driven through the loader, which builds the set in force.
printf 'private\ntokens\n' > "${TESTDIR}/patterns-private"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-private"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
operator_set_ok=true
for entry in node_modules/@angular/build/private node_modules/@angular/material/core/tokens \
             node_modules/@angular/material/core/density/private; do
    is_open "/home/op/web/${entry}" \
        || { fail "an operator's pattern set locked a baseline exemption: ${entry}"; operator_set_ok=false; }
done
is_open /home/op/web/private && { fail "an operator's 'private' pattern left /home/op/web/private open"; operator_set_ok=false; }
${operator_set_ok} && pass "an operator's file holding 'private' and 'tokens' leaves every baseline exemption open"

# A pattern of the operator's own locks a baseline-exempt path it matches, while a baseline entry the file repeats
# in another case leaves its exemption open, an exempt path the pattern does not match stays open, and the operator's
# `!` line still opens the path the pattern locked.
env_prod=/home/op/web/src/environments/environment.prod.ts
printf 'environment.prod.ts\nPRIVATE\n' > "${TESTDIR}/patterns-own"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-own"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
if is_open "${env_prod}"; then
    fail "an operator's own 'environment.prod.ts' pattern left the baseline-exempt ${env_prod} open"
elif ! is_open /home/op/web/node_modules/@angular/build/private; then
    fail "an operator's 'PRIVATE', a baseline entry in another case, locked a baseline exemption"
elif ! is_open /home/op/web/src/environments/environment.development.ts; then
    fail "an operator's 'environment.prod.ts' pattern locked an exempt path it does not match"
else
    pass "an operator's own pattern locks a baseline-exempt path, and a repeated baseline entry does not"
fi
printf 'environment.prod.ts\n!%s\n' "${env_prod}" > "${TESTDIR}/patterns-own-keep"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-own-keep"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
if is_open "${env_prod}"; then
    pass "a '!' line opens the path the operator's own pattern locked"
else
    fail "a '!' line beside the operator's own pattern left ${env_prod} locked"
fi

# (10) Operator `!` lines: an exact canonical absolute path, open whichever set is in force; its sibling, parent, child
# and case variant stay locked. A malformed line is reported under its code by line number, its path stays locked,
# and the loader's status and set are those the rest of the file states.
section "secret classifier: operator exemption lines (unit)"
keep=/home/op/src/api/appsettings.Development.json
printf '# exemptions\n!%s\n' "${keep}" > "${TESTDIR}/patterns-keep"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-keep"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
rc=0; ai_tools_secret_patterns__load 2>"${TESTDIR}/keep-err" || rc=$?
if (( rc == 0 )) && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count )) && [[ ! -s "${TESTDIR}/keep-err" ]] \
        && ! out="$(ai_tools_secret_patterns__format_unreadable_report)" && [[ -z "${out}" ]]; then
    pass "a file of '!' lines and comments loads the baseline at status 0, and the journal line is silent"
else
    fail "a file of '!' lines: rc=${rc} patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} err='$(cat "${TESTDIR}/keep-err")' report='${out:-}'"
fi
bang_case() {  # <label> -- with the file loaded, the named path is open and its neighbours are locked
    local label="$1" path ok=true
    is_open "${keep}" || { fail "${label}: the '!' path stays locked"; ok=false; }
    for path in /home/op/src/api/appsettings.Production.json /home/op/src/web/appsettings.Development.json \
                /home/op/src/api/AppSettings.Development.json "${keep}/secrets" /home/op/src/api/.env; do
        if is_open "${path}"; then fail "${label}: a path the '!' line does not name is open: ${path}"; ok=false; fi
    done
    ${ok} && pass "${label}: the '!' path is open, and a sibling, a case variant, a child and another secret stay locked"
}
bang_case "with the baseline alone"
printf 'appsettings.*.json\nsecrets\n.env\n!%s\n' "${keep}" > "${TESTDIR}/patterns-keep-set"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-keep-set"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
bang_case "with patterns of the operator's own"
# A parent named by a `!` line opens the parent alone.
printf '!/home/op/src/api/private\n' > "${TESTDIR}/patterns-parent"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-parent"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
if is_open /home/op/src/api/private && ! is_open /home/op/src/api/private/.env; then
    pass "a '!' directory is open and a secret inside it stays locked"
else
    fail "a '!' directory: the directory or its .env classified wrongly"
fi
# Each form in this list names /home/op/src/api/x.pem or a set holding it, by a spelling that is not its canonical path.
malformed_lines=( '!src/api/x.pem' '!/home/op/src/api/*.pem' '!/home/op/src/api/x.pe?'
                  '!/home/op/src/api/x.[p]em' '!/home/op/src/../src/api/x.pem' '!/home/op/./src/api/x.pem'
                  '!/home/op//src/api/x.pem' '!/home/op/src/api/x.pem/' '!/' '!' )
printf '%s\n' '*.pem' "${malformed_lines[@]}" > "${TESTDIR}/patterns-malformed"
# shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-malformed"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
rc=0; ai_tools_secret_patterns__load 2>"${TESTDIR}/malformed-err" || rc=$?
err="$(cat "${TESTDIR}/malformed-err")"
assert_msg MSG-T4W8 "${err}" "a malformed '!' line is reported under its code"
reported="$(command grep -c '^MSG-T4W8$' <<< "${err}" || true)"
if (( rc == 0 )) && [[ "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}" == "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[*]} *.pem" ]] \
        && (( reported == ${#malformed_lines[@]} )) && [[ "${err}" == *"line 2 of ${TESTDIR}/patterns-malformed"* ]] \
        && (( ${#_AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS[@]} == 0 )); then
    pass "each malformed '!' form is reported by line and ignored, with the status and the pattern set the file states"
else
    fail "malformed '!' lines: rc=${rc} patterns='${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}' reported=${reported}/${#malformed_lines[@]} exempt=${#_AI_TOOLS_SECRET_PATTERNS__OPERATOR_EXEMPT_PATHS[@]}"
fi
if ! is_open /home/op/src/api/x.pem; then
    pass "the path a malformed line meant stays locked"
else
    fail "a malformed '!' line opened a path"
fi
# A line opening with `!(` is a negation glob an operator's file already holds, and stays a pattern: alone it is the one
# pattern the file adds to the baseline, and beside another pattern it is one of the two.
negation_case() {  # <label> <expected-pattern-count> <line...>
    local label="$1" want="$2" rc=0 err; shift 2
    printf '%s\n' "$@" > "${TESTDIR}/patterns-negation"
    # shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
    AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-negation"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    ai_tools_secret_patterns__load 2>"${TESTDIR}/negation-err" || rc=$?
    err="$(cat "${TESTDIR}/negation-err")"
    if (( rc == 0 )) && [[ -z "${err}" ]] && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == want )) \
            && ! is_open /home/op/src/api/database.conf && is_open /home/op/src/api/public.conf; then
        pass "${label}: a '!(' line loads as a negation pattern, with no line reported"
    else
        fail "${label}: rc=${rc} patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} err='${err}'"
    fi
}
negation_case "alone" "$(( baseline_count + 1 ))" '!(public).conf'
negation_case "beside another pattern" "$(( baseline_count + 2 ))" 'rclone.conf' '!(public).conf'
unset AI_TOOLS_SECRET_PATTERNS_FILE
force_baseline

finish
