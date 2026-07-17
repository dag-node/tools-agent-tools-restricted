#!/usr/bin/env bash
# Enforce the release-metadata invariant: packaging/VERSION, the newest %changelog entry in
# ai-tools.spec, and — when a tag argument is given — the release tag all name the same
# version. A version bump therefore cannot ship without a matching %changelog entry, and a
# tag cannot publish against a stale VERSION. Fail-closed: any mismatch exits non-zero.
#
# Usage:
#   packaging/check-version.sh                 # VERSION == newest %changelog entry
#   packaging/check-version.sh vX.Y.Z          # also: tag (v-stripped) == VERSION  (release/CI)
#   packaging/check-version.sh vX.Y.Z-rc.N     # base X.Y.Z == VERSION; %changelog match relaxed
#                                              # (RC notes aren't finalized; the final tag gates them)
#
# Errors use the ::error:: prefix so GitHub Actions surfaces them as annotations; the text
# reads plainly on a local terminal too.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version_file="${here}/VERSION"
spec="${here}/ai-tools.spec"

file_version="$(cat "${version_file}")"

# Parse the tag argument up front: a prerelease tag (vX.Y.Z-rc.N, the only dashed shape
# accepted) compares by its base X.Y.Z and relaxes the %changelog match below.
tag="${1:-}"
tag_version=""
prerelease=0
if [[ -n "${tag}" ]]; then
    tag_version="${tag#v}"
    if [[ "${tag_version}" == *-* ]]; then
        if [[ ! "${tag_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
            echo "::error::prerelease tag ${tag} is not vX.Y.Z-rc.N" >&2
            exit 1
        fi
        prerelease=1
        tag_version="${tag_version%%-*}"
    fi
fi

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
    if [[ "${prerelease}" -eq 1 ]]; then
        echo "note: newest %changelog entry (${head_version}) does not match packaging/VERSION (${file_version}) -- allowed for an RC tag; the final vX.Y.Z tag requires the match"
    else
        echo "::error::newest %changelog entry (${head_version}) does not match packaging/VERSION (${file_version}) -- add a '${file_version}-1' %changelog entry before tagging" >&2
        rc=1
    fi
fi

if [[ -n "${tag}" && "${tag_version}" != "${file_version}" ]]; then
    echo "::error::tag ${tag} does not match packaging/VERSION (${file_version}) -- bump the file and re-tag" >&2
    rc=1
fi

if [[ "${rc}" -eq 0 ]]; then
    echo "version check ok: VERSION=${file_version}, %changelog head=${head_version}${tag:+, tag=${tag}}"
fi
exit "${rc}"
