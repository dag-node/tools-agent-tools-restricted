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
# `invariant-altitude` is pinned from both sides of its scope, since it is the one check that
# reads the file NAME. The two ways that scope can regress are not symmetric: narrowed to no file
# it stays silent, which reads as a clean sweep, so the router fixture it MUST report on is what
# catches that; widened, it reports every file mode and test path in the tree, which the rule
# fixture catches on the first hit.
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

# Every result line names its CASE: a unique per-case id, never the sentence the case drives. The
# fixture file carries the same id, so the checker's own `path:line:` report and the harness
# result line name one case, and the deliberate bad examples half of these fixtures hold stay in
# the fixtures, where the standard is their one home and a transcript that is read, pasted and
# grepped does not carry them. A failure prints the finding, which is the detail a reader needs.
#
# reports <check> <case>.<ext> <line...>: PASS when the named check is reported for the fixture.
reports() {
    local check="$1" name="$2"; shift 2
    run_check "$(fixture "${name}" "$@")"
    if grep -q -- "${check}" <<<"${OUT}"; then
        pass "${name%%.*}: reports ${check}"
    else
        fail "${name%%.*}: did NOT report ${check}"
    fi
}

# silent <case>.<ext> <line...>: PASS when the fixture is reported clean and the run exits 0.
silent() {
    local name="$1"; shift
    run_check "$(fixture "${name}" "$@")"
    if [[ "${RC}" -eq 0 && -z "${OUT}" ]]; then
        pass "${name%%.*}: silent (rc 0)"
    else
        fail "${name%%.*}: expected no finding; rc ${RC}, output: ${OUT}"
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

# omits <check> <description>: PASS when the last run_check did NOT report the named check. The
# fixture may carry other findings, so this is the assertion for a check that must not FIRE, as
# distinct from `silent`, which requires a fixture the whole default set passes over.
omits() {
    if grep -q -- "$1" <<<"${OUT}"; then
        fail "$2 -- reported ${1}: ${OUT}"
    else
        pass "$2"
    fi
}

# ── Each default check fires on the shape it names ────────────────────────────────────────────
reports fronted-quantifier PC-01-fronted-quantifier.md "The helper takes no path argument."
reports nothing            PC-02-nothing.md            "There is nothing left to check."
reports unbacked-cost      PC-03-unbacked-cost.md      "The label probe is cheap."
reports predicted-action   PC-04-wants-clause.md \
    "A host that wants it enforced keeps operator.conf root-owned."
reports predicted-action   PC-05-second-person.md "If you want the notice, you should set the key."

# ── ...and stays silent on the corrected form, which is the half a widened pattern breaks ─────
silent PC-06-fronted-quantifier-ok.md "The helper does not take a path argument."
silent PC-07-nothing-ok.md "The helper does not read the path argument, so the validator is skipped."
# A cost claim backed by a frequency, and one backed by a bounded operation named as the subject.
# Both carry a cost word, so each fails if the backing half of the check stops being applied.
silent PC-08-cost-frequency.md "It runs once per restart, not per connection, so the relabel is cheap."
silent PC-09-cost-bounded.md "A single write of the whole text keeps the window negligible."
silent PC-10-predicted-action-ok.md \
    "The installer creates operator.conf root-owned, and the probe reads it there."
# The three neighbouring registers the vocabulary is kept small for: an advisory document
# addressing its reader, a man page addressing an operator, and `reader` naming a FUNCTION. Each
# fails if the check widens beyond the two subjects that name a person outright.
silent PC-11-person-registers.md \
    "A reader should stop at the first mismatch, and you can set the key by hand." \
    "A clamped reader will refuse the value, which the caller reports."

# ── The cost vocabulary excludes the domain-term compounds, or the check buries itself ────────
silent PC-12-cost-compounds.md \
    "The prompt is fast-tracked when its default is yes, and the build is fail-fast."

# ── Suppression: the explicit marker, and the quoted span a style guide needs ──────────────────
silent PC-13-allow-marker.md "The label probe is cheap. <!-- prose-check: allow -->"
# The backticked spans are the content under test, not shell substitutions.
# shellcheck disable=SC2016
silent PC-14-quoted-span.md \
    'Write `does not take a path argument` rather than the fronted `takes no path`.'

# ── Exit status is the contract a sweep and the pre-commit hook branch on ──────────────────────
run_check "$(fixture PC-15-exit-finding.md 'There is nothing left to check.')"
assert_rc 1 "PC-15-exit-finding: exits 1 when a finding is reported"
run_check "$(fixture PC-16-exit-clean.md 'The helper does not take a path argument.')"
assert_rc 0 "PC-16-exit-clean: exits 0 when clean"

# ── The extension decides how a file is read, and --prose/--source override it ─────────────────
# A .conf is read as SOURCE: its comments are prose and its body is not. Without the override a
# document whose name lost its extension reads as source and scores a misleading zero.
run_check "$(fixture PC-17-source-comment.conf 'KEY=value' '# There is nothing left to check.')"
assert_rc 1 "PC-17-source-comment: source mode reads a # comment"

body="$(fixture PC-18-source-body.conf 'There is nothing left to check.')"
run_check "${body}"
assert_rc 0 "PC-18-source-body: source mode leaves a non-comment body unread"
run_check --prose "${body}"
assert_rc 1 "PC-18-source-body: --prose reads the same body as prose"

md="$(fixture PC-19-prose-as-source.md '# There is nothing left to check.' \
                                       'The helper does not take a path argument.')"
run_check --source "${md}"
assert_rc 1 "PC-19-prose-as-source: --source reads a .md as comments only"

# ── invariant-altitude: mechanism in the always-loaded layer, reported there and nowhere else ──
# One sentence, two placements. The mark is a file mode, which a domain rule states and a router
# points at; what the check reads is the PATH, so the same sentence must report in a CLAUDE.md
# and stay unreported in a rule file -- the scope is the whole check, and one that stopped
# reading the path would report every header and rule in the tree.
# The router fixture takes the one name the check reads, so its case id travels in the assertion.
# The backticked spans are fixture content, not shell substitutions -- as at PC-14 above.
# shellcheck disable=SC2016
altitude='The stop helper is `750 root:root`, so the agent cannot replace it.'
run_check "$(fixture CLAUDE.md "${altitude}")"
assert_grep invariant-altitude "${OUT}" "PC-20-altitude-mode: reports a file mode in the router"

run_check "$(fixture PC-21-domain.rule.md "${altitude}")"
omits invariant-altitude "PC-21-domain: the same sentence is not reported in a domain rule"

# The other two marks, each the altitude drift the check exists for: a reference into a source
# file, and a test path standing in for the assertion a rule cites.
# shellcheck disable=SC2016
run_check "$(fixture CLAUDE.md 'The gate is in `providers.lib.sh:123`, which the launch path calls.')"
assert_grep invariant-altitude "${OUT}" "PC-22-altitude-file-line: reports a file:line reference"
run_check "$(fixture CLAUDE.md 'The refusal is asserted in tests/unit/providers.sh, from both ends.')"
assert_grep invariant-altitude "${OUT}" "PC-23-altitude-test-path: reports a test path"

# An invariant naming the same components without the mechanism is what the router is FOR, so a
# mark that widened into ordinary router prose fails here.
# shellcheck disable=SC2016
run_check "$(fixture CLAUDE.md \
    'The control plane is root-owned and not writable by `SANDBOX_USER`.')"
assert_rc 0 "PC-24-router-invariant: an invariant carrying no mechanism is not reported"

# ── --kept: the rewrite guard, driven over a real git index ────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
    skip "PC-30..34-kept" "git not available"
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
    assert_grep dropped  "${kept}" "PC-30-kept-set: --kept reports a dropped security term"
    assert_grep weakened "${kept}" "PC-31-kept-modality: --kept reports a weakened modality"

    # A rewrite that carries the claim through is silent, so the check is usable on a sweep.
    printf 'The file does not carry any secrets, and the rule is never a glob.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    if [[ -z "${kept}" ]]; then
        pass "PC-32-kept-preserved: --kept is silent when the claim survives the rewrite"
    else
        fail "PC-32-kept-preserved: --kept reported a preserved claim: ${kept}"
    fi

    # An access verb names the operation a sentence permits or refuses, so a rewrite that keeps
    # the vocabulary of access and drops the verb changes which operation the claim is about --
    # and leaves the set, the number and the modality intact, which is what keeps the other two
    # kinds silent on it.
    git -C "${repo}" -c commit.gpgsign=false commit -qm kept
    printf 'The agent may not read other users files.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm verb
    printf 'No rule grants access to them.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep 'dropped \[read\]' "${kept}" "PC-33-kept-access-verb: reports a dropped verb"

    # An inflection is not a dropped claim: the two sides must reduce to one term, including the
    # `-es` forms, or every rewrite that changes only a verb's number reports as a lost operation.
    printf 'The helper searches the tree once.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm inflection
    printf 'The helper does not search the tree.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    if [[ -z "${kept}" ]]; then
        pass "PC-34-kept-inflection: an access verb's inflections read as one term"
    else
        fail "PC-34-kept-inflection: reported an inflection as a dropped claim: ${kept}"
    fi
fi

# ── --message: a commit message is an artifact the standard covers like any other ──────────────
msg="$(fixture PC-40-message.txt 'fix(x): state what changed' '' 'There is nothing left to check.')"
run_check --message "${msg}"
assert_rc 1 "PC-40-message: --message checks a commit message"

finish
