#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Draft MATERIAL for a %changelog block from the Conventional-Commit subjects since the last
# stable release. It removes the blank-page burden and does not replace the editing pass: it
# does not write a file and does not stage a change.
#
# What it prints is one line per commit, which is NOT what ships. A changelog is grouped by what
# the operator gained, not by commit -- a feature built over nine commits is one entry, and a
# commit that only moved code is none -- so the block that ships is shorter than this draft and
# is reconciled once, before the release. Writing an entry per merge during development produces
# a commit log with headings.
#
# stdout is the draft; stderr carries the guidance and the commits that usually earn no entry,
# so a redirect captures the draft alone.
#
# CATEGORIES. An RPM %changelog is still a changelog -- the packaging format does not prescribe
# any vocabulary of its own, so Keep a Changelog's categories apply here, spelled as this spec's
# uppercase bullet prefixes:
#   NEW:       a capability the operator did not have         (ADDED)
#   CHANGE:    behaviour that differs on upgrade              (CHANGED / REMOVED / DEPRECATED)
#   SECURITY:  the operator's exposure changes, either way    (SECURITY)
#   FIX:       a defect the operator may have hit             (FIXED)
#   DOCS:      operator-facing documentation only
#   LICENSE:   licensing or distribution terms
# A breaking change is a CHANGE: that names the action to take ("Update any script that ..."),
# since this spec has never carried a separate BREAKING prefix.
#
# ORDER. What may cost the reader comes first -- breaking CHANGE, then SECURITY -- because the
# main reason to scan a changelog is to find those. Gains follow (NEW), then FIX by severity,
# then DOCS, so the block still reads forward rather than as a defect list. Do not end on a
# failure sentence.
#
# WRITING AN ENTRY. The full standard is the ai-tools-technical-docs skill, change-docs section;
# what it comes down to here: one or two sentences, what the operator gains or must do rather
# than how it was built, a rule or lib named only where that makes the entry shorter, and the
# gain stated plainly -- an operator deciding whether to upgrade wants the fact, and an entry
# that sounds sold reads as less trustworthy. Version bumps, tests, refactors, formatting and CI
# earn no entry.
#
# GROUPING is the pass this tool exists to feed, and a subject line rarely carries enough to do
# it: the reader-facing why lives in the commit BODY, which is where two commits reveal
# themselves as one entry. Run --material for those, and when a body still leaves it unclear,
# read the change itself (git show <sha>) rather than guessing from the subject.
#
# Reading more does NOT mean writing more. The material is long so the entry can be short: the
# bodies are read to decide what groups with what, then summarized in a sentence or two. Every
# detail stays where it already is -- in the commit message and the commit itself -- and an entry
# that reproduces it has copied the wrong thing.
#
# Usage:
#   packaging/changelog-draft.sh             bullets for packaging/VERSION, paste-ready
#   packaging/changelog-draft.sh --material  the same commits with bodies and touched files
#   packaging/changelog-draft.sh --check     lint the newest block already in ai-tools.spec
#   packaging/changelog-draft.sh --check --all   ... and every released block, as a summary
#   (or: make -C packaging changelog)
#
# Order of work: --material to group, write the block, --check to lint it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
spec="${here}/ai-tools.spec"

# The prefixes an entry may carry. Read by both modes: the draft assigns one, --check refuses
# anything outside the set, so a sixth category is added here rather than invented per release.
readonly CATEGORIES='NEW|CHANGE|FIX|SECURITY|DOCS|LICENSE'
# An entry longer than this many lines has stopped being one or two sentences. Advisory: --check
# reports and never fails, since a genuinely complex upgrade step can earn the space.
readonly MAX_ENTRY_LINES=5

