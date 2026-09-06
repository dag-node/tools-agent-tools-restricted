#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/prose-check.sh
# Unit test for prose-check.py, the checker shipped beside the ai-tools-technical-docs skill. It
# is the mechanical half of the writing standard: every artifact in this tree is swept with it,
# and a rule that silently stops firing takes the whole sweep with it -- a regression here reads
# as "the tree is clean" rather than as a failure, which is why the checks are pinned from both
# directions. Each default check is driven with a sentence it MUST report and with the corrected
# form it MUST stay silent on, so neither a broken pattern nor one widened into reporting good
# prose survives.
#
# Also pins the three behaviours a caller depends on but no finding names: the exit status (a
# sweep and the pre-commit hook branch on it), the suppression paths (`prose-check: allow`, and
# the backticked span that lets a style guide quote the prose it warns against), and the
# extension-driven read mode that `--prose`/`--source` override. `--kept` is driven over a real
# git index, since it is the check that guards a security claim through a rewrite.
#
# Hermetic: fixtures are written in the test's own /tmp testdir and the checker is run on those
# paths only. Pure text analysis, so it does not need privilege of its own; run as root via sudo
# like the rest of the suite. Validates the repo source, falling back to the installed copies.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "prose-check: writing-standard checker (unit)"

PC=""
for candidate in \
    "${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py" \
    "/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py" \
    "/opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py"; do
    [[ -r "${candidate}" ]] && { PC="${candidate}"; break; }
done

if [[ -z "${PC}" ]]; then
    skip "prose-check" "checker not readable in the repo or in either shipped location"; finish; exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    skip "prose-check" "python3 not available"; finish; exit
fi

mktestdir
note "checker" "${PC}"

# run_check <argument...>: run the checker, leaving its output in OUT and its status in RC. A
# finding makes it exit 1, which `|| RC=$?` keeps non-fatal under set -e.
RC=0 OUT=""
run_check() {
    RC=0
    OUT="$(python3 "${PC}" "$@" 2>&1)" || RC=$?
}

# fixture <name> <line...>: write a fixture file in TESTDIR and echo its path.
fixture() {
    local name="$1"; shift
    printf '%s\n' "$@" > "${TESTDIR}/${name}"
    printf '%s' "${TESTDIR}/${name}"
}

# reports <check> <name> <line...>: PASS when the named check is reported for the fixture.
reports() {
    local check="$1" name="$2"; shift 2
    run_check "$(fixture "${name}" "$@")"
    if grep -q -- "${check}" <<<"${OUT}"; then
        pass "reports ${check}: ${1}"
    else
        fail "did NOT report ${check}: ${1}"
    fi
}

# silent <name> <line...>: PASS when the fixture is reported clean and the run exits 0.
silent() {
    local name="$1"; shift
    run_check "$(fixture "${name}" "$@")"
    if [[ "${RC}" -eq 0 && -z "${OUT}" ]]; then
        pass "silent (rc 0): ${1}"
    else
        fail "expected no finding for '${1}'; rc ${RC}, output: ${OUT}"
    fi
}

# assert_rc <expected> <description>: PASS when the last run_check exited as expected.
assert_rc() {
    if [[ "${RC}" -eq "$1" ]]; then
        pass "$2"
    else
        fail "$2 -- expected rc $1, got ${RC}${OUT:+; output: ${OUT}}"
    fi
}

# assert_grep <pattern> <text> <description>: PASS when the pattern is present in the text.
assert_grep() {
    if grep -q -- "$1" <<<"$2"; then
        pass "$3"
    else
        fail "$3 -- pattern '$1' absent from: $2"
    fi
}

# ── Each default check fires on the shape it names ────────────────────────────────────────────
reports fronted-quantifier fq.md "The helper takes no path argument."
reports nothing            no.md "There is nothing left to check."
reports unbacked-cost      uc.md "The label probe is cheap."

# ── ...and stays silent on the corrected form, which is the half a widened pattern breaks ─────
silent fq-ok.md "The helper does not take a path argument."
silent no-ok.md "The helper does not read the path argument, so the validator is skipped."
# A cost claim backed by a frequency, and one backed by a bounded operation named as the subject.
# Both carry a cost word, so each fails if the backing half of the check stops being applied.
silent uc-freq.md "It runs once per restart, not per connection, so the relabel is cheap."
silent uc-bound.md "A single write of the whole text keeps the window negligible."

# ── The cost vocabulary excludes the domain-term compounds, or the check buries itself ────────
silent uc-domain.md "The prompt is fast-tracked when its default is yes, and the build is fail-fast."

# ── Suppression: the explicit marker, and the quoted span a style guide needs ──────────────────
silent allow.md "The label probe is cheap. <!-- prose-check: allow -->"
# The backticked spans are the content under test, not shell substitutions.
# shellcheck disable=SC2016
silent quoted.md 'Write `does not take a path argument` rather than the fronted `takes no path`.'

# ── Exit status is the contract a sweep and the pre-commit hook branch on ──────────────────────
run_check "$(fixture rc-bad.md 'There is nothing left to check.')"
assert_rc 1 "exits 1 when a finding is reported"
run_check "$(fixture rc-ok.md 'The helper does not take a path argument.')"
assert_rc 0 "exits 0 when clean"

# ── The extension decides how a file is read, and --prose/--source override it ─────────────────
# A .conf is read as SOURCE: its comments are prose and its body is not. Without the override a
# document whose name lost its extension reads as source and scores a misleading zero.
run_check "$(fixture mode.conf 'KEY=value' '# There is nothing left to check.')"
assert_rc 1 "source mode reads a # comment"

body="$(fixture body.conf 'There is nothing left to check.')"
run_check "${body}"
assert_rc 0 "source mode leaves a non-comment body unread"
run_check --prose "${body}"
assert_rc 1 "--prose reads the same body as prose"

md="$(fixture src.md '# There is nothing left to check.' 'The helper does not take a path argument.')"
run_check --source "${md}"
assert_rc 1 "--source reads a .md as comments only"

# ── --kept: the rewrite guard, driven over a real git index ────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
    skip "--kept" "git not available"
else
    repo="${TESTDIR}/repo"
    mkdir -p "${repo}"
    git -C "${repo}" init -q
    git -C "${repo}" config user.email t@example.invalid
    git -C "${repo}" config user.name t
    printf 'The file carries no secrets, and the rule is never a glob.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm base
    # The worked example from the standard: a rewrite that swaps the SET it quantifies over, and
    # one that swaps a universal for a single instance. Both read as tidying; both retire a claim.
    printf 'The file contains only settings, and the rule is not a glob.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md

    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep dropped  "${kept}" "--kept reports a dropped security term"
    assert_grep weakened "${kept}" "--kept reports a weakened modality"

    # A rewrite that carries the claim through is silent, so the check is usable on a sweep.
    printf 'The file does not carry any secrets, and the rule is never a glob.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    if [[ -z "${kept}" ]]; then
        pass "--kept is silent when the claim survives the rewrite"
    else
        fail "--kept reported a preserved claim: ${kept}"
    fi
fi

# ── --message: a commit message is an artifact the standard covers like any other ──────────────
msg="$(fixture msg.txt 'fix(x): state what changed' '' 'There is nothing left to check.')"
run_check --message "${msg}"
assert_rc 1 "--message checks a commit message"

finish
