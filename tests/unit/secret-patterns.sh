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
    _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE=1
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
# at enrolment, before the operator has decided anything, so what it writes must parse to an empty set and leave
# the built-in baseline in force -- a seed that parsed to even one pattern would REPLACE the baseline and silently stop
# quarantining every name it dropped.
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
    # The one claim the seeded header must always carry, asserted by the grep that follows it: an operator's pattern
    # REPLACES the baseline rather than adding to it, so a file holding one name classifies on that name alone.
    if grep -qi 'REPLACES the built-in baseline' "${seed_file}"; then
        pass "the seeded header states that a pattern replaces the baseline"
    else
        fail "the seeded header does not state the replace rule: $(cat "${seed_file}")"
    fi
    rm -f "${seed_file}"
    # Restore the shipped defaults for the next case, which the operator-file load overwrote.
    force_baseline
else
    skip "seeded secret-patterns config" "conf.lib.sh defines no seed function"
fi

# (6) The drift report, which the launch wrapper logs once per session. What it exists to catch is a file written once
# and never re-read: because an operator's set REPLACES the baseline, such a file keeps this host on the patterns it
# listed then and drops every one added upstream since. So the assertions are about the two silent directions -- no file
# and an empty file must read as agreement (the baseline is in force, and a host that has decided nothing should not be
# nagged), while a real file must name what it DROPS, that being the half that stops quarantining anything.
if declare -F ai_tools_secret_patterns__format_drift >/dev/null 2>&1; then
    # The preceding cases need no fixture on disk; this section is the first here that does, so it creates the testdir
    # the harness tears down.
    mktestdir
    _drift_file="${TESTDIR}/drift-patterns"

    # shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
    AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/no-such-file"
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    if ! out="$(ai_tools_secret_patterns__format_drift)" && [[ -z "${out}" ]]; then
        pass "a missing config reports no drift (the baseline is what is in force)"
    else
        fail "a missing config reported drift: ${out}"
    fi

    printf '# only comments and blanks\n\n' > "${_drift_file}"
    # shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
    AI_TOOLS_SECRET_PATTERNS_FILE="${_drift_file}"
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    if ! out="$(ai_tools_secret_patterns__format_drift)" && [[ -z "${out}" ]]; then
        pass "a config that parses empty reports no drift (the loader fell back to the baseline)"
    else
        fail "an empty config reported drift: ${out}"
    fi

    # A copy of the baseline, reordered and with one line repeated: the same SET, so no pattern is added or dropped,
    # and the report names the one difference it makes -- a file with patterns replaces the baseline's path exemptions,
    # which leaves the paths they kept open locked.
    printf '%s\n' "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}" | LC_ALL=C sort -r > "${_drift_file}"
    printf '%s\n' "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[0]}" >> "${_drift_file}"
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    if out="$(ai_tools_secret_patterns__format_drift)" && [[ "${out}" == *"${_drift_file}"*"path exemptions"* ]] \
            && [[ "${out}" != *adds* && "${out}" != *drops* ]]; then
        pass "a reordered, duplicated copy of the baseline reports the path exemptions it replaces, and no pattern drift"
    else
        fail "a set-identical config: the report did not name the replaced path exemptions alone: '${out}'"
    fi

    # The real case, driven as ONE pattern in and one out, so both lists are named in full and the assertion does not
    # depend on where a name falls against the cap. The dropped half is the one an operator acts on: that pattern is
    # a credential name this host stopped quarantining.
    printf '%s\n' "${_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}" | grep -vxF '*.pem' > "${_drift_file}"
    printf '*.asc\n' >> "${_drift_file}"
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    out="$(ai_tools_secret_patterns__format_drift)" || true
    if [[ "${out}" == *"${_drift_file}"* ]] \
       && [[ "${out}" == *"adds 1 (*.asc)"* ]] \
       && [[ "${out}" == *"drops 1 (*.pem)"* ]]; then
        pass "a config that differs by one pattern names the file, the addition, and the drop"
    else
        fail "the drift report did not name the file, the addition, or the dropped pattern: ${out}"
    fi

    # A wide difference stays ONE line: the report is read at a glance in the journal, and the file itself is
    # where the whole set is read. Driven with a config that keeps two patterns, so the dropped list runs well past
    # the cap.
    printf '.env\n*.asc\n' > "${_drift_file}"
    _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    out="$(ai_tools_secret_patterns__format_drift)" || true
    if [[ "$(printf '%s' "${out}" | wc -l)" -eq 0 ]] && [[ "${out}" == *"more)"* ]]; then
        pass "the report stays one line, capping the list it prints"
    else
        fail "the drift report is not a single capped line: ${out}"
    fi

    rm -f "${_drift_file}"
    unset AI_TOOLS_SECRET_PATTERNS_FILE
    force_baseline
