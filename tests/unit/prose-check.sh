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
# sweep and the pre-commit hook branch on it), the suppression paths (`prose-check: ignore`, and
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
# The fixtures hold cross-reference reftags as text, so the tree-wide reference check does not
# read this file (the marker on the next line).
# ref-index: ignore-file
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
reports fronted-quantifier TEST-PC-01-fronted-quantifier.md "The helper takes no path argument."
reports nothing            TEST-PC-02-nothing.md            "There is nothing left to check."
reports unbacked-cost      TEST-PC-03-unbacked-cost.md      "The label probe is cheap."
reports predicted-action   TEST-PC-04-wants-clause.md \
    "A host that wants it enforced keeps operator.conf root-owned."
reports predicted-action   TEST-PC-05-second-person.md "If you want the notice, you should set the key."
reports positional-reference TEST-PC-67-positional.md \
    "The rule above governs a first draft, and the steps are covered below."
reports positional-reference TEST-PC-68-positional-paren.md \
    "An explicit answer at the end of the install (below) puts the line back."
reports positional-reference TEST-PC-69-positional-placement.md "The details are printed plain below the box."
# A reftag is a prefix, a dash, and a four-character id; a prefix followed by anything else is a
# reftag a search will not find. The bare `ref-` prefix opens ordinary words and is not read.
reports reference-shape TEST-PC-71-reference-shape.md "The owner rule [ref-section-k7q](../cli.rule.md#x) holds."
reports reference-shape TEST-PC-72-reference-shape-code.md "The refusal prints MSG-12 and stops."

# ── ...and stays silent on the corrected form, which is the half a widened pattern breaks ─────
silent TEST-PC-06-fronted-quantifier-ok.md "The helper does not take a path argument."
silent TEST-PC-07-nothing-ok.md "The helper does not read the path argument, so the validator is skipped."
silent TEST-PC-70-positional-threshold.md "A comment line stays below 120 columns, and a box within 80."
silent TEST-PC-73-reference-ok.md \
    "The owner rule [ref-section-j9l2](../cli.rule.md#ref-section-j9l2) holds, and the message carries MSG-N1H8."
silent TEST-PC-74-reference-tool-name.md "Run ref-index.py before a commit."
# A cost claim backed by a frequency, and one backed by a bounded operation named as the subject.
# Both carry a cost word, so each fails if the backing half of the check stops being applied.
silent TEST-PC-08-cost-frequency.md "It runs once per restart, not per connection, so the relabel is cheap."
silent TEST-PC-09-cost-bounded.md "A single write of the whole text keeps the window negligible."
silent TEST-PC-10-predicted-action-ok.md \
    "The installer creates operator.conf root-owned, and the probe reads it there."
# The three neighbouring registers the vocabulary is kept small for: an advisory document
# addressing its reader, a man page addressing an operator, and `reader` naming a FUNCTION. Each
# fails if the check widens beyond the two subjects that name a person outright.
silent TEST-PC-11-person-registers.md \
    "A reader should stop at the first mismatch, and you can set the key by hand." \
    "A clamped reader will refuse the value, which the caller reports."

# ── The cost vocabulary excludes the domain-term compounds, or the check buries itself ────────
silent TEST-PC-12-cost-compounds.md \
    "The prompt is fast-tracked when its default is yes, and the build is fail-fast."

# ── Suppression: the explicit marker, and the quoted span a style guide needs ──────────────────
silent TEST-PC-13-allow-marker.md "The label probe is cheap. <!-- prose-check: ignore -->"
# The backticked spans are the content under test, not shell substitutions.
# shellcheck disable=SC2016
silent TEST-PC-14-quoted-span.md \
    'Write `does not take a path argument` rather than the fronted `takes no path`.'

# ── Exit status is the contract a sweep and the pre-commit hook branch on ──────────────────────
run_check "$(fixture TEST-PC-15-exit-finding.md 'There is nothing left to check.')"
assert_rc 1 "TEST-PC-15-exit-finding: exits 1 when a finding is reported"
run_check "$(fixture TEST-PC-16-exit-clean.md 'The helper does not take a path argument.')"
assert_rc 0 "TEST-PC-16-exit-clean: exits 0 when clean"

