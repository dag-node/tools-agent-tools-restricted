#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/cli-verbs.sh
# Hermetic check that the ai-tools CLI's four GATING TABLES still describe the commands it dispatches. Each table is
# a named array of command paths read before dispatch, and each decides something a caller can be let
# through by mistake:
#   OPERATOR_VERBS         who may run it   -- an unenrolled caller is refused
#   ROOT_ALLOWED_VERBS     may root run it  -- the carve-out for verbs that write no operator state
#   BOOTSTRAP_EXEMPT_VERBS may it run on an unprovisioned host
#   FOR_ALLOWED_VERBS      does `--for` apply -- elsewhere the flag is refused, not ignored
#
# The failure this exists for is silent and one-directional: a verb ADDED to the dispatcher and forgotten
# in OPERATOR_VERBS is one an unenrolled user runs, and no runtime message says so -- the verb simply works, until
# a root helper refuses it midway. The reverse (a table naming a verb the dispatcher no longer has) is dead
# configuration that reads as coverage. So membership is asserted in both directions, and every dispatched verb must be
# classified one way or the other: the INFORMATIONAL set is the second half of that contract, and adding a verb means
# naming it in one of the two.
#
# A command path is the string the CLI's verb_in reads: the collection and its verb (`projects claim`), one bare word
# for a host command (`status`), or one of the two options answered as commands (`--help`, `--version`). The dispatch
# nests one `case` per collection, so a path is read as the top-level arm joined to the arm of that collection's
# dispatch function, and a bare collection in the help is its `list`, the CLI's own rule.
#
# Pure text comparison of the CLI source -- no root, no install dependency, no CLI execution (its bootstrap gate
# fail-closes on an unprovisioned host). Validates the repo source, falling back to the installed copy outside
# a checkout, exactly like man.sh.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT}/src/usr/local/bin/ai-tools.sh"
[[ -r "${CLI}" ]] || CLI="/usr/local/bin/ai-tools"
section "cli: the verb-gating tables match the dispatcher (unit)"

if [[ ! -r "${CLI}" ]]; then
    skip "cli verb gating" "CLI not found in src/ or the install path"
    finish; exit
fi

# INFORMATIONAL -- the verbs deliberately open to any caller: they read, or (in `stop`'s case) act through a helper
# that requires root anyway and does not take operator-owned state. This list is the test's half of the contract,
# so a verb added to neither this nor OPERATOR_VERBS fails with the choice spelled out.
readonly INFORMATIONAL=(--help --version "projects list" "providers list" status audit stop)
# INTERNAL -- the dispatched verbs that are the CLI's own calling contract: another verb runs each one and parses
# what it prints, so the help, the man page and the completion leave it out. A verb qualifies when no person is meant
# to type it; the gating tables still classify it like every other.
readonly INTERNAL=("projects inspect")

# array_items <NAME> : the elements of a `readonly NAME=(...)` declaration, one per line. An element is a quoted command
# path or a bare word; the declarations span lines, so the extraction runs from the name to the closing paren.
array_items() {
    awk -v name="readonly $1=(" '
        index($0, name)==1 { inside=1; sub(/^[^(]*\(/, "") }
        inside {
            line=$0
            if (index(line, ")")) { sub(/\).*$/, "", line); inside=0; done=1 }
            while (match(line, /"[^"]*"|[^" \t]+/)) {
                item=substr(line, RSTART, RLENGTH); gsub(/"/, "", item); print item
                line=substr(line, RSTART+RLENGTH)
            }
            if (done) exit
        }' "${CLI}" | sort -u
}

# dispatch_paths : every command path the dispatch accepts. A top-level arm whose body calls a `<noun>_dispatch`
# function contributes one path per arm of that function; any other arm is a path of one token.
dispatch_paths() {
    awk '
        /^[a-z_]+_dispatch\(\) \{/ { fn=$1; sub(/\(\).*/, "", fn); infn=fn; next }
        infn && /^}/ { infn=""; next }
        infn && match($0, /^[ \t]*[a-z][a-z-]*\)/) {
            verb=$0; sub(/^[ \t]*/, "", verb); sub(/\).*/, "", verb); verbs[infn]=verbs[infn] " " verb; next }
        /^# ── Dispatch/ { top=1; next }
        top && /^esac/ { exit }
        top && match($0, /^[ \t]*[^)#* \t][^)#]*\)/) {
            arms=$0; sub(/^[ \t]*/, "", arms); sub(/\).*/, "", arms)
            body=$0; sub(/^[^)]*\)/, "", body)
            n=split(arms, alts, "|")
            for (i=1; i<=n; i++) {
                alt=alts[i]; gsub(/"/, "", alt)
                if (match(body, /[a-z_]+_dispatch/)) {
                    fn=substr(body, RSTART, RLENGTH); m=split(verbs[fn], vs, " ")
                    for (j=1; j<=m; j++) if (vs[j] != "") print alt " " vs[j]
                } else print alt
            }
        }' "${CLI}" | sort -u
}

