#!/usr/bin/env bash
# Enforce the release-metadata invariant: packaging/VERSION, the newest %changelog entry in
# ai-tools.spec, and — when a tag argument is given — the release tag all name the same
# version. A version bump therefore cannot ship without a matching %changelog entry, and a
# tag cannot publish against a stale VERSION. Fail-closed: any mismatch exits non-zero.
#
# Usage:
#   packaging/check-version.sh            # VERSION == newest %changelog entry
#   packaging/check-version.sh vX.Y.Z     # also: tag (v-stripped) == VERSION  (release/CI)
#
# Errors use the ::error:: prefix so GitHub Actions surfaces them as annotations; the text
# reads plainly on a local terminal too.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_file="${here}/VERSION"
spec="${here}/ai-tools.spec"

file_version="$(cat "${version_file}")"

# Newest changelog entry: the first "* <date> <author> - X.Y.Z-R" header after %changelog.
# Split the header on " - " and take the trailing "X.Y.Z-R" field, then drop the -R release.
head_version="$(awk '
    /^%changelog/ { in_log = 1; next }
    in_log && /^\*/ {
        n = split($0, parts, " - ")
        v = parts[n]
        sub(/-.*/, "", v)
        print v
        exit
    }
' "${spec}")"

rc=0
if [[ -z "${head_version}" ]]; then
    echo "::error::no %changelog entry found in ${spec}" >&2
    rc=1
elif [[ "${head_version}" != "${file_version}" ]]; then
    echo "::error::newest %changelog entry (${head_version}) does not match packaging/VERSION (${file_version}) -- add a '${file_version}-1' %changelog entry before tagging" >&2
    rc=1
fi

if [[ -n "${1:-}" ]]; then
    tag_version="${1#v}"
    if [[ "${tag_version}" != "${file_version}" ]]; then
        echo "::error::tag ${1} does not match packaging/VERSION (${file_version}) -- bump the file and re-tag" >&2
        rc=1
    fi
fi

if [[ "${rc}" -eq 0 ]]; then
    echo "version check ok: VERSION=${file_version}, %changelog head=${head_version}${1:+, tag=${1}}"
fi
exit "${rc}"
