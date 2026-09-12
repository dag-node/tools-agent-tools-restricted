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
# sweep and the pre-commit hook branch on it), the suppression paths (`prose-check: ignore`,
# `prose-check: ignore-file` for a generated file, and
# the backticked span that lets a style guide quote the prose it warns against), and the
# extension-driven read mode that `--prose`/`--source` override. `--kept` is driven over a real
# git index, since it is the check that guards a security claim through a rewrite.
#
# The markup checks are pinned from both sides of their SURFACE as well as their pattern.
# `bare-option` reads a document and a source comment; `bare-placeholder`, `bare-variable`
# and `bare-path` read a document alone, so each of those is driven with one sentence in both
# places. Widened to comments the document-only checks report several thousand sites in this
# tree, a pre-commit hook no commit can answer for; narrowed further they report a clean tree.
# The exemptions carry the rest of the pattern work and each is driven through the one check
# that reads it: a roff page, a doc comment's contract line, an SPDX tag, and a Markdown link.
# The regions that are not the author's prose -- a document's frontmatter, its indented code
# blocks, and the addresses in it -- are pinned from BOTH sides, since each is bounded by prose
# the checks must still read: a folded scalar's body, a list continuation at the same indent,
# and the sentence a URL sits in.
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
# An emit verb elsewhere in the sentence does not exempt a `nothing` it does not govern. This is
# the widening guard on the empty-result carve-out: read loosely it silences the defect the check
# exists for, and the sentence that names both is what catches it.
reports nothing            TEST-PC-79-nothing-ungoverned.md \
    "The sweep prints a summary, and nothing is exempt."
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
# `nothing` as the object of an OUTPUT verb names an empty result, which is a contract rather than
# a hidden scope. Two of the verbs, since the exemption turns on the object being the output.
silent TEST-PC-80-nothing-result.md \
    "Prints nothing when the set in force matches the baseline." \
    "The drift report writes nothing on a host that has kept the shipped patterns."
# The verbs NOT exempt, each a different claim: an authority whose scope is still owed, a value a
# caller gets back rather than reads, and an empty effect. A widened list silences all three.
reports nothing TEST-PC-81-nothing-granted.md "A claim over a sealed directory grants nothing."
reports nothing TEST-PC-82-nothing-returned.md "The helper returns nothing when the two agree."
reports nothing TEST-PC-83-nothing-run.md "A comment between the two runs nothing."
silent TEST-PC-70-positional-threshold.md "A comment line stays below 120 columns, and a box within 80."
silent TEST-PC-73-reference-ok.md \
    "The owner rule [ref-section-j9l2](../cli.rule.md#ref-section-j9l2) holds, and the message carries MSG-F6Z3."
# shellcheck disable=SC2016
silent TEST-PC-74-reference-tool-name.md 'Run `ref-index.py` before a commit.'
# A cost claim backed by a frequency, and one backed by a bounded operation named as the subject.
# Both carry a cost word, so each fails if the backing half of the check stops being applied.
silent TEST-PC-08-cost-frequency.md "It runs once per restart, not per connection, so the relabel is cheap."
silent TEST-PC-09-cost-bounded.md "A single write of the whole text keeps the window negligible."
# shellcheck disable=SC2016
silent TEST-PC-10-predicted-action-ok.md \
    'The installer creates `operator.conf` root-owned, and the probe reads it there.'
# The three neighbouring registers the vocabulary is kept small for: an advisory document
# addressing its reader, a man page addressing an operator, and `reader` naming a FUNCTION. Each
# fails if the check widens beyond the two subjects that name a person outright.
silent TEST-PC-11-person-registers.md \
    "A reader should stop at the first mismatch, and you can set the key by hand." \
    "A clamped reader will refuse the value, which the caller reports."

# ── The cost vocabulary excludes the domain-term compounds, or the check buries itself ────────
silent TEST-PC-12-cost-compounds.md \
    "The prompt is fast-tracked when its default is yes, and the build is fail-fast."

# ── The markup checks: a literal a reader types is backticked ─────────────────────────────────
# One check per kind over one rule, and what each is pinned for differs. The surface split
# carries the most: `bare-option` reads a document AND a source comment, while
# `bare-placeholder`, `bare-variable` and `bare-path` read a document alone, so each of those is
# driven with one sentence in both places -- reported as a document, silent as a comment. Widened
# to comments the document-only checks report several thousand sites in this tree, which no
# pre-commit hook can answer for; narrowed further they report a clean tree.
reports bare-option      TEST-PC-84-bare-option.md "Pass --project-claim to register the tree."
reports bare-option      TEST-PC-85-bare-option-short.md "The -n spelling was dropped at 0.15.0."
reports bare-option      TEST-PC-86-bare-option-comment.sh \
    'x=1' '# The claim takes --for and refuses root.'
