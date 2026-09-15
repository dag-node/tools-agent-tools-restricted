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

# usage_paths : the command paths the help lists, one per line indented four spaces -- a bare-word path up to its
# placeholder, or one of the two options answered as commands. A bare collection is normalized to its `list`.
usage_paths() {
    local line path
    while IFS= read -r line; do
        path="$(sed -E 's/^    //; s/  +.*$//; s/ (\[)?[A-Z][A-Z_]*(\])?(\.\.\.)?$//' <<<"${line}")"
        [[ -n "${path}" ]] || continue
        if [[ "${path}" != *' '* ]] && grep -qx -- "${path}" <<<"$(collections)"; then path="${path} list"; fi
        printf '%s\n' "${path}"
    done < <(sed -n '/^usage() {/,/^EOF$/p' "${CLI}" | grep -E '^    ([a-z]|--help|--version).*  ') | sort -u
}

DISPATCH="$(dispatch_paths)"
OPERATOR="$(array_items OPERATOR_VERBS)"
ROOTOK="$(array_items ROOT_ALLOWED_VERBS)"
BOOTEXEMPT="$(array_items BOOTSTRAP_EXEMPT_VERBS)"
FORALLOWED="$(array_items FOR_ALLOWED_VERBS)"

# An empty extraction would make every check pass vacuously, which is the one way a test like this fails silently --
# so the extractor is asserted before anything is compared.
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
# man.sh pins usage() against ai-tools(1); this pins it against the CODE, so the three surfaces agree transitively.
# A verb that works but is documented nowhere is as much a defect as the reverse -- an operator cannot run what they
# cannot find.
missing_help="$(comm -23 <(printf '%s\n' "${DISPATCH}") <(printf '%s\n' "$(usage_paths)"))"
extra_help="$(comm -13 <(printf '%s\n' "${DISPATCH}") <(printf '%s\n' "$(usage_paths)"))"
if [[ -z "${missing_help}" ]]; then
    pass "every dispatched verb appears in the CLI help"
else
    fail "verb(s) the CLI dispatches but the help omits: $(tr '\n' '/' <<<"${missing_help}")"
fi
if [[ -z "${extra_help}" ]]; then
    pass "the CLI help lists no verb the dispatcher rejects"
else
    fail "verb(s) in the help that the dispatcher does not accept: $(tr '\n' '/' <<<"${extra_help}")"
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
    while read -r key; do
        grep -qE -- "(^|[^[:alnum:]-])${key}([^[:alnum:]-]|$)" <<<"$(sed -n '/^usage() {/,/^EOF$/p' "${CLI}")" \
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

finish