# collections : the plural nouns whose bare form is a `list`, from the CLI's own COLLECTIONS table.
collections() { array_items COLLECTIONS; }

# HELP_LIB: the library holding the CLI's command rows, the checkout's beside the CLI (the installed one outside
# a checkout), read in a shell of its own so its readonly rows stay out of this one.
HELP_LIB="${ROOT}/src/usr/local/lib/ai-tools/help.lib.sh"
[[ -r "${HELP_LIB}" ]] || HELP_LIB="/usr/local/lib/ai-tools/help.lib.sh"
help_list() { bash -c 'source "$1" && "$2" ai-tools' _ "${HELP_LIB}" "$1"; }

# usage_paths : the command paths the help rows hold, a `[list]` row as its `list` path, and the two options answered
# as commands, the option rows that take no argument.
usage_paths() {
    local path argument
    {
        while IFS=$'\t' read -r path argument _; do
            if [[ "${argument}" == "[list]" ]]; then path="${path} list"; fi
            printf '%s\n' "${path}"
        done < <(help_list ai_tools_help__list_commands)
        help_list ai_tools_help__list_options | awk -F '\t' '$2 == "-" {print $1}'
    } | sort -u
}
# for_paths : the command paths whose help row carries the `for` flag, a `[list]` row as its `list` path.
for_paths() {
    local path argument flags
    while IFS=$'\t' read -r path argument _ flags; do
        [[ " ${flags} " == *" for "* ]] || continue
        if [[ "${argument}" == "[list]" ]]; then path="${path} list"; fi
        printf '%s\n' "${path}"
    done < <(help_list ai_tools_help__list_commands) | sort -u
}

# `--help` is answered by the help resolution ahead of the dispatch, which therefore has no arm for it.
DISPATCH="$( { dispatch_paths; printf -- '--help\n'; } | sort -u)"
OPERATOR="$(array_items OPERATOR_VERBS)"
ROOTOK="$(array_items ROOT_ALLOWED_VERBS)"
BOOTEXEMPT="$(array_items BOOTSTRAP_EXEMPT_VERBS)"
FORALLOWED="$(array_items FOR_ALLOWED_VERBS)"

# An empty extraction would let every check pass without comparing a verb, which is the one way a test like this fails
# silently, so the extractor is asserted before anything is compared.
if [[ -z "${DISPATCH}" || -z "${OPERATOR}" || -z "${ROOTOK}" || -z "${BOOTEXEMPT}" || -z "${FORALLOWED}" ]]; then
    fail "could not extract a verb set (dispatch=$(wc -l <<<"${DISPATCH}") operator=$(wc -l <<<"${OPERATOR}") root=$(wc -l <<<"${ROOTOK}") bootstrap=$(wc -l <<<"${BOOTEXEMPT}") for=$(wc -l <<<"${FORALLOWED}"))"
    finish; exit
fi
pass "extracted the dispatcher ($(wc -l <<<"${DISPATCH}") command paths) and all four gating tables"

# ── (1) Every dispatched verb is classified ─────────────────────────────────────
# The check with teeth: a new mutating verb that nobody added to OPERATOR_VERBS runs for an unenrolled caller,
# and the first thing to notice would be a root helper refusing it partway.
unclassified="$(comm -23 <(printf '%s\n' "${DISPATCH}") \
                         <(printf '%s\n' "${OPERATOR}" "$(printf '%s\n' "${INFORMATIONAL[@]}")" | sort -u))"
if [[ -z "${unclassified}" ]]; then
    pass "every dispatched verb is either operator-gated or informational"
else
    fail "verb(s) in the dispatcher that no gate classifies: $(tr '\n' '/' <<<"${unclassified}") -- add each to OPERATOR_VERBS (it acts as an operator) or to INFORMATIONAL in this test (it only reports)"
fi

# ── (2) The two classifications do not overlap ──────────────────────────────────
# Root is refused every operator-acting verb, because a registry written by root names an owner whose own launch gate
# cannot read it. A verb in both tables would be a contradiction the principal guard resolves silently, in whichever
# order it happens to test them.
overlap="$(comm -12 <(printf '%s\n' "${OPERATOR}") <(printf '%s\n' "${ROOTOK}"))"
if [[ -z "${overlap}" ]]; then
    pass "no verb is both operator-acting and root-allowed"