reports bare-placeholder TEST-PC-87-bare-placeholder.md \
    "The helper writes <operator> into the registry."
reports bare-variable    TEST-PC-88-bare-variable.md "The unit hands AI_TOOLS_AGENT_EXEC to the shim."
reports bare-path        TEST-PC-89-bare-path-root.md "The gate is staged under src/usr/local/bin."
reports bare-path        TEST-PC-90-bare-path-extension.md \
    "The seeder reads managed-assets.lib.sh from the datadir."

# The corrected form, every kind at once: what the sweep leaves behind must be silent,
# or the checks report the tree they were run over.
# shellcheck disable=SC2016
silent TEST-PC-91-markup-backticked.md \
    'Pass `--project-claim` to register the tree, writing `<operator>` into the registry.' \
    'The unit hands `AI_TOOLS_AGENT_EXEC` to `src/usr/local/bin/ai-tools-run`.'

# The three shapes a bare `-` takes in prose and none of which is an option: a hyphenated word,
# the spaced dashes an author writes for an em dash, and a Markdown list marker.
silent TEST-PC-92-option-not-an-option.md \
    "A well-maintained page keeps its wording, and the gate -- a read-only one -- refuses." \
    "- an item in a list takes a marker"

# A tag the same sentence closes is HTML, which prose about markup contains.
silent TEST-PC-93-placeholder-html.md \
    "A tag such as <code>x</code> is markup, so the check reads it as one."

# The scope split, from the side that floods: the same sentence in a source comment is not
# read by the document-only checks, a comment sitting inside the code it describes,
# where an identifier and a path are the grammar of the file.
silent TEST-PC-94-variable-comment.sh 'x=1' '# The unit hands AI_TOOLS_AGENT_EXEC to the shim.'
silent TEST-PC-95-path-comment.sh 'x=1' '# The seeder reads managed-assets.lib.sh from the datadir.'

# A Markdown link's text and its destination are both paths by construction, so the line carrying
# one is measured without it.
silent TEST-PC-96-path-link.md \
    "The conventions are in [docs/naming-conventions.md](docs/naming-conventions.md)."
# The prose readings a path pattern takes if it is loosened: a coordination, a ratio,
# and a sentence-final abbreviation.
silent TEST-PC-97-path-prose.md "The ratio of docs:code stays low, and/or the header is filled, etc."
# A version number ends in a dot and a digit exactly as a man page's filename does.
silent TEST-PC-98-path-version.md "Rocky 9.5 and release 0.16.0 carry one policy."

# A doc comment's contract line is the form this standard prescribes for a shell function,
# so every token in it is the signature rather than prose that forgot its backticks. Each
# branch is driven through the one check that reads it: the fragment key through an option
# in a comment, the signature through a placeholder in a document.
silent TEST-PC-99-contract-fragment.sh \
    'x=1' '# usage: ai-tools-admin operators add --for <name>'
silent TEST-PC-99-contract-signature.md \
    'seed_asset <kind> <name> -- place the shipped asset, and report what it replaced.'

# A roff page's markup is its fonts, held by the man-page lint, and read as raw roff a page
# reports every variable and every path in it.
silent TEST-PC-100-man-page.1 '.TH AI-TOOLS 1' '.B \-\-full' \
    '.I /etc/ai-tools/operator.conf' 'The AI_TOOLS_REQUIRE_SELINUX key is read at launch.'

# An SPDX identifier is a machine-read tag, and joined to the block beneath it would open
# the header's first sentence with a licence expression -- which the contract-line rule then
# exempts, taking the whole header with it.
reports bare-option TEST-PC-101-spdx.sh \
    '# SPDX-License-Identifier: AGPL-3.0-only' '# The claim takes --for and refuses root.'

# A backticked span is what every check reads past, so each way one can be lost is pinned
# here rather than left to whichever check reports first. A span may hold a period of its own,
# and a cut there leaves the span open on both parts, where no later pass matches it.
# shellcheck disable=SC2016
silent TEST-PC-104-span-holds-a-period.md \
    'A refusal reads `ai-tools --project-claim <path>. Claim it with the CLI` and stops.'
# A span glued to the next word by a hyphen was one word, so the separator that replaces it goes
# outside: inserted inside, it hands the option check a leading `-macro`.
# shellcheck disable=SC2016
silent TEST-PC-105-span-glued.md 'The `an`-macro form is read as one word.'
# The same glue with no hyphen: a span carrying an English suffix is one word, and a dash
# placeholder inside it hands the option check a `--s` to report.
# shellcheck disable=SC2016
silent TEST-PC-106-span-suffix.md 'A session that `cat`s the root-owned log keeps reading.'
# A span closes on the run of backticks that OPENED it, which is how a span holds a backtick
# of its own. Paired by single backticks instead, the opener closes on the backtick inside
# the span, and every code reference after it in the sentence is read as prose.
# shellcheck disable=SC2016
silent TEST-PC-107-span-double-backtick.md \
    'A value carrying `` ` `` is passed to `logger` as one argument.'