# ── --check [--all]: lint the newest block, or every released block ──────────────────────────
# Default is the newest block, the one being written. --all sweeps the history too: a shipped
# entry is the public record of that release, so what it reports is a reading list rather than
# a work list.
if [[ "${1:-}" == "--check" ]]; then
    awk -v cats="${CATEGORIES}" -v maxlines="${MAX_ENTRY_LINES}" -v all="${2:-}" '
        /^%changelog/ { in_log = 1; next }
        !in_log { next }
        /^\* / {
            if (seen_header) { if (all != "--all") exit; if (entry != "") check(); entry = "" ; report() }
            seen_header = 1; header = $0; next
        }
        !seen_header { next }
        /^- / {
            if (entry != "") check()
            entry = $0; lines = 1
            next
        }
        { if (entry != "") lines++ }
        function check(   pfx) {
            n++
            if (match(entry, /^- [A-Z]+:/)) {
                pfx = substr(entry, 3, RLENGTH - 3)
                if (pfx !~ "^(" cats ")$") {
                    printf "  unknown category %s: on %s\n", pfx, snippet(entry) > "/dev/stderr"; bad++
                }
            } else {
                printf "  no category prefix: %s\n", snippet(entry) > "/dev/stderr"; bad++
            }
            if (lines > maxlines) {
                printf "  %d lines (over %d), review for length: %s\n", lines, maxlines, snippet(entry) > "/dev/stderr"
                long++
            }
        }
        function snippet(s) { return substr(s, 1, 72) (length(s) > 72 ? "..." : "") }
        function report(   tag) {
            tag = header; sub(/^\* [^ ]+ [^ ]+ [^ ]+ [^ ]+ /, "", tag)
            printf "%-28s %3d entries, %d uncategorized, %d over %d lines\n", tag, n, bad+0, long+0, maxlines > "/dev/stderr"
            tot_n += n; tot_bad += bad; tot_long += long; blocks++
            n = 0; bad = 0; long = 0
        }
        END {
            if (entry != "") check()
            report()
            if (all == "--all")
                printf "%d blocks, %d entries, %d uncategorized, %d over %d lines\n", blocks, tot_n, tot_bad+0, tot_long+0, maxlines > "/dev/stderr"
        }
    ' "${spec}"
    exit 0
fi

version="$(cat "${here}/VERSION")"

# Anchor on the newest STABLE tag (vX.Y.Z) reachable from HEAD, excluding the vX.Y.Z-rc.N
# prereleases cut during stabilization: a final %changelog entry spans everything since the
# last release, not just since the last RC. With no stable tag yet, span all history.
anchor="$(git -C "${here}" describe --tags --abbrev=0 --match 'v*' --exclude '*-*' 2>/dev/null || true)"
range="${anchor:+${anchor}..}HEAD"

# Attribute the draft to the packager already named in the spec's %changelog (the identity the
# entry will be pasted next to), not the committer's git identity. Fall back to git config only
# when the spec does not carry an entry yet.
packager="$(awk '
    /^%changelog/ { in_log = 1; next }
    in_log && /^\*/ {
        line = $0
        sub(/^\* +/, "", line)                        # drop the "* " bullet
        sub(/ - [^ ]+$/, "", line)                    # drop the trailing " - X.Y.Z-R"
        sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", line)  # drop the four date tokens
        print line
        exit
    }
' "${spec}")"
if [[ -z "${packager}" ]]; then
    packager="$(git -C "${here}" config user.name || echo 'YOUR NAME') <$(git -C "${here}" config user.email || echo 'you@example.com')>"
fi
date="$(LC_ALL=C date +'%a %b %d %Y')"

# Ordered so a reader scanning the block meets what may cost them first. Breaking changes are
# CHANGE: entries and lead it, which is what keeps them in one place.
# classify <subject> -> sets CAT (the bullet prefix) and DESC (the subject minus its type).
# Shared by both modes, so --material files a commit exactly where the draft would.
CAT=""; DESC=""
classify() {
    local subject="$1" type scope bang
    if [[ "${subject}" =~ ^([a-z]+)(\(([^\)]*)\))?(!)?:[[:space:]]+(.*)$ ]]; then
        type="${BASH_REMATCH[1]}"; scope="${BASH_REMATCH[3]}"
        bang="${BASH_REMATCH[4]}"; DESC="${BASH_REMATCH[5]}"
    else
        type="other"; scope=""; bang=""; DESC="${subject}"
    fi
    # A security entry is a judgement the author makes, so this only NOMINATES: a security scope,
    # or a CVE in the subject. Everything else lands in its type's category for the author to
    # re-file, which is the safe direction -- a missed nomination is edited in, while an automatic
    # SECURITY: on an unrelated commit would be published as one.
    if [[ "${scope}" == "security" || "${DESC}" =~ CVE-[0-9]{4}-[0-9]+ ]]; then CAT="SECURITY"; return; fi
    if [[ -n "${bang}" ]]; then CAT="BREAKING"; return; fi
    case "${type}" in
        feat)                              CAT="NEW" ;;
        fix)                               CAT="FIX" ;;
        perf|revert)                       CAT="CHANGE" ;;
        docs)                              CAT="DOCS" ;;
        refactor|chore|ci|build|test|style) CAT="CHURN" ;;
        *)                                 CAT="CHANGE" ;;
    esac
}