else
    fail "verb(s) in OPERATOR_VERBS and ROOT_ALLOWED_VERBS at once: $(tr '\n' '/' <<<"${overlap}")"
fi

# ── (2b) `admin` is not a command of the CLI ────────────────────────────────────
# The short command `atr` reads `admin` as its first word and runs ai-tools-admin for it, so an `admin` verb here would
# be unreachable through `atr` (cli-grammar.rule.md, The `/admin` namespace).
if grep -qE '^admin( |$)' <<<"${DISPATCH}"; then
    fail "the CLI dispatches an admin command, which atr admin shadows: $(grep -E '^admin( |$)' <<<"${DISPATCH}" | tr '\n' '/')"
else
    pass "the CLI dispatches no admin command, the first word atr reserves"
fi

# ── (3) No table names a verb the dispatcher does not have ──────────────────────
# A stale entry is dead configuration that reads as coverage -- worst for ROOT_ALLOWED_VERBS and BOOTSTRAP_EXEMPT_VERBS,
# whose whole content is exceptions.
for table in OPERATOR_VERBS ROOT_ALLOWED_VERBS BOOTSTRAP_EXEMPT_VERBS FOR_ALLOWED_VERBS; do
    case "${table}" in
        OPERATOR_VERBS)         items="${OPERATOR}" ;;
        ROOT_ALLOWED_VERBS)     items="${ROOTOK}" ;;
        BOOTSTRAP_EXEMPT_VERBS) items="${BOOTEXEMPT}" ;;
        *)                      items="${FORALLOWED}" ;;
    esac
    stale="$(comm -23 <(printf '%s\n' "${items}") <(printf '%s\n' "${DISPATCH}"))"
    if [[ -z "${stale}" ]]; then
        pass "${table} names only verbs the dispatcher accepts"
    else
        fail "${table} names verb(s) the CLI no longer dispatches: $(tr '\n' '/' <<<"${stale}")"
    fi
done

# ── (4) The help lists exactly the verbs the CLI dispatches ─────────────────────
# man.sh pins the help rows against ai-tools(1); this pins them against the CODE, so the three surfaces agree
# transitively. A verb that works but is documented nowhere is as much a defect as the reverse -- an operator cannot run
# what they cannot find.
# An INTERNAL verb is the one dispatched path the help leaves out, so it is held to that from both sides: it is
# dispatched, and the help does not list it.
PUBLIC_DISPATCH="$(comm -23 <(printf '%s\n' "${DISPATCH}") <(printf '%s\n' "${INTERNAL[@]}" | sort -u))"
missing_help="$(comm -23 <(printf '%s\n' "${PUBLIC_DISPATCH}") <(printf '%s\n' "$(usage_paths)"))"
extra_help="$(comm -13 <(printf '%s\n' "${PUBLIC_DISPATCH}") <(printf '%s\n' "$(usage_paths)"))"
if [[ -z "${missing_help}" ]]; then
    pass "every dispatched verb but the internal ones appears in the CLI help"
else
    fail "verb(s) the CLI dispatches but the help omits: $(tr '\n' '/' <<<"${missing_help}")"
fi
for internal in "${INTERNAL[@]}"; do
    if ! grep -qxF -- "${internal}" <<<"${DISPATCH}"; then
        fail "INTERNAL names '${internal}', which the CLI does not dispatch"
    elif grep -qxF -- "${internal}" <<<"$(usage_paths)"; then
        fail "the internal verb '${internal}' is listed in the CLI help"
    else
        pass "the internal verb '${internal}' is dispatched and left out of the help"
    fi
done
if [[ -z "${extra_help}" ]]; then
    pass "the CLI help lists no verb the dispatcher rejects"
else
    fail "verb(s) in the help that the dispatcher does not accept: $(tr '\n' '/' <<<"${extra_help}")"
fi