# ── The regions of a document that are not its author's prose ─────────────────────────────────
#
# A Markdown code block written INDENTED does not carry a marker of its own -- four spaces
# after a blank line -- so a usage document that shows a command in one reports every option
# and path the command carries. Pinned from both sides, because the indent that opens a code
# block outside a list is a continuation line inside one: read too loosely, the exemption takes
# that prose with it, and the second case is what catches that.
silent TEST-PC-108-indented-code.md \
    "Start here -- one command answers it:" "" \
    "    sudo ai-tools --audit --since '2 days ago'" "" \
    "It reads the two trails and reports what refused."
reports bare-option TEST-PC-109-list-continuation.md \
    "- An item whose continuation runs on:" "" \
    "    The launcher takes --full and refuses root."

# Frontmatter is machine-read: a loader's keys, its one-token values, and the set of globs
# a `paths:` list holds. A folded scalar's body is prose and stays, which the second case
# pins -- a shipped asset's description is written to this standard like any other sentence.
silent TEST-PC-110-frontmatter.md \
    "---" "paths:" "  - src/usr/local/lib/ai-tools/msg.lib.sh" "---" \
    "The library wraps a refusal to the terminal width."
reports bare-option TEST-PC-111-frontmatter-body.md \
    "---" "description: >" "  Use where the launcher takes --full and refuses root." "---" \
    "The rule is stated once."

# A URL is machine-read wherever it appears, and its own path and query carry the separators
# every pattern here looks for: the filename a link destination ends in, and the identifier
# a bug-tracker query carries. The second case pins that the exemption stops at the address.
silent TEST-PC-112-url.md \
    "The AV rules are at https://example.org/notebook/src/avc_rules.md and stay current."
reports bare-option TEST-PC-113-url-prose.md \
    "The page at https://example.org/a_b.md says the launcher takes --full."

# A suspended hyphen carries a compound's tail onto the conjunction and is not an option.
# Pinned from both sides: the two marks the exemption needs are the conjunction and the compound,
# and a sentence carrying neither still reports the short options in it.
silent TEST-PC-116-option-suspended-hyphen.md \
    "The ACL makes the whole tree agent-readable and -writable once it is claimed."
reports bare-option TEST-PC-117-option-short-pair.md "Pass -v and -x to the shim."

# A wrapped span may close on a later line, and a continuation line beginning with what the span
# holds -- a `|` alternation reads as a table row -- ends the block inside it, leaving the span
# open on both parts.
# shellcheck disable=SC2016
silent TEST-PC-118-span-wrapped-alternation.md \
    'The logger records one line (`confirm: <question> -> yes|no (answered' \
    '| default | assume-yes)`) for every decision.'

# An absolute root is a directory on its own, so the path that follows it is optional. Pinned
# from both sides: the boundary that admits `/opt` must still refuse a word that merely
# begins with it, or every `/optional` in the tree reads as a path.
reports bare-path TEST-PC-120-path-absolute-root.md "The account is created at /opt, never at /home."
silent TEST-PC-121-path-absolute-word.md "An /optional group is enabled by the operator alone."

# A literal cut by its own backticks leaves the rest of the token outside them, where a rename
# over the marked spans edits one half. Pinned against the two forms it sits beside, since
# each puts an ordinary sentence next to a span: a coordination, and a closing period.
# shellcheck disable=SC2016
reports split-literal TEST-PC-122-split-literal.md \
    'The unit is `/usr/lib/systemd/system/ai-tools-handback`@.service on the host.'
# shellcheck disable=SC2016
silent TEST-PC-123-split-literal-coordination.md \
    'The type keeps it off other domains'"'"' `tmp_t`/`user_tmp_t` files.' \
    'The seeder reads `managed-assets.lib.sh`. It runs as root.'

# A filename is spelled in one case throughout, while a product whose name ends in an extension
# is capitalised. Pinned from both sides: the narrowing that keeps the product name out must
# leave the uppercase filename a repository's own router carries.
silent TEST-PC-114-path-product.md "The updater keeps Node.js current under the account."
reports bare-path TEST-PC-115-path-uppercase.md "The router CLAUDE.md holds the invariants."

# The path roots are a checker option: a shipped tool ships without any repository's layout.
run_check "$(fixture TEST-PC-102-path-roots.md 'The module sits in selinux/policy and loads at boot.')"
omits bare-path "TEST-PC-102-path-roots: a root outside the default set is not a path"
run_check --path-roots selinux/ \
    "$(fixture TEST-PC-103-path-roots-arg.md 'The module sits in selinux/policy and loads at boot.')"