else
    skip "secret-pattern drift report" "the library defines no ai_tools_secret_patterns__format_drift"
fi

# (7) The classifier restores the caller's nocasematch setting (it flips it on internally).
shopt -u nocasematch
_ai_tools_secret_patterns__is_secret_basename .env >/dev/null || true
if ! shopt -q nocasematch; then
    pass "classifier restores the caller's nocasematch state"
else
    fail "classifier left nocasematch enabled -- leaks case-insensitive matching to the caller"
fi

# (8) A configured file that is PRESENT and the loader refuses to read is a third state, apart from absent and empty:
# the loader returns 1 under its code with the baseline loaded, so a caller ignoring the status classifies
# on the baseline (never an empty set) and a helper that reads it refuses. The suite is root, which DAC lets read a file
# of any mode; the states a root reader meets are a directory, a dangling symlink and a FIFO, which the `-f` check
# refuses before an open that would block. Absent and empty stay status 0, which is what keeps a fresh enrolment
# walking.
[[ -n "${TESTDIR:-}" ]] || mktestdir
baseline_count="${#_AI_TOOLS_SECRET_PATTERNS__DEFAULTS[@]}"
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
# The two readable states stay status 0: absent and empty load the baseline, a real file loads its own patterns.
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/no-such-file"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
if ai_tools_secret_patterns__load 2>/dev/null && [[ -z "${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}" ]] \
        && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count )); then
    pass "an absent file loads the baseline at status 0"
else
    fail "an absent file: rc=$? unreadable='${AI_TOOLS_SECRET_PATTERNS__UNREADABLE}' patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]}"
fi
printf 'only-this\n' > "${TESTDIR}/patterns-one"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-one"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
if ai_tools_secret_patterns__load 2>/dev/null && [[ "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}" == only-this ]]; then
    pass "a readable file loads its own patterns at status 0"
else
    fail "a readable file: patterns='${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}' (want only-this)"
fi
# The drift report names an unreadable file, since the baseline is then in force for the operator's sessions while their
# helpers refuse -- the one state the wrapper's journal line would otherwise read as silent agreement.
if declare -F ai_tools_secret_patterns__format_drift >/dev/null 2>&1; then
    AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-dir"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    if out="$(ai_tools_secret_patterns__format_drift 2>/dev/null)" && [[ "${out}" == *"cannot be read"* ]]; then
        pass "the drift report names an unreadable file at status 0"
    else
        fail "the drift report over an unreadable file: '${out}'"
    fi
fi
unset AI_TOOLS_SECRET_PATTERNS_FILE

# (9) The path predicate every consumer classifies with. With the baseline in force, each exempt path is open where it
# is the tail of the canonical path -- under a project root, a nested client directory and pnpm's layout -- while
# a lookalike stays locked: a sibling name, a case variant, the exempt path as a parent of the path classified, the same
# last component outside the entry, and the bare name elsewhere. An exemption covers the path and not its subtree,
# so a credential beneath an exempt directory is locked by its own name.
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
        is_open "${path}" || { fail "an exempt path stays locked with the baseline in force: ${path}"; open_ok=false; }
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