# ── The extension decides how a file is read, and --prose/--source override it ─────────────────
# A .conf is read as SOURCE: its comments are prose and its body is not. Without the override a
# document whose name lost its extension reads as source and scores a misleading zero.
run_check "$(fixture TEST-PC-17-source-comment.conf 'KEY=value' '# There is nothing left to check.')"
assert_rc 1 "TEST-PC-17-source-comment: source mode reads a # comment"

body="$(fixture TEST-PC-18-source-body.conf 'There is nothing left to check.')"
run_check "${body}"
assert_rc 0 "TEST-PC-18-source-body: source mode leaves a non-comment body unread"
run_check --prose "${body}"
assert_rc 1 "TEST-PC-18-source-body: --prose reads the same body as prose"

md="$(fixture TEST-PC-19-prose-as-source.md '# There is nothing left to check.' \
                                       'The helper does not take a path argument.')"
run_check --source "${md}"
assert_rc 1 "TEST-PC-19-prose-as-source: --source reads a .md as comments only"

# ── invariant-altitude: mechanism in the always-loaded layer, reported there and nowhere else ──
# One sentence, two placements. The mark is a file mode, which a domain rule states and a router
# points at; what the check reads is the PATH, so the same sentence must report in a CLAUDE.md
# and stay unreported in a rule file -- the scope is the whole check, and one that stopped
# reading the path would report every header and rule in the tree.
# The router fixture takes the one name the check reads, so its case id travels in the assertion.
# The backticked spans are fixture content, not shell substitutions -- as at TEST-PC-14.
# shellcheck disable=SC2016
altitude='The stop helper is `750 root:root`, so the agent cannot replace it.'
run_check "$(fixture CLAUDE.md "${altitude}")"
assert_grep invariant-altitude "${OUT}" "TEST-PC-20-altitude-mode: reports a file mode in the router"

run_check "$(fixture TEST-PC-21-domain.rule.md "${altitude}")"
omits invariant-altitude "TEST-PC-21-domain: the same sentence is not reported in a domain rule"

# The other two marks, each the altitude drift the check exists for: a reference into a source
# file, and a test path standing in for the assertion a rule cites.
# shellcheck disable=SC2016
run_check "$(fixture CLAUDE.md 'The gate is in `providers.lib.sh:123`, which the launch path calls.')"
assert_grep invariant-altitude "${OUT}" "TEST-PC-22-altitude-file-line: reports a file:line reference"
run_check "$(fixture CLAUDE.md 'The refusal is asserted in tests/unit/providers.sh, from both ends.')"
assert_grep invariant-altitude "${OUT}" "TEST-PC-23-altitude-test-path: reports a test path"

# An invariant naming the same components without the mechanism is what the router is FOR, so a
# mark that widened into ordinary router prose fails here.
# shellcheck disable=SC2016
run_check "$(fixture CLAUDE.md \
    'The control plane is root-owned and not writable by `SANDBOX_USER`.')"
assert_rc 0 "TEST-PC-24-router-invariant: an invariant carrying no mechanism is not reported"

# ── closed-set-count: a count word standing in for the members it counts (--all) ──────────────
# The pronoun form is the one that goes stale silently: a third config file makes `seeds both`
# wrong about what it describes while reading as ordinary prose. Pinned from both directions,
# since the exclusions carry most of the check -- widened, it reports every `both files` and
# `A and B both hold` in the tree and becomes noise a reader stops reading.
run_check --all "$(fixture TEST-PC-25-closed-set.md 'The command seeds both.')"
assert_grep closed-set-count "${OUT}" "TEST-PC-25-closed-set: reports a count word standing alone"

run_check --all "$(fixture TEST-PC-26-closed-set-named.md \
    "The command seeds the operator's config files.")"
omits closed-set-count "TEST-PC-26-closed-set-named: the named set is not reported"

run_check --all "$(fixture TEST-PC-27-closed-set-noun.md 'Both files are seeded at enrolment.')"
omits closed-set-count "TEST-PC-27-closed-set-noun: a following noun names what is counted"

run_check --all "$(fixture TEST-PC-28-closed-set-correlative.md \
    'It seeds both the allowlist and the secret patterns.' \
    'The manifest and the key both ship in the package.')"
omits closed-set-count "TEST-PC-28-closed-set-correlative: enumerated members are not reported"

