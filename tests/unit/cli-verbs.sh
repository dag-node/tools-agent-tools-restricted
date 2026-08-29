#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/cli-verbs.sh
# Hermetic check that the ai-tools CLI's four GATING TABLES still describe the verbs it dispatches.
# Each table is a named array read before dispatch, and each decides something a caller can be let
# through by mistake:
#   OPERATOR_VERBS         who may run it   -- an unenrolled caller is refused
#   ROOT_ALLOWED_VERBS     may root run it  -- the carve-out for verbs that write no operator state
#   BOOTSTRAP_EXEMPT_VERBS may it run on an unprovisioned host
#   FOR_ALLOWED_VERBS      does --for apply -- elsewhere the flag is refused, not ignored
#
# The failure this exists for is silent and one-directional: a verb ADDED to the dispatcher and
# forgotten in OPERATOR_VERBS is one an unenrolled user runs, and nothing at runtime says so --
# the verb simply works, until a root helper refuses it midway. The reverse (a table naming a verb
# the dispatcher no longer has) is dead configuration that reads as coverage. So membership is
# asserted in both directions, and every dispatched verb must be classified one way or the other:
# the INFORMATIONAL set below is the second half of that contract, and adding a verb means naming
# it in one of the two.
#
# Pure text comparison of the CLI source -- no root, no install dependency, no CLI execution (its
# bootstrap gate fail-closes on an unprovisioned host). Validates the repo source, falling back to
# the installed copy outside a checkout, exactly like man.sh.
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

# INFORMATIONAL -- the verbs deliberately open to any caller: they read, or (in --stop's case) act
# through a helper that requires root anyway and takes no operator-owned state. This list is the
# test's half of the contract, so a verb added to neither this nor OPERATOR_VERBS fails below with
# the choice spelled out.
readonly INFORMATIONAL=(--help --version --list --providers --status --audit --stop)

# array_items <NAME> : the elements of a `readonly NAME=(...)` declaration, one per line. The
# declarations span lines, so the extraction runs from the name to the closing paren.
array_items() {
    awk -v name="readonly $1=(" '
        index($0, name)==1 { inside=1; sub(/^[^(]*\(/, "") }
        inside {
            line=$0
            if (index(line, ")")) { sub(/\).*$/, "", line); inside=0; done=1 }
            n=split(line, w, /[[:space:]]+/)
            for (i=1; i<=n; i++) if (w[i] ~ /^--/) print w[i]
            if (done) exit
        }' "${CLI}" | sort -u
}

# dispatch_verbs : every long option the final dispatch case accepts.
dispatch_verbs() {
    awk '/^# ── Dispatch/{d=1} d && /^esac/{exit} d' "${CLI}" \
        | grep -oE '^[[:space:]]+--[a-z-]+' | tr -d ' ' | sort -u
}

# usage_verbs : the verb lines of the help heredoc (indented four spaces; the cross-verb flag
# block below them is indented two, so the indent alone separates them).
usage_verbs() {
    sed -n '/^usage() {/,/^EOF$/p' "${CLI}" \
        | grep -E '^    --[a-z]' | grep -oE -- '--[a-z][a-z-]+' | sort -u
}

DISPATCH="$(dispatch_verbs)"
OPERATOR="$(array_items OPERATOR_VERBS)"
ROOTOK="$(array_items ROOT_ALLOWED_VERBS)"
BOOTEXEMPT="$(array_items BOOTSTRAP_EXEMPT_VERBS)"
FORALLOWED="$(array_items FOR_ALLOWED_VERBS)"

# An empty extraction would make every check below pass vacuously, which is the one way a test
# like this fails silently -- so the extractor is asserted before anything is compared.
if [[ -z "${DISPATCH}" || -z "${OPERATOR}" || -z "${ROOTOK}" || -z "${BOOTEXEMPT}" || -z "${FORALLOWED}" ]]; then
    fail "could not extract a verb set (dispatch=$(wc -w <<<"${DISPATCH}") operator=$(wc -w <<<"${OPERATOR}") root=$(wc -w <<<"${ROOTOK}") bootstrap=$(wc -w <<<"${BOOTEXEMPT}") for=$(wc -w <<<"${FORALLOWED}"))"
    finish; exit
fi
pass "extracted the dispatcher ($(wc -w <<<"${DISPATCH}") verbs) and all four gating tables"

# ── (1) Every dispatched verb is classified ─────────────────────────────────────
# The check with teeth: a new mutating verb that nobody added to OPERATOR_VERBS runs for an
# unenrolled caller, and the first thing to notice would be a root helper refusing it partway.
unclassified="$(comm -23 <(printf '%s\n' "${DISPATCH}") \
                         <(printf '%s\n' "${OPERATOR}" "$(printf '%s\n' "${INFORMATIONAL[@]}")" | sort -u))"
if [[ -z "${unclassified}" ]]; then
    pass "every dispatched verb is either operator-gated or informational"
else
    fail "verb(s) in the dispatcher that no gate classifies: $(tr '\n' ' ' <<<"${unclassified}") -- add each to OPERATOR_VERBS (it acts as an operator) or to INFORMATIONAL in this test (it only reports)"
fi

# ── (2) The two classifications do not overlap ──────────────────────────────────
# Root is refused every operator-acting verb, because a registry written by root names an owner
# whose own launch gate cannot read it. A verb in both tables would be a contradiction the
# principal guard resolves silently, in whichever order it happens to test them.
overlap="$(comm -12 <(printf '%s\n' "${OPERATOR}") <(printf '%s\n' "${ROOTOK}"))"
if [[ -z "${overlap}" ]]; then
    pass "no verb is both operator-acting and root-allowed"
else
    fail "verb(s) in OPERATOR_VERBS and ROOT_ALLOWED_VERBS at once: $(tr '\n' ' ' <<<"${overlap}")"
fi

# ── (3) No table names a verb the dispatcher does not have ──────────────────────
# A stale entry is dead configuration that reads as coverage -- worst for ROOT_ALLOWED_VERBS and
# BOOTSTRAP_EXEMPT_VERBS, whose whole content is exceptions.
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
        fail "${table} names verb(s) the CLI no longer dispatches: $(tr '\n' ' ' <<<"${stale}")"
    fi
done

# ── (4) The help lists exactly the verbs the CLI dispatches ─────────────────────
# man.sh pins usage() against ai-tools(1); this pins it against the CODE, so the three surfaces
# agree transitively. A verb that works but is documented nowhere is as much a defect as the
# reverse -- an operator cannot run what they cannot find.
missing_help="$(comm -23 <(printf '%s\n' "${DISPATCH}") <(printf '%s\n' "$(usage_verbs)"))"
extra_help="$(comm -13 <(printf '%s\n' "${DISPATCH}") <(printf '%s\n' "$(usage_verbs)"))"
if [[ -z "${missing_help}" ]]; then
    pass "every dispatched verb appears in the CLI help"
else
    fail "verb(s) the CLI dispatches but the help omits: $(tr '\n' ' ' <<<"${missing_help}")"
fi
if [[ -z "${extra_help}" ]]; then
    pass "the CLI help lists no verb the dispatcher rejects"
else
    fail "verb(s) in the help that the dispatcher does not accept: $(tr '\n' ' ' <<<"${extra_help}")"
fi

finish
