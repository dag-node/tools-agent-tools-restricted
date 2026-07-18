#!/usr/bin/env bash
# Draft a %changelog block for the current packaging/VERSION from the Conventional-Commit
# subjects since the last stable release, grouped by impact. Prints to stdout for the author to
# CURATE before pasting into ai-tools.spec -- a changelog is not a commit log: prune
# no-user-impact commits and rewrite subjects into reader-facing, upgrade-oriented prose
# (see the change-docs standard). This removes the blank-page burden; it does not replace the
# editing pass. It writes nothing and stages nothing.
#
# Usage: packaging/changelog-draft.sh   (or: make -C packaging changelog)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
spec="${here}/ai-tools.spec"
version="$(cat "${here}/VERSION")"

# Anchor on the newest STABLE tag (vX.Y.Z) reachable from HEAD, excluding the vX.Y.Z-rc.N
# prereleases cut during stabilization: a final %changelog entry spans everything since the
# last release, not just since the last RC. With no stable tag yet, span all history.
anchor="$(git -C "${here}" describe --tags --abbrev=0 --match 'v*' --exclude '*-*' 2>/dev/null || true)"
range="${anchor:+${anchor}..}HEAD"

# Attribute the draft to the packager already named in the spec's %changelog (the identity the
# entry will be pasted next to), not the committer's git identity. Fall back to git config only
# when the spec carries no entry yet.
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

echo "* ${date} ${packager} - ${version}-1"
((${#breaking[@]})) && emit "BREAKING: " "${breaking[@]}"
((${#feat[@]}))     && emit "" "${feat[@]}"
((${#fix[@]}))      && emit "" "${fix[@]}"
((${#perf[@]}))     && emit "" "${perf[@]}"
((${#other[@]}))    && emit "" "${other[@]}"

echo >&2 "--- DRAFT for ${version} from ${range} (${anchor:-repo start}..HEAD) ---"
echo >&2 "Curate before committing: drop no-user-impact lines, rewrite into upgrade-oriented prose, order by impact."