# ── --kept: the rewrite guard, driven over a real git index ────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
    skip "TEST-PC-30..34-kept" "git not available"
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
    assert_grep dropped  "${kept}" "TEST-PC-30-kept-set: --kept reports a dropped security term"
    assert_grep weakened "${kept}" "TEST-PC-31-kept-modality: --kept reports a weakened modality"

    # A rewrite that carries the claim through is silent, so the check is usable on a sweep.
    printf 'The file does not carry any secrets, and the rule is never a glob.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    if [[ -z "${kept}" ]]; then
        pass "TEST-PC-32-kept-preserved: --kept is silent when the claim survives the rewrite"
    else
        fail "TEST-PC-32-kept-preserved: --kept reported a preserved claim: ${kept}"
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
    assert_grep 'dropped \[read\]' "${kept}" "TEST-PC-33-kept-access-verb: reports a dropped verb"

    # An inflection is not a dropped claim: the two sides must reduce to one term, including the
    # `-es` forms, or every rewrite that changes only a verb's number reports as a lost operation.
    printf 'The helper searches the tree once.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm inflection
    printf 'The helper does not search the tree.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    if [[ -z "${kept}" ]]; then
        pass "TEST-PC-34-kept-inflection: an access verb's inflections read as one term"
    else
        fail "TEST-PC-34-kept-inflection: reported an inflection as a dropped claim: ${kept}"
    fi

    # An RFC 2119 verb fixes how binding a sentence is, so demoting one to a plain present tense
    # turns a constraint the code was built to satisfy into a report of what it happens to do.
    git -C "${repo}" -c commit.gpgsign=false commit -qm rfc-base
    printf 'A preview must not ask to apply.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm rfc
    printf 'A preview stops before the confirmation.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep 'weakened \[must not\]' "${kept}" \
        "TEST-PC-35-kept-rfc-verb: reports a dropped RFC 2119 verb"

    # `must not` weakened to a bare `must` is the same defect one step smaller, so the negation is
    # matched before the stem it begins with rather than being absorbed into it.
    printf 'A preview must ask before it applies.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep 'weakened \[must not\]' "${kept}" \
        'TEST-PC-36-kept-negation-first: "must not" weakened to "must" is reported'

    # The guideline is to write the long form, so a contraction carries the same claim and a
    # rewrite between the two forms is a wording change rather than a weakening.
    printf 'The agent cannot read the file.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm contraction
    printf "The agent can't read the file.\n" > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    if [[ -z "${kept}" ]]; then
        pass "TEST-PC-37-kept-contraction: a contraction and its long form read as one modality"
    else
        fail "TEST-PC-37-kept-contraction: reported a contraction as a weakening: ${kept}"
    fi

    # And the contraction is matched, so dropping one is reported like dropping its long form.
    printf 'The agent reads the file.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep 'weakened \[cannot\]' "${kept}" \
        "TEST-PC-38-kept-contraction-dropped: a dropped contraction reports as its long form"

    # A special bit is often the mechanism rather than a detail of it, so rendering a mode as
    # prose drops the bit that does the work. The ten-character rendering, the symbolic mode and
    # the four-digit octal are terms for that reason.
    git -C "${repo}" -c commit.gpgsign=false commit -qm bits-base
    printf 'The home root is drwxr-s--x at 2751, and the claim runs chmod g+s on it.\n' \
        > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm bits
    printf 'The home root gives the group read and traverse.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep 'dropped \[drwxr-s--x\]' "${kept}" \
        "TEST-PC-39-kept-mode-rendering: a dropped mode rendering is reported"
    assert_grep 'dropped \[g+s\]' "${kept}" \
        "TEST-PC-39-kept-symbolic-mode: a dropped symbolic mode is reported"
    assert_grep 'dropped \[2751\]' "${kept}" \
        "TEST-PC-39-kept-special-octal: a dropped four-digit octal is reported"

    # A permission that CHANGES is the same defect as one that goes: the claim the old mode made
    # is gone either way, and a mode edited in place is the easier one to read past. The set
    # difference reports it, so a rewrite cannot move a bit without saying so.
    printf 'The dir is 2751 and the file is 640, stripped with g-x.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm modes
    printf 'The dir is 2750 and the file is 660, stripped with g-w.\n' > "${repo}/doc.md"
    git -C "${repo}" add doc.md
    kept="$(cd "${repo}" && python3 "${PC}" --kept 2>&1)" || true
    assert_grep 'dropped \[2751\]' "${kept}" \
        "TEST-PC-39-kept-mode-changed: an octal changed in place is reported"
    assert_grep 'dropped \[g-x\]' "${kept}" \
        "TEST-PC-39-kept-symbolic-changed: a symbolic mode changed in place is reported"