# ── (3b) Every `--for` verb loads the target's registry itself ────────────────────
# A `--for` run reads the target's registry once the verb has checked its own command line, through
# load_target_registry_snapshot, so a refusal of that line precedes the password prompt. A verb that forgot the call
# would read every path as unregistered -- the less-access answer for each verb but the claim -- so each function
# the dispatch maps a FOR_ALLOWED_VERBS path to is read for the call. The control is a dispatched function that does
# not take `--for`, which the reader must report as not calling it.
dispatch_function() {  # dispatch_function <verb>: the function projects_dispatch runs for `projects <verb>`
    awk -v verb="$1" '
        /^projects_dispatch\(\) \{/ { on=1; next }
        on && /^}/ { exit }
        on && $0 ~ "^[ \t]*" verb "\\)" { sub(/^[^)]*\)[ \t]*/, ""); split($0, words, /[ \t]+/); print words[1]; exit }
    ' "${CLI}"
}
calls_loader() {  # calls_loader <function>: the function's body in the CLI source calls load_target_registry_snapshot
    # The body is captured before it is matched: `grep -q` exits on the match, and the writer it leaves would die of
    # SIGPIPE, which pipefail reports as a failure.
    local body
    body="$(awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" { on=1; next } on && /^}/ { exit } on' "${CLI}" | sed 's/#.*//')"
    grep -qw load_target_registry_snapshot <<< "${body}"
}
loader_missing=""
loader_checked=0
while IFS= read -r for_path; do
    [[ "${for_path}" == "projects "* ]] || continue
    fn="$(dispatch_function "${for_path#projects }")"
    if [[ -z "${fn}" ]]; then loader_missing+=" ${for_path}(no dispatch arm)"; continue; fi
    loader_checked=$(( loader_checked + 1 ))
    calls_loader "${fn}" || loader_missing+=" ${fn}"
done <<< "${FORALLOWED}"
control_fn="$(dispatch_function clone)"
if [[ -z "${control_fn}" ]] || calls_loader "${control_fn}"; then
    fail "control: the reader did not find projects clone's function, or read it as calling the loader (${control_fn:-none})"
elif (( loader_checked == 0 )); then
    fail "no FOR_ALLOWED_VERBS function was read -- the reader stopped matching"
elif [[ -n "${loader_missing}" ]]; then
    fail "--for verb function(s) that do not call load_target_registry_snapshot:${loader_missing}"
else
    pass "each of the ${loader_checked} --for verb functions calls load_target_registry_snapshot, and ${control_fn} does not"
fi

# ── (4b) The help's `for` flag names the verbs FOR_ALLOWED_VERBS names ──────────
# The flag decides which hints carry `[--for OPERATOR]`, and FOR_ALLOWED_VERBS decides what the flag does; the two are
# one set, held equal here so the flag does not become a second home for that table.
for_mismatch="$(comm -3 <(for_paths) <(printf '%s\n' "${FORALLOWED}"))"
if [[ -n "$(for_paths)" && -z "${for_mismatch}" ]]; then
    pass "the help rows carrying the for flag are FOR_ALLOWED_VERBS"
else
    fail "the help's for flag and FOR_ALLOWED_VERBS differ: $(tr '\n\t' '/ ' <<<"${for_mismatch:-no for-flagged row read}")"
fi

# ── (5) The CLI describes itself on a host that is not provisioned yet ──────────
# `--help` and `--version` read no installed state, and the provisioning gate's own refusal names the command to run
# next -- which a caller who cannot print the usage has no way to look up. Gating them fails on the one host nobody
# develops against, so the membership is pinned here rather than left to the gate, which is a single line far
# from the table it reads.
readonly SELF_DESCRIBING=(--help --version)
ungated="$(comm -23 <(printf '%s\n' "${SELF_DESCRIBING[@]}" | sort -u) <(printf '%s\n' "${BOOTEXEMPT}"))"
if [[ -z "${ungated}" ]]; then
    pass "--help and --version run on an unprovisioned host"
else
    fail "verb(s) that describe the CLI but sit behind the provisioning gate: $(tr '\n' ' ' <<<"${ungated}") -- add each to BOOTSTRAP_EXEMPT_VERBS"
fi

# ── (6) The option spellings map onto the dispatcher, and only onto it ──────────
# OPTION_SPELLINGS is data the CLI rewrites ahead of every gate, so no other reader in this file meets a key: no arm
# dispatches one and the help does not list one, which is asserted from the other side here, since a key that is also
# an arm or a help line is a command with two live spellings that the rewrite answers first. What goes stale
# on the value side is worse: a value naming a path the dispatcher no longer has turns a spelling that ran
# into a refused command. tools/generators/option-spellings.sh reads the table for the page it generates, so the rows
# are read through it here too and the committed page is held to the table. The tool is a checkout's,
# so an installed-only run
# skips.
GEN="${ROOT}/tools/generators/option-spellings.sh"
check_option_spellings() {
    if [[ ! -r "${GEN}" ]]; then
        skip "option spellings" "not a checkout (no ${GEN})"; return
    fi
    local rows keys values accepted stale collide listed key out rc=0
    rows="$(bash "${GEN}" rows 2>/dev/null)" || rows=""
    if [[ -z "${rows}" ]]; then
        fail "could not extract OPTION_SPELLINGS from the CLI source"; return
    fi
    keys="$(cut -f1 <<<"${rows}" | sort -u)"
    values="$(cut -f2 <<<"${rows}" | sort -u)"
    # A value is a dispatched command path, or a long option some CLI parser accepts (`--group`, which `-g` stands
    # for); the option read is man.sh's, an option token in a case-arm position.
    accepted="$( { printf '%s\n' "${DISPATCH}"; grep -oE -- '--[a-z][a-z-]+[)|=]' "${CLI}" | sed 's/.$//'; } | sort -u)"
    stale="$(comm -23 <(printf '%s\n' "${values}") <(printf '%s\n' "${accepted}"))"
    if [[ -z "${stale}" ]]; then
        pass "every option spelling maps onto a dispatched command or a parsed option ($(wc -l <<<"${rows}") rows)"
    else
        fail "OPTION_SPELLINGS value(s) the CLI neither dispatches nor parses: $(tr '\n' '/' <<<"${stale}")"
    fi
    collide="$(comm -12 <(printf '%s\n' "${keys}") <(printf '%s\n' "${DISPATCH}"))"
    if [[ -z "${collide}" ]]; then
        pass "no option spelling is also a dispatched command"
    else
        fail "OPTION_SPELLINGS key(s) the dispatcher also accepts, so the rewrite answers first: $(tr '\n' '/' <<<"${collide}")"
    fi
    listed=""
    help_text="$(bash -c 'source "$1" && ai_tools_help__render ai-tools' _ "${HELP_LIB}")"
    while read -r key; do
        grep -qE -- "(^|[^[:alnum:]-])${key}([^[:alnum:]-]|$)" <<<"${help_text}" \
            && listed="${listed}${key} "
    done <<<"${keys}"
    if [[ -z "${listed}" ]]; then
        pass "the CLI help lists no option spelling"
    else
        fail "option spelling(s) the CLI help lists beside the command form: ${listed}"
    fi
    out="$(bash "${GEN}" stale 2>&1)" || rc=$?
    if (( rc == 0 )); then
        pass "docs/option-spellings.md is what the table generates"
    else
        fail "docs/option-spellings.md is stale:"$'\n'"${out}"
    fi
}
check_option_spellings

# ── Every key the suite names resolves through the spelling table ──────────────────────────────
# A test names a command by a key that tests/lib/cli-spelling.sh turns into today's tokens (tests.rule.md). A key
# the table no longer holds is caught at RUN time by cli_cmd's own refusal, which is the root suite on a deployed
# install -- and a row whose assertion reads only the call log passes anyway, because a command that never started
# leaves the same empty log. So the resolution is checked here instead: pure text, no root, no install, one second.
#
# What it reads is the first literal token after each function that takes a key. It must NOT filter to tokens already
# shaped like a key: a key that lost its namespace is precisely the defect, so a token is collected on the call shape
# alone and then resolved. Quoted spans go first and comments after them, which drops both a token the shell expands
# (only a literal is checkable) and a driver's name inside a message, in that order so a `#` inside a string is not read
# as opening a comment.
check_spelling_keys() {
    local lib="${ROOT}/tests/lib/cli-spelling.sh"
    if [[ ! -r "${lib}" ]]; then
        skip "spelling keys resolve" "no ${lib}"; return
    fi
    # shellcheck source=../lib/cli-spelling.sh
    source "${lib}"
    local drivers='cli|cli_in|cli_flag_first|cli_for_first|cli_cmd|cli_cmd_text|cli_cmd_option|spell|pd_cli|run_for'
    local -a keys
    mapfile -t keys < <(sed -E 's/"[^"]*"//g; s/'\''[^'\'']*'\''//g; s/#.*//' "${ROOT}"/tests/*/*.sh \
                        | grep -hoE "\b(${drivers})[[:space:]]+[A-Za-z][A-Za-z0-9.-]*" \
                        | sed -E "s/^(${drivers})[[:space:]]+//" \
                        | grep -vxE "${drivers}" | sort -u)
    if (( ${#keys[@]} == 0 )); then
        fail "no command key found in the suite -- the reader stopped matching"; return
    fi
    local key unresolved=""
    for key in "${keys[@]}"; do
        cli_cmd "${key}" >/dev/null 2>&1 || unresolved+=" ${key}"
    done
    if [[ -n "${unresolved}" ]]; then
        fail "command key(s) the suite names that tests/lib/cli-spelling.sh does not hold:${unresolved}"
    else
        pass "every command key the suite names resolves (${#keys[@]} keys)"
    fi
}
check_spelling_keys

finish
