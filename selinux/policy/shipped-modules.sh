#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# selinux/policy/shipped-modules.sh -- print the policy modules a release ships, one name per line.
#
# The one derivation of the shipped set: the core (ai_tools), ai_tools_<group> for each STABLE
# group in selinux-groups.lib.sh, and the layout module each integration manifest declares
# (selinux_layout_module, ai-tools-providers(5)). The spec's %build compiles this list against
# the building distribution's policy headers and %install stages it; install.sh compiles and
# stages the same list from a checkout (through install-selinux.sh build); the tests hold the
# built package and the installed host to it. No module name is spelled anywhere else, so
# promoting a group edits the registry and adding a layout module edits a manifest.
#
# Lives beside the policy sources and carries their licence: it names what the policy build
# compiles, which makes it a script controlling compilation and so part of the corresponding
# source of every module the ai-tools-selinux package conveys (GPLv2 s.3).
#
# Usage: bash selinux/policy/shipped-modules.sh [<integrations.d directory>]
#   The manifests default to this checkout's src/usr/local/lib/ai-tools/integrations.d, the set
#   a release ships. The registry is read from the checkout too, falling back to the installed
#   copy. Prints nothing and fails when the registry cannot be sourced.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${1:-${DIR}/../../src/usr/local/lib/ai-tools/integrations.d}"

GROUPS_LIB="${DIR}/../../src/usr/local/lib/ai-tools/selinux-groups.lib.sh"
[[ -r "${GROUPS_LIB}" ]] || GROUPS_LIB="/usr/local/lib/ai-tools/selinux-groups.lib.sh"
# shellcheck source=/dev/null
source "${GROUPS_LIB}" \
    || { printf 'shipped-modules: cannot source the group registry %s\n' "${GROUPS_LIB}" >&2; exit 1; }

printf 'ai_tools\n'
for entry in "${AI_TOOLS_SELINUX_GROUPS[@]}"; do
    [[ "$(ai_tools_selinux_group_stability "${entry}")" == stable ]] || continue
    printf 'ai_tools_%s\n' "$(ai_tools_selinux_group_name "${entry}")"
done
# One layout module per manifest, the last assignment winning as in the parser the tooling uses;
# a value that is not a plain ai_tools_<name> token is dropped, as the selinux %post drops it.
for manifest in "${MANIFESTS}"/*.conf; do
    [[ -f "${manifest}" ]] || continue
    module="$(sed -n 's/^[[:space:]]*selinux_layout_module[[:space:]]*=[[:space:]]*"\{0,1\}\([A-Za-z0-9_]*\).*/\1/p' "${manifest}" | tail -1)"
    [[ "${module}" =~ ^ai_tools_[a-z][a-z0-9_]*$ ]] || continue
    printf '%s\n' "${module}"
done | sort -u