fi

# ── --message: a commit message is an artifact the standard covers like any other ──────────────
msg="$(fixture TEST-PC-40-message.txt 'fix(x): state what changed' '' 'There is nothing left to check.')"
run_check --message "${msg}"
assert_rc 1 "TEST-PC-40-message: --message checks a commit message"

# ── --config-header: a config file's header is fixed-width text ────────────────────────────────
# Both rules are pinned from both directions, and the exemptions with them: a commented default
# is a setting, so its length is not measured and its last word is not read; a comment line
# that closes a sentence on a tie word is not a wrapped line.
long="# $(printf 'x%.0s' $(seq 1 75))"
run_check --config-header "$(fixture TEST-PC-41-header-width.conf "${long}")"
assert_grep 'header-width \[77>72\]' "${OUT}" "TEST-PC-41-header-width: a 77-column comment line is reported at the default width"
run_check --config-header --width 80 "$(fixture TEST-PC-42-header-width-arg.conf "${long}")"
assert_rc 0 "TEST-PC-42-header-width-arg: the same line is within an explicit width of 80"
run_check --config-header "$(fixture TEST-PC-43-header-default.conf "#KEY=$(printf 'v%.0s' $(seq 1 75))")"
assert_rc 0 "TEST-PC-43-header-default: a commented default is not measured"
run_check --config-header "$(fixture TEST-PC-44-header-tie.conf '# A session starts only inside a' '# listed directory.')"
assert_grep 'header-tie \[a\]' "${OUT}" "TEST-PC-44-header-tie: a comment line ending on an article is reported"
run_check --config-header "$(fixture TEST-PC-45-header-tie-prep.conf '# the token is passed to Claude Code by' '# name.')"
assert_grep 'header-tie \[by\]' "${OUT}" "TEST-PC-45-header-tie-prep: a comment line ending on a preposition is reported"
run_check --config-header "$(fixture TEST-PC-46-header-tie-sentence.conf '# carve this subtree out.' '# Next sentence.')"
assert_rc 0 "TEST-PC-46-header-tie-sentence: a tie word closing a sentence is not reported"
run_check --config-header "$(fixture TEST-PC-47-header-clean.conf '# A session starts only inside' '# a listed directory.' 'KEY=value' '#OTHER=default')"
assert_rc 0 "TEST-PC-47-header-clean: a wrapped header, a setting and a commented default are silent"