# An operator's file with a pattern replaces the baseline and its exemptions with it. Driven through the loader,
# which is what records the set in force.
printf 'private\ntokens\n' > "${TESTDIR}/patterns-private"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-private"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
operator_set_ok=true
for entry in node_modules/@angular/build/private node_modules/@angular/material/core/tokens \
             node_modules/@angular/material/core/density/private; do
    if is_open "/home/op/web/${entry}"; then
        fail "an operator's pattern set left a baseline exemption open: ${entry}"; operator_set_ok=false
    fi
done
${operator_set_ok} && pass "an operator's file holding 'private' and 'tokens' keeps every baseline exemption locked"

# (10) Operator `!` lines: an exact canonical absolute path, open whichever set is in force; its sibling, parent, child
# and case variant stay locked. A malformed line is reported under its code by line number, its path stays locked,
# and the loader's status and set are those the rest of the file states.
section "secret classifier: operator exemption lines (unit)"
keep=/home/op/src/api/appsettings.Development.json
printf '# exemptions\n!%s\n' "${keep}" > "${TESTDIR}/patterns-keep"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-keep"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
rc=0; ai_tools_secret_patterns__load 2>"${TESTDIR}/keep-err" || rc=$?
if (( rc == 0 )) && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == baseline_count )) && [[ ! -s "${TESTDIR}/keep-err" ]] \
        && ! out="$(ai_tools_secret_patterns__format_drift)" && [[ -z "${out}" ]]; then
    pass "a file of '!' lines and comments loads the baseline at status 0, and the drift report is silent"
else
    fail "a file of '!' lines: rc=${rc} patterns=${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} err='$(cat "${TESTDIR}/keep-err")' drift='${out:-}'"
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
bang_case "with the baseline in force"
printf 'appsettings.*.json\nsecrets\n.env\n!%s\n' "${keep}" > "${TESTDIR}/patterns-keep-set"
AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-keep-set"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
ai_tools_secret_patterns__load 2>/dev/null || true
bang_case "with an operator pattern set"
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
if (( rc == 0 )) && [[ "${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}" == '*.pem' ]] \
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
# A line opening with `!(` is a negation glob an operator's file already holds, and stays a pattern: alone it is
# the whole set in force, and beside another pattern it is one of the two.
negation_case() {  # <label> <expected-pattern-count> <line...>
    local label="$1" want="$2" rc=0 err; shift 2
    printf '%s\n' "$@" > "${TESTDIR}/patterns-negation"
    # shellcheck disable=SC2034  # read by ai_tools_secret_patterns__load in the sourced library
    AI_TOOLS_SECRET_PATTERNS_FILE="${TESTDIR}/patterns-negation"; _AI_TOOLS_SECRET_PATTERNS__PATTERNS_LOADED=""
    ai_tools_secret_patterns__load 2>"${TESTDIR}/negation-err" || rc=$?
    err="$(cat "${TESTDIR}/negation-err")"
    if (( rc == 0 )) && [[ -z "${err}" ]] && (( ${#AI_TOOLS_SECRET_PATTERNS__PATTERNS[@]} == want )) \
            && (( _AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE == 0 )) \
            && ! is_open /home/op/src/api/database.conf && is_open /home/op/src/api/public.conf; then
        pass "${label}: a '!(' line loads as a negation pattern, with no line reported"
    else
        fail "${label}: rc=${rc} patterns='${AI_TOOLS_SECRET_PATTERNS__PATTERNS[*]}' baseline=${_AI_TOOLS_SECRET_PATTERNS__BASELINE_IN_FORCE} err='${err}'"
    fi
}
negation_case "alone" 1 '!(public).conf'
negation_case "beside another pattern" 2 '*.pem' '!(public).conf'
unset AI_TOOLS_SECRET_PATTERNS_FILE
force_baseline

finish
