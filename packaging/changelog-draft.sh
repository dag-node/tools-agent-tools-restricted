#!/usr/bin/env bash
# Draft a %changelog block for the current packaging/VERSION from the Conventional-Commit
# subjects since the last vX.Y.Z tag, grouped by impact. Prints to stdout for the author to
# CURATE before pasting into ai-tools.spec -- a changelog is not a commit log: prune
# no-user-impact commits and rewrite subjects into reader-facing, upgrade-oriented prose
# (see the change-docs standard). This removes the blank-page burden; it does not replace the
# editing pass. It writes nothing and stages nothing.
#
# Usage: packaging/changelog-draft.sh   (or: make -C packaging changelog)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(cat "${here}/VERSION")"

# Anchor on the newest vX.Y.Z tag reachable from HEAD; with no tag yet, span all history.
anchor="$(git -C "${here}" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
range="${anchor:+${anchor}..}HEAD"

name="$(git -C "${here}" config user.name || echo 'YOUR NAME')"
email="$(git -C "${here}" config user.email || echo 'you@example.com')"
date="$(LC_ALL=C date +'%a %b %d %Y')"

declare -a breaking=() feat=() fix=() perf=() other=()
while IFS= read -r subject; do
    [[ -z "${subject}" ]] && continue
    # Conventional Commit header: type(scope)!: description
    if [[ "${subject}" =~ ^([a-z]+)(\([^\)]*\))?(!)?:[[:space:]]+(.*)$ ]]; then
        type="${BASH_REMATCH[1]}"; bang="${BASH_REMATCH[3]}"; desc="${BASH_REMATCH[4]}"
    else
        type="other"; bang=""; desc="${subject}"
    fi
    if [[ -n "${bang}" ]]; then breaking+=("${desc}"); continue; fi
    case "${type}" in
        feat) feat+=("${desc}") ;;
        fix)  fix+=("${desc}") ;;
        perf) perf+=("${desc}") ;;
        *)    other+=("${desc}") ;;
    esac
done < <(git -C "${here}" log --no-merges --format='%s' "${range}")

emit() { local d prefix="$1"; shift; for d in "$@"; do printf -- '- %s%s\n' "${prefix}" "${d}"; done; }

echo "* ${date} ${name} <${email}> - ${version}-1"
((${#breaking[@]})) && emit "BREAKING: " "${breaking[@]}"
((${#feat[@]}))     && emit "" "${feat[@]}"
((${#fix[@]}))      && emit "" "${fix[@]}"
((${#perf[@]}))     && emit "" "${perf[@]}"
((${#other[@]}))    && emit "" "${other[@]}"

echo >&2 "--- DRAFT for ${version} from ${range} (${anchor:-repo start}..HEAD) ---"
echo >&2 "Curate before committing: drop no-user-impact lines, rewrite into upgrade-oriented prose, order by impact."