# ── --wrap: the line checks on source comments, opt-in ───────────────────────────────────────
# A source comment is read as written, so under --wrap it holds to the tie rule and a 120-column
# wrap. Opt-in, so the default run stays silent on how a line is wrapped: that is pinned first,
# since a tree whose comments predate the rule would otherwise report every one of them.
silent TEST-PC-48a-wrap-off-by-default.sh 'KEY=1' '# The helper reads the list from the operator, the' '# one whose allowlist covers the path.'
wrapped() {  # wrapped <check> <case>.<ext> <line...>: PASS when the check is reported under --wrap
    local check="$1" name="$2"; shift 2
    run_check --wrap "$(fixture "${name}" "$@")"
    if grep -q -- "${check}" <<<"${OUT}"; then pass "${name%%.*}: reports ${check} under --wrap"
    else fail "${name%%.*}: did NOT report ${check} under --wrap"; fi
}
wrapped_silent() {  # wrapped_silent <case>.<ext> <line...>: PASS when --wrap reports the fixture clean
    local name="$1"; shift
    run_check --wrap "$(fixture "${name}" "$@")"
    if [[ "${RC}" -eq 0 && -z "${OUT}" ]]; then pass "${name%%.*}: silent under --wrap (rc 0)"
    else fail "${name%%.*}: expected no finding under --wrap; rc ${RC}, output: ${OUT}"; fi
}
wrapped comment-tie TEST-PC-49-comment-tie.sh 'KEY=1' '# The helper reads the list from the operator, the' '# one whose allowlist covers the path.'
wrapped comment-tie TEST-PC-50-comment-tie-docstring.py 'def f():' '    """Return the rows of' '    the table."""'
wrapped_silent TEST-PC-51-comment-tie-wrapped.sh 'KEY=1' '# The helper reads the list from the operator,' '# the one whose allowlist covers the path.'
wrapped_silent TEST-PC-52-comment-tie-sentence.sh '# Carve this subtree out.' '# Next sentence.'
wrapped_silent TEST-PC-53-comment-tie-prose.md 'A document reflows, so a line may end on the' 'next word.'
wrapped_silent TEST-PC-54-comment-tie-code.sh 'value="$(cat a)"    # not a comment ending on a' 'x=1'
# A source comment wraps at 120 columns, wider than a config header's 72; --width overrides it.
wide="# $(printf 'w%.0s' $(seq 1 125))"
wrapped comment-width TEST-PC-55-comment-width.sh 'x=1' "${wide}"
wrapped_silent TEST-PC-56-comment-width-under.sh 'x=1' "# $(printf 'w%.0s' $(seq 1 110))"
run_check --wrap --width 100 "$(fixture TEST-PC-57-comment-width-arg.sh 'x=1' "# $(printf 'w%.0s' $(seq 1 110))")"
assert_grep 'comment-width \[112>100\]' "${OUT}" "TEST-PC-57-comment-width-arg: --width lowers the column a source comment is measured against"
# A linter directive is read by the linter, so neither line rule reads it, however long or however it ends.
wrapped_silent TEST-PC-58-comment-directive.sh 'x=1' "# shellcheck disable=SC2154  # set by the sourced library, whose contract names the" "y=2"
# A Markdown document is read unrendered too -- in an editor, a diff -- so under --wrap a line holds
# to 100 columns. A table row, a fenced block, a URL line, a lone token and a man page are units
# the rule cannot break, and each is pinned silent.
long_md="$(printf 'word %.0s' $(seq 1 25))"
wrapped document-width TEST-PC-59-document-width.md '# Title' "${long_md}"
wrapped_silent TEST-PC-60-document-width-under.md '# Title' "$(printf 'word %.0s' $(seq 1 19))"
wrapped_silent TEST-PC-61-document-width-table.md '| a | b |' '|---|---|' "| $(printf 'cell %.0s' $(seq 1 25)) | x |"
wrapped_silent TEST-PC-62-document-width-fence.md '```' "${long_md}" '```' 'After the fence.'
wrapped_silent TEST-PC-63-document-width-url.md "See https://example.invalid/$(printf 'p%.0s' $(seq 1 100)) for the reference."
wrapped_silent TEST-PC-64-document-width-token.md "$(printf 'p%.0s' $(seq 1 110))"
wrapped_silent TEST-PC-65-document-width-man.1 '.TH X 1' "${long_md}"
# The parenthesised part of a label link is generated, so a line is measured without it.
wrapped_silent TEST-PC-75-document-width-label-link.md \
    "$(printf 'word %.0s' $(seq 1 15))[ref-section-y4v2](../../src/usr/share/ai-tools/skills/ai-tools-technical-docs/SKILL.md#ref-section-y4v2) ends."
run_check --wrap --width 80 "$(fixture TEST-PC-66-document-width-arg.md '# Title' "$(printf 'word %.0s' $(seq 1 19))")"
assert_grep 'document-width \[94>80\]' "${OUT}" "TEST-PC-66-document-width-arg: --width lowers the column a document line is measured against"

# The tie set is msg.lib.sh's, mirrored: the runtime wrap and the header check must agree
# on which words carry to the next line, or a header passes here and wraps differently in a box.
MSG_LIB="${ROOT}/src/usr/local/lib/ai-tools/msg.lib.sh"
[[ -r "${MSG_LIB}" ]] || MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
if [[ -r "${MSG_LIB}" ]]; then
    lib_ties="$(sed -n '/^readonly _AI_TOOLS_MSG_TIES=/,/"$/p' "${MSG_LIB}" | tr -d '"\\' | sed 's/^readonly _AI_TOOLS_MSG_TIES=//' | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')"
    py_ties="$(python3 - "${PC}" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pc", sys.argv[1]); pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
print(" ".join(sorted(pc.HEADER_TIES)), end=" ")
EOF
)"
    if [[ "${lib_ties}" == "${py_ties}" ]]; then
        pass "TEST-PC-48-tie-set: the header tie set matches msg.lib.sh's _AI_TOOLS_MSG_TIES"
    else
        fail "TEST-PC-48-tie-set: tie sets differ -- msg.lib: '${lib_ties}' checker: '${py_ties}'"
    fi
else
    skip "TEST-PC-48-tie-set" "msg.lib.sh not readable in the repo or installed"
fi

finish