# ── --material: the same commits with the bodies and files the grouping pass needs ───────────
if [[ "${1:-}" == "--material" ]]; then
    for want in BREAKING SECURITY NEW CHANGE FIX DOCS CHURN; do
        printed=0
        while IFS= read -r -d $'\x1e' rec; do
            rec="${rec#"${rec%%[![:space:]]*}"}"   # git leaves the record's trailing LF on the next one
            [[ -z "${rec}" ]] && continue
            sha="${rec%%$'\x1f'*}"; rest="${rec#*$'\x1f'}"
            subject="${rest%%$'\x1f'*}"; body="${rest#*$'\x1f'}"
            classify "${subject}"
            [[ "${CAT}" == "${want}" ]] || continue
            (( printed++ )) || printf '\n=== %s ===\n' "${want}"
            printf '\n  %s  [%s]\n' "${subject}" "${sha:0:9}"
            # Trailers are commit plumbing, not reader-facing why -- drop them from the material.
            [[ -n "${body//[[:space:]]/}" ]] && printf '%s\n' "${body}" \
                | sed -E '/^(Co-Authored-By|Signed-off-by|Co-authored-by):/d' \
                | sed 's/^/    /' | sed '/^ *$/d'
            printf '    files: %s\n' "$(git -C "${here}" show --pretty= --name-only "${sha}" | paste -sd' ' - | cut -c1-300)"
        done < <(git -C "${here}" log --no-merges --reverse --format=$'%H\x1f%s\x1f%b\x1e' "${range}")
    done
    {
        echo
        echo "--- MATERIAL for ${version} from ${range} ---"
        echo "Group by what the operator gained: several commits fold into one entry, and a commit that"
        echo "only moved code earns none. Where a body still leaves the grouping unclear, read the change:"
        echo "  git show <sha>"
        echo
        echo "Then summarize. The bodies above are input to the grouping, not text to condense into the"
        echo "entry: each entry is a sentence or two on what the operator gained or must do, and the"
        echo "detail stays here, in the commits."
    } >&2
    exit 0
fi

declare -a breaking=() security=() new=() change=() fix=() docs=() churn=()
while IFS= read -r subject; do
    [[ -z "${subject}" ]] && continue
    classify "${subject}"
    case "${CAT}" in
        BREAKING) breaking+=("${DESC}") ;;
        SECURITY) security+=("${DESC}") ;;
        NEW)      new+=("${DESC}") ;;
        CHANGE)   change+=("${DESC}") ;;
        FIX)      fix+=("${DESC}") ;;
        DOCS)     docs+=("${DESC}") ;;
        CHURN)    churn+=("${DESC}") ;;
    esac
done < <(git -C "${here}" log --no-merges --format='%s' "${range}")

emit() { local d prefix="$1"; shift; for d in "$@"; do printf -- '- %s%s\n' "${prefix}" "${d}"; done; }

echo "* ${date} ${packager} - ${version}-1"
((${#breaking[@]})) && emit "CHANGE: [BREAKING -- name the action to take] " "${breaking[@]}"
((${#security[@]})) && emit "SECURITY: " "${security[@]}"
((${#new[@]}))      && emit "NEW: "      "${new[@]}"
((${#change[@]}))   && emit "CHANGE: "   "${change[@]}"
((${#fix[@]}))      && emit "FIX: "      "${fix[@]}"
((${#docs[@]}))     && emit "DOCS: "     "${docs[@]}"

{
    echo "--- DRAFT MATERIAL for ${version} from ${range} (${anchor:-repo start}..HEAD) ---"
    if ((${#churn[@]})); then
        echo "Left out (${#churn[@]} commits whose type usually earns no entry -- promote any that changed what an operator sees):"
        printf '  %s\n' "${churn[@]}"
    fi
    echo "Each line above is one COMMIT subject. Consolidate them into entries by what the operator"
    echo "gained: several commits fold into one, and the block you paste is shorter than this."
    echo "Then run: packaging/changelog-draft.sh --check"
} >&2