assert_grep bare-path "${OUT}" "TEST-PC-103-path-roots-arg: --path-roots names the root it reports"

# ── Suppression: the explicit marker, and the quoted span a style guide needs ──────────────────
silent TEST-PC-13-allow-marker.md "The label probe is cheap. <!-- prose-check: ignore -->"
# The backticked spans are the content under test, not shell substitutions.
# shellcheck disable=SC2016
silent TEST-PC-14-quoted-span.md \
    'Write `does not take a path argument` rather than the fronted `takes no path`.'
# The file marker takes the whole file out of the report -- what a generated file needs, its text
# being copied from targets it cannot edit. Pinned from both sides, because the two failures are
# not symmetric: read too loosely it silences every document that merely NAMES the marker, and the
# second case is the one that catches that.
silent TEST-PC-77-ignore-file.md \
    "<!-- prose-check: ignore-file -->" "There is nothing left to check." \
    "The helper takes no path argument."
reports nothing TEST-PC-78-ignore-file-named.md \
    "A file carrying <!-- prose-check: ignore-file --> as a line of its own is not read." \
    "There is nothing left to check."

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

    # ── `--staged`: a document's regions, read from the lines a commit adds ────────────────────
    # The pre-commit hook runs this mode, and it is the one gate that is not optional.
    # The frontmatter a rule file opens with must take its own lines out of the report and no
    # more, or a commit adding a rule passes the gate without being read at all.
    printf -- '---\npaths:\n  - src/**\n---\n\nThe launcher takes --full and refuses root.\n' \
        > "${repo}/front.md"
    git -C "${repo}" add front.md
    staged="$(cd "${repo}" && python3 "${PC}" --all --staged 2>&1)" || true
    assert_grep 'bare-option' "${staged}" \
        "TEST-PC-119-staged-frontmatter: an unclosed region does not silence the lines after it"
    git -C "${repo}" -c commit.gpgsign=false commit -qm staged-front

    # ── --new: report only what the working tree ADDS against a revision ───────────────────────
    # The failure it exists to remove is a false one: an edit renumbers every finding after it,
    # and a reader comparing two runs by line then reports each shifted finding as new.
    # The fixture inserts text ahead of two existing figures and appends a third, so a pairing
    # by position reports three where a pairing by content reports one.
    printf 'The account is never an administrator.\nA claim adds nothing here.\n' > "${repo}/new.md"
    git -C "${repo}" add new.md
    git -C "${repo}" -c commit.gpgsign=false commit -qm new-base
    printf 'An inserted line that is plain.\nAnother inserted line, also plain.\n%s\n%s\n%s\n' \
        'The account is never an administrator.' \
        'A claim adds nothing here.' \
        'The helper grants no access.' > "${repo}/new.md"
    added="$(cd "${repo}" && python3 "${PC}" --all --new HEAD new.md 2>&1)" || true
    assert_grep 'grants no access' "${added}" \
        "TEST-PC-39a-new-added: --new reports the figure the edit introduced"
    OUT="${added}"   # `omits` reads it, the same global run_check sets
    omits 'never' \
        "TEST-PC-39b-new-shifted: a finding that only moved down the file is not reported"
    omits 'nothing' \
        "TEST-PC-39c-new-shifted-second: neither is the second one the insert displaced"

    # An edited sentence that still reports counts as NEW, its text no longer matching the one
    # it replaced: the wording a branch leaves behind is the wording it is answerable for.
    printf 'An inserted line that is plain.\nAnother inserted line, also plain.\n%s\n%s\n%s\n' \
        'The service account is never an administrator.' \
        'A claim adds nothing here.' \
        'The helper grants no access.' > "${repo}/new.md"
    added="$(cd "${repo}" && python3 "${PC}" --all --new HEAD new.md 2>&1)" || true
    assert_grep 'The service account' "${added}" \
        "TEST-PC-39d-new-edited: a sentence reworded and still reporting counts as new"

    # A path the revision does not hold has no baseline, so every finding in it is the tree's.
    printf 'The helper grants no access.\n' > "${repo}/fresh.md"
    added="$(cd "${repo}" && python3 "${PC}" --all --new HEAD fresh.md 2>&1)" || true
    assert_grep 'grants no access' "${added}" \
        "TEST-PC-39e-new-absent: a file the revision lacks reports every finding in it"

    # The filter needs paths: --staged and --message name no path to read at a revision.
    if ( cd "${repo}" && python3 "${PC}" --new HEAD >/dev/null 2>&1 ); then
        fail "TEST-PC-39f-new-needs-paths: --new with no path was accepted"
    else
        pass "TEST-PC-39f-new-needs-paths: --new with no path is refused"
    fi
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
