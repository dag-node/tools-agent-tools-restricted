#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/assets.sh
# Unit test for the assets resolver (assets.lib.sh): the runtime half of every refusal its predicate table names,
# and the view transaction's guarantees. Drives ai_tools_assets_reconcile over sets signed in the run with a throwaway
# key (tests/lib/asset-signing.sh), through the root-only hooks -- AI_TOOLS_ASSETS_ROOTS, AI_TOOLS_ASSETS_BINDINGS_DIR,
# AI_TOOLS_ASSETS_LOCK, AI_TOOLS_ASSETS_HOME, AI_TOOLS_OPERATOR_CONF, AI_TOOLS_AGENTS_DIR, AI_TOOLS_INTEGRATIONS_DIR --
# at fixtures in its testdir, and asserts each case on the record stream (one row per entry, its finding the reason
# token) and on the links left behind. Each refusal leaves the asset out of the view and out of every agent's directory;
# the control beside it links. The boundary half is tests/boundary/assets.sh. Fixtures are the synthetic set `acme`
# and the agents `acme`, `beta` and `gamma`. Run as root via sudo: every input the resolver trusts is root-owned,
# so the fixtures are born root's.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/assets.lib.sh"
[[ -r "${LIB}" ]] || LIB="${CHECKOUT}/src/usr/local/lib/ai-tools/assets.lib.sh"
MANAGED_LIB="${LIB%/*}/managed-assets.lib.sh"
section "assets: the resolver and the view transaction (unit)"
note "library" "${LIB}"

# Every function this file calls, checked before the first case: an absent one exits 127, which a refusal case would
# read as a correct refusal, so a library older than this test stops here.
# shellcheck disable=SC2016  # the $1 is the inner shell's
if ! bash -c 'source "$1" 2>/dev/null && declare -F ai_tools_assets_reconcile ai_tools_assets_plan \
        ai_tools_assets_validate_set ai_tools_assets_plan_set ai_tools_assets_parse_id >/dev/null' _ "${LIB}"; then
    fail "${LIB} does not load or lacks a function this test calls; reinstall from this checkout (sudo ./install.sh)"
    finish; exit 1
fi
for tool in gpg gpgv flock; do
    command -v "${tool}" >/dev/null 2>&1 || { skip "assets" "${tool} is not installed"; finish; exit 0; }
done
# shellcheck source=/dev/null
source "${LIB%/*}/assets-verify.lib.sh"

mktestdir
LOCAL="${TESTDIR}/local"; PKG="${TESTDIR}/pkg"; BASE="${TESTDIR}/base"
KEYS="${TESTDIR}/keys"; BINDINGS="${TESTDIR}/bindings.d"; HOME_DIR="${TESTDIR}/home"
AGENTS_D="${TESTDIR}/agents.d"; INTEG_D="${TESTDIR}/integrations.d"; CONF="${TESTDIR}/operator.conf"
LOCK="${TESTDIR}/lock/assets.lock"
mkdir -p "${LOCAL}" "${PKG}" "${BASE}" "${KEYS}" "${BINDINGS}" "${AGENTS_D}" "${INTEG_D}" \
    "${HOME_DIR}/.acme" "${HOME_DIR}/.beta" "${HOME_DIR}/.gamma"
chmod 0755 "${LOCAL}" "${PKG}" "${BASE}" "${KEYS}" "${BINDINGS}" "${AGENTS_D}" "${INTEG_D}" "${HOME_DIR}" \
    "${HOME_DIR}"/.acme "${HOME_DIR}"/.beta "${HOME_DIR}"/.gamma
export ASSET_KEYS_DIR="${KEYS}" ASSET_BINDINGS_DIR="${BINDINGS}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/asset-signing.sh"
HOOKS=( "AI_TOOLS_ASSETS_ROOTS=${LOCAL} ${PKG} ${BASE}" "AI_TOOLS_ASSETS_BINDINGS_DIR=${BINDINGS}"
        "AI_TOOLS_ASSETS_LOCK=${LOCK}" "AI_TOOLS_ASSETS_HOME=${HOME_DIR}" "AI_TOOLS_OPERATOR_CONF=${CONF}"
        "AI_TOOLS_AGENTS_DIR=${AGENTS_D}" "AI_TOOLS_INTEGRATIONS_DIR=${INTEG_D}" "AI_TOOLS_VERSION=0.24.0" )

# manifest <name> <line>... : an agent manifest, root-owned 0644.
manifest() {
    local name="$1"; shift
    printf 'npm_package=@fixture/%s\nlauncher=%s\nconfig_dir=.%s\ndefault_enable=no\n' "${name}" "${name}" "${name}" \
        > "${AGENTS_D}/${name}.conf"
    printf '%s\n' "$@" >> "${AGENTS_D}/${name}.conf"
    chmod 0644 "${AGENTS_D}/${name}.conf"
}
manifest acme skills_dir=skills subagents_dir=agents \
    "asset_profiles=[skills.portable.v1, skills.dynamic.v1, subagents.claude.v1]"
manifest beta skills_dir=skills "asset_profiles=[skills.portable.v1]"
manifest gamma
printf 'default_enable=no\n' > "${INTEG_D}/dotnet.conf"; chmod 0644 "${INTEG_D}/dotnet.conf"

# write_conf <entry>... : operator.conf enabling AGENTS_LINE's agents and INTEG_LINE's integrations and listing
# the entries in AI_TOOLS_ASSETS, root-owned 0644.
AGENTS_LINE="agent-acme"; INTEG_LINE=""
write_conf() {
    local entries="" entry
    for entry in "$@"; do entries+="${entries:+, }${entry}"; done
    {
        printf 'AI_TOOLS_AGENTS=[%s]\n' "${AGENTS_LINE}"
        [[ -n "${INTEG_LINE}" ]] && printf 'AI_TOOLS_INTEGRATIONS=[%s]\n' "${INTEG_LINE}"
        printf 'AI_TOOLS_ASSETS=[%s]\n' "${entries}"
    } > "${CONF}"
    chown root:root "${CONF}"; chmod 0644 "${CONF}"
}

# reconcile [NAME=value...] : run ai_tools_assets_reconcile in a fresh shell with the hooks (and any override given),
# keeping the record stream in OUT, stderr in ERR, and the status the verb takes in RC: 1 for a write that failed, else
# the stream's exit. PRELUDE, when set, is evaluated in that shell after the library loads, to stub what a case drives;
# a case sets it for one call and clears it.
OUT=""; ERR=""; RC=0; PRELUDE=""
reconcile() {
    RC=0
    # shellcheck disable=SC2016
    OUT="$(env "${HOOKS[@]}" "$@" bash -c 'source "$1" || exit 99; eval "$2"; failed=0
        ai_tools_assets_reconcile root || failed=1
        status=0; ai_tools_records_get_exit_status || status=$?
        (( failed )) && exit 1; exit "${status}"' _ "${LIB}" "${PRELUDE:-:}" 2>"${TESTDIR}/err")" || RC=$?
    ERR="$(<"${TESTDIR}/err")"
}
# has_row_at <severity> <finding> : succeed when a row carries <finding> at <severity>.
has_row_at() { awk -F'\t' -v s="$1" -v f="$2" 'NR > 1 && $5 == s && $6 == f { found = 1 } END { exit !found }' <<< "${OUT}"; }
# finding <id> : the finding of the first row whose item carries <id>, from OUT.
finding() { awk -F'\t' -v id="$1" 'NR > 1 && index($9, id) { print $6; exit }' <<< "${OUT}"; }
# detail <id> : that row's detail.
detail() { awk -F'\t' -v id="$1" 'NR > 1 && index($9, id) { print $11; exit }' <<< "${OUT}"; }
# has_row <finding> [substring] : succeed when a row carries <finding> and, if given, <substring> in its subject.
has_row() { awk -F'\t' -v f="$1" -v s="${2:-}" 'NR > 1 && $6 == f && index($10, s) { found = 1 } END { exit !found }' <<< "${OUT}"; }

# expect_state <id> <token> <what> : the entry's row carries <token>.
expect_state() {
    local got
    got="$(finding "$1")"
    if [[ "${got}" == "$2" ]]; then pass "$3 -> $2"; else fail "$3 -> got '${got}', want $2: $(detail "$1") ${ERR:0:200}"; fi
}
# expect_detail <id> <substring> <what> : the entry's detail names <substring>.
expect_detail() {
    if [[ "$(detail "$1")" == *"$2"* ]]; then pass "$3"; else fail "$3: detail is '$(detail "$1")'"; fi
}
# linked <kind>/<view-name> <target> : the view entry is a link to <target>.
linked() { [[ -L "${HOME_DIR}/$1" && "$(readlink -- "${HOME_DIR}/$1")" == "$2" ]]; }
# absent <path> : no entry at <path>, not even a dangling link.
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
# expect_unlinked <kind>/<view-name> <what> : the view and the agent acme's directory do not hold the asset.
expect_unlinked() {
    local agent_dir="${HOME_DIR}/.acme/skills"
    [[ "$1" == subagents/* ]] && agent_dir="${HOME_DIR}/.acme/agents"
    if absent "${HOME_DIR}/$1" && absent "${agent_dir}/${1#*/}"; then
        pass "$2: no link in the view or the agent's directory"
    else
        fail "$2: a link is left at ${HOME_DIR}/$1 or ${agent_dir}/${1#*/}"
    fi
}

SKILL="acme/skills/acme-pdf"; SUB="acme/subagents/acme-reviewer"
asset_signing_gen_key SIGNER signer
asset_signing_gen_key OTHER other
asset_signing_write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
asset_signing_write_binding acme-two "${KEYS}/signer.gpg" "openpgp:${SIGNER}"

# fresh : the control state every case starts from: acme built in the packaged root alone, both its assets enabled
# for the agent acme, linked by one reconcile.
fresh() {
    rm -rf "${LOCAL:?}"/* "${PKG:?}"/* "${HOME_DIR}/skills" "${HOME_DIR}/subagents" "${HOME_DIR}"/.acme/* \
        "${HOME_DIR}"/.beta/* "${HOME_DIR}"/.gamma/*
    AGENTS_LINE="agent-acme"; INTEG_LINE=""
    asset_signing_build_set "${PKG}" acme
    write_conf "${SKILL}" "${SUB}"
    reconcile
}

# ── The control ──────────────────────────────────────────────────────────────────────────────────────────────────────
fresh
if [[ "${RC}" == 0 ]] && linked skills/acme-pdf "${PKG}/acme/skills/acme-pdf" \
        && linked subagents/acme-reviewer.md "${PKG}/acme/agents/acme-reviewer.md"; then
    pass "control: a verified, valid set links each enabled asset into the view, exit 0"
else
    fail "control: rc ${RC}, view $(ls -la "${HOME_DIR}/skills" 2>&1 | tr '\n' '|'); ${ERR:0:300}"
fi
expect_state "${SKILL}" linked "control: the skill's row"
if [[ "$(readlink -- "${HOME_DIR}/.acme/skills/acme-pdf")" == "${HOME_DIR}/skills/acme-pdf" \
        && "$(readlink -- "${HOME_DIR}/.acme/agents/acme-reviewer.md")" == "${HOME_DIR}/subagents/acme-reviewer.md" ]]; then
    pass "control: the enabled agent's directories link into the view"
else
    fail "control: the agent's links are $(ls -la "${HOME_DIR}/.acme/skills" "${HOME_DIR}/.acme/agents" 2>&1 | tr '\n' '|')"
fi
if [[ "$(stat -c %U:%G "${HOME_DIR}/skills/acme-pdf" 2>/dev/null)" == root:root ]]; then
    pass "control: a view link is root-owned"
else
    fail "control: the view link is $(stat -c %U:%G "${HOME_DIR}/skills/acme-pdf" 2>&1)"
fi
reconcile
if [[ "${RC}" == 0 ]] && ! awk -F'\t' 'NR > 1 && $5 == "info" { found = 1 } END { exit !found }' <<< "${OUT}"; then
    pass "control: a second run over unchanged inputs takes no action"
else
    fail "control: a second run took an action: ${OUT:0:300}"
fi

# ── operator.conf and the enable list ────────────────────────────────────────────────────────────────────────────────
section "assets: an untrusted operator.conf, an invalid list"
fresh
chmod 0664 "${CONF}"; reconcile
if has_row enable-list-untrusted "${CONF}"; then pass "a group-writable operator.conf: enable-list-untrusted"; else fail "a group-writable operator.conf: no enable-list-untrusted row: ${OUT:0:300}"; fi
expect_unlinked skills/acme-pdf "a group-writable operator.conf"
[[ "${RC}" == 4 ]] && pass "a group-writable operator.conf: exit 4" || fail "a group-writable operator.conf: exit ${RC}"
fresh
mv "${CONF}" "${CONF}.real"; ln -s "${CONF}.real" "${CONF}"; reconcile
has_row enable-list-untrusted "${CONF}" && pass "a symlinked operator.conf: enable-list-untrusted" || fail "a symlinked operator.conf: ${OUT:0:300}"
expect_unlinked skills/acme-pdf "a symlinked operator.conf"
rm -f "${CONF}"; mv "${CONF}.real" "${CONF}"
fresh
chown "${PROJECTS_USER}" "${CONF}"; reconcile
has_row enable-list-untrusted "${CONF}" && pass "an operator.conf not owned by root: enable-list-untrusted" || fail "a non-root operator.conf: ${OUT:0:300}"
expect_unlinked skills/acme-pdf "an operator.conf not owned by root"
fresh
printf 'AI_TOOLS_AGENTS=[agent-acme]\nAI_TOOLS_ASSETS=[%s, %s\n' "${SKILL}" "${SUB}" > "${CONF}"; reconcile
expect_unlinked skills/acme-pdf "an invalid list [a, b"
has_row id-malformed "${CONF}" && pass "an invalid list: one attention row naming operator.conf" || fail "an invalid list: ${OUT:0:300}"
fresh
write_conf "${SKILL}" "acme/agents/acme-reviewer" "Bad/skills/x" "acme/orientation/x"; reconcile
expect_state "acme/agents/acme-reviewer" kind-unknown "an identifier spelling agents"
expect_detail "acme/agents/acme-reviewer" subagents "the agents spelling names subagents"
expect_state "Bad/skills/x" id-malformed "an identifier outside the grammar"
expect_state "acme/orientation/x" kind-unknown "a kind without a registry row"
expect_state "${SKILL}" linked "a bad entry beside a good one: the good one"

# ── Trust of the roots and the set ───────────────────────────────────────────────────────────────────────────────────
section "assets: untrusted roots, sets and files"
fresh
chmod 0775 "${PKG}/acme"; reconcile
expect_state "${SKILL}" path-untrusted "a group-writable set directory"
expect_unlinked skills/acme-pdf "a group-writable set directory"
fresh
mv "${PKG}/acme" "${TESTDIR}/acme-moved"; ln -s "${TESTDIR}/acme-moved" "${PKG}/acme"; reconcile
expect_state "${SKILL}" path-untrusted "a symlinked set directory"
rm -f "${PKG}/acme"; rm -rf "${TESTDIR}/acme-moved"
fresh
chown "${PROJECTS_USER}" "${PKG}"; reconcile
expect_state "${SKILL}" path-untrusted "a root owned by the projects user"
expect_unlinked skills/acme-pdf "a root owned by the projects user"
chown root:root "${PKG}"
fresh
chmod 0664 "${PKG}/acme/skills/acme-pdf/SKILL.md"; reconcile
expect_state "${SKILL}" path-untrusted "one 0664 file inside a root-owned set"
expect_detail "${SKILL}" SKILL.md "the refusal names the file"

# ── The signature ────────────────────────────────────────────────────────────────────────────────────────────────────
section "assets: a tampered set, an unverified set"
fresh
printf 'edited\n' >> "${PKG}/acme/skills/acme-pdf/SKILL.md"; reconcile
expect_state "${SKILL}" set-tampered "an edited file"
expect_unlinked skills/acme-pdf "an edited file"
assert_msg MSG-Z3P6 "$(cut -f3 <<< "${OUT}" | sort -u)" "the reconcile rows carry the reconcile code"
fresh
printf 'added\n' > "${PKG}/acme/skills/acme-pdf/extra.md"; chmod 0644 "${PKG}/acme/skills/acme-pdf/extra.md"; reconcile
expect_state "${SKILL}" set-tampered "an added file"
fresh
rm "${PKG}/acme/README.md"; reconcile
expect_state "${SKILL}" set-tampered "a removed file"
fresh
printf 'edited\n' >> "${PKG}/acme/README.md"; asset_signing_write_inventory "${PKG}/acme"; reconcile
expect_state "${SKILL}" set-tampered "a SHA256SUMS rewritten after an edit"
fresh
rm "${PKG}/acme/SHA256SUMS.asc"; reconcile
expect_state "${SKILL}" set-unverified "no SHA256SUMS.asc"
fresh
asset_signing_sign "${PKG}/acme" other; reconcile
expect_state "${SKILL}" set-unverified "a signature by a key the binding does not name"
fresh
printf 'origin=https://example.com\n' >> "${BINDINGS}/acme.conf"; reconcile
expect_state "${SKILL}" set-unverified "a binding carrying a key this release does not define"
asset_signing_write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
fresh
asset_signing_write_binding acme "${KEYS}/absent.gpg" "openpgp:${SIGNER}"; reconcile
expect_state "${SKILL}" set-unverified "a binding naming an absent keyring"
asset_signing_write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
fresh
asset_signing_build_set "${PKG}" acme-free; write_conf "acme-free/skills/acme-free-pdf"; reconcile
expect_state "acme-free/skills/acme-free-pdf" set-unbound "a set name with no binding"
fresh
write_conf "acme-two/skills/acme-two-pdf"; reconcile
expect_state "acme-two/skills/acme-two-pdf" set-absent "a bound set no root holds: pending its package"

# ── The file-shape rules ─────────────────────────────────────────────────────────────────────────────────────────────
section "assets: the file-shape rules refuse the set"
# shape_case <rule> <what> <command> : mutate the sealed set, reconcile, and expect set-invalid naming <rule>.
shape_case() {
    fresh
    eval "$3"
    reconcile
    expect_state "${SKILL}" set-invalid "$2"
    expect_detail "${SKILL}" "$1" "$2: the detail names $1"
}
shape_case file.symlink "a symbolic link" 'ln -s SKILL.md "${PKG}/acme/skills/acme-pdf/link.md"'
shape_case file.hardlink "a second hard link" 'ln "${PKG}/acme/README.md" "${PKG}/acme/skills/acme-pdf/again.md"'
shape_case file.special "a FIFO" 'mkfifo -m 0644 "${PKG}/acme/skills/acme-pdf/pipe"'
shape_case file.size "a file over 1 MiB" 'head -c 1048577 /dev/zero > "${PKG}/acme/skills/acme-pdf/large.md"; chmod 0644 "${PKG}/acme/skills/acme-pdf/large.md"'
shape_case file.size "2001 files" 'mkdir -m 0755 "${PKG}/acme/skills/acme-pdf/many"; for i in $(seq 1 2001); do : > "${PKG}/acme/skills/acme-pdf/many/f${i}"; done; chmod 0644 "${PKG}/acme/skills/acme-pdf/many"/*'
shape_case file.name "a name outside the portable set" ': > "${PKG}/acme/skills/acme-pdf/two words.md"; chmod 0644 "${PKG}/acme/skills/acme-pdf/two words.md"'

# ── The set-scope rules of the subset ────────────────────────────────────────────────────────────────────────────────
section "assets: each set-scope rule refuses the set"
# set_case <token> <rule> <what> <command> : mutate, reseal, reconcile, expect <token> naming <rule>.
set_case() {
    fresh
    eval "$4"
    asset_signing_seal "${PKG}/acme"
    reconcile
    expect_state "${SKILL}" "$1" "$3"
    expect_detail "${SKILL}" "$2" "$3: the detail names $2"
}
SETCONF='"${PKG}/acme/set.conf"'
set_case set-invalid set.conf.syntax "a line without =" "printf 'bad line\n' >> ${SETCONF}"
set_case set-invalid set.conf.syntax "a key given twice" "printf 'name=acme\n' >> ${SETCONF}"
set_case set-invalid set.conf.syntax "a quote that does not close" "sed -i 's/^license=MIT/license=\"MIT/' ${SETCONF}"
set_case set-invalid set.conf.syntax "an empty list item" "sed -i 's/^maintainers=.*/maintainers=[a@x,,b@x]/' ${SETCONF}"
set_case set-invalid set.conf.required-key "summary absent" "sed -i '/^summary=/d' ${SETCONF}"
set_case set-invalid set.conf.required-key "maintainers=[]" "sed -i 's/^maintainers=.*/maintainers=[]/' ${SETCONF}"
set_case set-invalid set.conf.format "format=2" "sed -i 's/^format=1/format=2/' ${SETCONF}"
set_case set-invalid set.conf.name "a name other than the directory" "sed -i 's/^name=acme/name=acme-other/' ${SETCONF}"
set_case set-invalid set.conf.version "version=1.0" "sed -i 's/^version=.*/version=1.0/' ${SETCONF}"
set_case set-invalid set.conf.requires-integrations "requires_integrations=[dotnet]" "printf 'requires_integrations=[dotnet]\n' >> ${SETCONF}"
set_case set-invalid set.conf.unknown-key "a key outside the table" "printf 'homepage=https://acme.example\n' >> ${SETCONF}"
set_case set-invalid set.entry.unknown "an unknown top-level file" ': > "${PKG}/acme/notes.txt"'
set_case set-invalid set.entry.unknown "LICENSES as a file" ': > "${PKG}/acme/LICENSES"'
set_case set-invalid set.entry.reserved "an empty libs/" 'mkdir "${PKG}/acme/libs"'
set_case set-invalid set.entry.reserved "llms.txt" ': > "${PKG}/acme/llms.txt"'
set_case set-invalid kind.shape "a file under skills/" ': > "${PKG}/acme/skills/notes.md"'
set_case set-invalid kind.shape "a skill without SKILL.md" 'mkdir "${PKG}/acme/skills/acme-empty"; : > "${PKG}/acme/skills/acme-empty/README.md"'
set_case set-invalid kind.reserved "a reserved kind directory, empty" 'mkdir "${PKG}/acme/commands"'
set_case capability-unknown set.conf.requires-capabilities "an unknown capability at set scope" "printf 'requires_capabilities=[skills.future.v9]\n' >> ${SETCONF}"
fresh
asset_signing_build_set "${TESTDIR}" set-without-conf; rm "${TESTDIR}/set-without-conf/set.conf"
# The source profile, as the publisher's fixture for the rule: a release inventory still listing set.conf is
# release.inventory as well.
if [[ "$(bash -c 'source "$1"; ai_tools_assets_validate_set "$2" source' _ "${LIB}" "${TESTDIR}/set-without-conf" | cut -f1 | sort -u)" == set.conf.missing ]]; then
    pass "a set directory without set.conf: set.conf.missing (the resolver does not discover it as a set)"
else
    fail "a set directory without set.conf is not set.conf.missing alone"
fi

# ── The asset-scope rules ────────────────────────────────────────────────────────────────────────────────────────────
section "assets: each asset-scope rule refuses the asset alone"
# asset_case <id> <token> <rule> <what> <command> : mutate, reseal, reconcile, expect <id> refused and the sibling
# linked.
asset_case() {
    local id="$1" sibling="${SUB}"
    [[ "${id}" == "${SUB}" ]] && sibling="${SKILL}"
    fresh
    eval "$5"
    asset_signing_seal "${PKG}/acme"
    reconcile
    expect_state "${id}" "$2" "$4"
    expect_detail "${id}" "$3" "$4: the detail names $3"
    expect_state "${sibling}" linked "$4: the sibling asset still links"
}
SKILLMD='"${PKG}/acme/skills/acme-pdf/SKILL.md"'; SUBMD='"${PKG}/acme/agents/acme-reviewer.md"'
ASSETCONF='"${PKG}/acme/metadata/skills/acme-pdf/asset.conf"'
mkmeta='mkdir -p "${PKG}/acme/metadata/skills/acme-pdf"; '
asset_case "${SKILL}" asset-invalid name.frontmatter "a frontmatter name other than the directory" "sed -i 's/^name: acme-pdf/name: acme-other/' ${SKILLMD}"
asset_case "${SKILL}" asset-invalid frontmatter.missing "no frontmatter" "printf 'No frontmatter.\n' > ${SKILLMD}"
asset_case "${SKILL}" asset-invalid frontmatter.missing "a frontmatter that does not close" "printf -- '---\nname: acme-pdf\n' > ${SKILLMD}"
asset_case "${SKILL}" asset-invalid frontmatter.required "an empty description" "sed -i 's/^description: .*/description:/' ${SKILLMD}"
asset_case "${SKILL}" asset-invalid frontmatter.syntax "a second name line" "sed -i '2a name: acme-pdf' ${SKILLMD}"
asset_case "${SKILL}" asset-invalid frontmatter.refused-key "a skill with allowed-tools" "sed -i '2a allowed-tools: Bash' ${SKILLMD}"
asset_case "${SUB}" asset-invalid frontmatter.refused-key "a subagent with hooks" "sed -i '2a hooks:' ${SUBMD}"
asset_case "${SUB}" asset-invalid frontmatter.refused-key "a subagent with permissionMode" "sed -i '2a permissionMode: acceptEdits' ${SUBMD}"
asset_case "${SKILL}" asset-invalid metadata.asset-conf "asset.conf format=2" "${mkmeta}printf 'format=2\n' > ${ASSETCONF}"
asset_case "${SKILL}" asset-invalid set.conf.unknown-key "asset.conf carrying supported_targets" "${mkmeta}printf 'format=1\nsupported_targets=[claude-code]\n' > ${ASSETCONF}"
asset_case "${SKILL}" capability-unknown metadata.asset-conf "an unknown capability at asset scope" "${mkmeta}printf 'format=1\nrequires_capabilities=[hooks.v1]\n' > ${ASSETCONF}"
fresh
asset_signing_build_set "${PKG}" acme ai-tools-pdf; write_conf acme/skills/ai-tools-pdf "${SUB}"; reconcile
expect_state acme/skills/ai-tools-pdf asset-invalid "an ai-tools- name outside core and ai-tools"
expect_detail acme/skills/ai-tools-pdf name.asset-prefix "the detail names name.asset-prefix"
expect_state "${SUB}" linked "the reserved prefix: the sibling still links"

# ── The load-time substitution ───────────────────────────────────────────────────────────────────────────────────────
section "assets: the substitution needs its declaration"
inject_case() {
    asset_case "$1" asset-invalid body.dynamic-injection "$2" "$3"
}
inject_case "${SKILL}" "!\`date\` at a line start" "printf '\n!\`date\`\n' >> ${SKILLMD}"
inject_case "${SKILL}" "!\`date\` after whitespace in a list item" "printf '\n- Current date: !\`date\`\n' >> ${SKILLMD}"
inject_case "${SKILL}" "a \`\`\`! fence" "printf '\n\`\`\`!\ngit status\n\`\`\`\n' >> ${SKILLMD}"
inject_case "${SKILL}" "a \`\`\`bash! fence" "printf '\n\`\`\`bash!\ngit status\n\`\`\`\n' >> ${SKILLMD}"
inject_case "${SKILL}" "an indented ~~~~ sh! fence" "printf '\n  ~~~~  sh! title\ngit status\n~~~~\n' >> ${SKILLMD}"
inject_case "${SKILL}" "a substitution inside the frontmatter" "sed -i '2a compatibility: \"Run !\`echo pwn\`\"' ${SKILLMD}"
inject_case "${SUB}" "a substitution in a subagent" "printf '\nThe branch: !\`git branch --show-current\`\n' >> ${SUBMD}"
fresh
mkdir -p "${PKG}/acme/metadata/skills/acme-pdf"
printf 'format=1\nrequires_capabilities=[skills.dynamic.v1]\n' > "${PKG}/acme/metadata/skills/acme-pdf/asset.conf"
printf '\nThe working tree: !`git status --short`\n' >> "${PKG}/acme/skills/acme-pdf/SKILL.md"
asset_signing_seal "${PKG}/acme"; reconcile
expect_state "${SKILL}" linked "the substitution with skills.dynamic.v1 declared"
expect_detail "${SKILL}" "requires skills.dynamic.v1" "a linked asset's row carries the capability it declares"
fresh
mkdir -p "${PKG}/acme/metadata/skills/acme-pdf"
printf 'format=1\nrequires_capabilities=[skills.dynamic.v1]\n' > "${PKG}/acme/metadata/skills/acme-pdf/asset.conf"
asset_signing_seal "${PKG}/acme"; reconcile
expect_state "${SKILL}" linked "the declaration with no substitution"

# ── A scan that does not complete ────────────────────────────────────────────────────────────────────────────────────
section "assets: a substitution scan that does not complete is a finding"
# validate <prelude> <set-dir> [user] : the validator's findings over <set-dir> under the source profile, one
# `<rule> <detail>` per line, after <prelude> ran in the same shell -- as root, or as <user>.
validate() {
    local -a runner=()
    [[ -n "${3:-}" ]] && runner=( runuser -u "$3" -- )
    # shellcheck disable=SC2016  # the $1, $2 and $3 are the inner shell's
    "${runner[@]}" bash -c 'source "$1" 2>/dev/null || exit 99; eval "$2"; ai_tools_assets_validate_set "$3" source | cut -f1,3' \
        _ "${LIB}" "$1" "$2" 2>/dev/null || true
}
asset_signing_build_set "${TESTDIR}" scan-hit; asset_signing_build_set "${TESTDIR}" scan-clean
printf '\n!`date`\n' >> "${TESTDIR}/scan-hit/skills/scan-hit-pdf/SKILL.md"
out="$(validate : "${TESTDIR}/scan-hit")"
[[ "${out}" == "body.dynamic-injection"$'\t'"a line runs a command"* ]] && pass "control: a matching file is body.dynamic-injection" \
    || fail "control: a matching file reads '${out}'"
out="$(validate : "${TESTDIR}/scan-clean")"
[[ -z "${out}" ]] && pass "control: a file without the substitution reads clean" || fail "control: a clean file reads '${out}'"
# scan_failed <what> <prelude> [user] : the clean set, with the scan made to fail, is body.dynamic-injection naming
# the incomplete scan.
scan_failed() {
    out="$(validate "$2" "${TESTDIR}/scan-clean" "${3:-}")"
    if grep -q "^body.dynamic-injection"$'\t'"the scan did not complete (grep exit" <<< "${out}"; then
        pass "$1: the scan is a finding, not a clean file"
    else
        fail "$1: the validator read '${out}'"
    fi
}
scan_failed "grep exiting 2" 'grep() { return 2; }'
scan_failed "grep absent from PATH" 'hash -p /nonexistent/grep grep'
chmod 0000 "${TESTDIR}/scan-clean/skills/scan-clean-pdf/SKILL.md"
scan_failed "an entry file the reader cannot read" : "${PROJECTS_USER}"
chmod 0644 "${TESTDIR}/scan-clean/skills/scan-clean-pdf/SKILL.md"

# ── Requirements ─────────────────────────────────────────────────────────────────────────────────────────────────────
section "assets: a requirement is read, not skipped"
set_case requires-base requires_base "requires_base above the installed base" "printf 'requires_base=99.0.0\n' >> ${SETCONF}"
fresh
printf 'requires_base=0.1.0\n' >> "${PKG}/acme/set.conf"; asset_signing_seal "${PKG}/acme"; reconcile AI_TOOLS_VERSION=dev
expect_state "${SKILL}" requires-base "a checkout's dev version against requires_base"
fresh
printf 'requires_base=0.24.0\n' >> "${PKG}/acme/set.conf"; asset_signing_seal "${PKG}/acme"; reconcile
expect_state "${SKILL}" linked "requires_base equal to the installed base"
set_case integration-off integration-dotnet "a set requiring an integration that is off" "printf 'requires_integrations=[integration-dotnet]\n' >> ${SETCONF}"
fresh
mkdir -p "${PKG}/acme/metadata/skills/acme-pdf"
printf 'format=1\nrequires_integrations=[integration-dotnet]\n' > "${PKG}/acme/metadata/skills/acme-pdf/asset.conf"
asset_signing_seal "${PKG}/acme"; reconcile
expect_state "${SKILL}" integration-off "an asset requiring an integration that is off"
INTEG_LINE="integration-dotnet"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" linked "the same asset once the integration is enabled"

# ── Compatibility is a profile question ──────────────────────────────────────────────────────────────────────────────
section "assets: compatibility is a profile question"
dynamic_skill() {
    fresh
    mkdir -p "${PKG}/acme/metadata/skills/acme-pdf"
    printf 'format=1\nrequires_capabilities=[skills.dynamic.v1]\n' > "${PKG}/acme/metadata/skills/acme-pdf/asset.conf"
    asset_signing_seal "${PKG}/acme"
}
dynamic_skill; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" capability-unsupported "a profile the enabled agent beta does not list"
expect_detail "${SKILL}" beta "the refusal names the agent"
expect_unlinked skills/acme-pdf "an unsupported profile"
absent "${HOME_DIR}/.beta/skills/acme-pdf" && pass "an unsupported profile: absent for beta too" || fail "an unsupported profile: beta holds a link"
expect_state "${SUB}" linked "an unsupported skill profile leaves the subagent linked"
AGENTS_LINE="agent-acme"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" linked "the same asset once beta is disabled"
manifest beta skills_dir=skills "asset_profiles=[skills.portable.v1, skills.dynamic.v1]"
dynamic_skill; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" linked "the same asset once beta's manifest lists the profile"
manifest beta skills_dir=skills "asset_profiles=[skills.portable.v1, skills.future.v9]"
dynamic_skill; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" capability-unsupported "a token base does not define in asset_profiles is not implemented"
manifest beta skills_dir=skills
fresh; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" linked "a manifest without asset_profiles implements the base profile of its directory"
manifest beta skills_dir=skills "asset_profiles=[skills.dynamic.v1]"
fresh; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" capability-unsupported "a manifest listing a profile of the kind but not its base profile"
expect_detail "${SKILL}" "skills.portable.v1, which the enabled agent beta" "the refusal names the base profile and the agent"
dynamic_skill; AGENTS_LINE="agent-acme, agent-gamma"; write_conf "${SKILL}" "${SUB}"; reconcile
expect_state "${SKILL}" linked "an agent declaring no directory and no profile for the kind is not consulted"
absent "${HOME_DIR}/.gamma/skills" && pass "a skills_dir-less agent gets no link" || fail "the agent gamma was given ${HOME_DIR}/.gamma/skills"
manifest beta skills_dir=skills "asset_profiles=[skills.portable.v1]"

# ── A failed discovery is not an empty receiver set ──────────────────────────────────────────────────────────────────
section "assets: a provider discovery that fails leaves the receivers unknown"
# receivers_unknown <what> : the last run wrote one unreadable receivers-unknown row and the entry as receivers-unknown,
# left the view without a resolver link and the agent's links as the control placed them, and exited 5.
receivers_unknown() {
    if has_row_at unreadable receivers-unknown && [[ "$(finding "${SKILL}")" == receivers-unknown && "${RC}" == 5 ]]; then
        pass "$1: one unreadable receivers-unknown row, the entry receivers-unknown, exit 5"
    else
        fail "$1: rc ${RC}, ${OUT:0:400}"
    fi
    if absent "${HOME_DIR}/skills/acme-pdf" && absent "${HOME_DIR}/subagents/acme-reviewer.md"; then
        pass "$1: the view keeps no resolver link"
    else
        fail "$1: a resolver link is left in the view"
    fi
    [[ "$(readlink -- "${HOME_DIR}/.acme/skills/acme-pdf")" == "${HOME_DIR}/skills/acme-pdf" ]] \
        && pass "$1: the agent's directory is not changed" || fail "$1: the agent's link was changed"
}
fresh; PRELUDE='ai_tools_enabled_agents() { return 2; }'; reconcile; PRELUDE=""
receivers_unknown "an enabled-agents reader that exits 2"
fresh; PRELUDE='ai_tools_enabled_agents() { printf "acme\t@fixture/acme\tacme\n"; return 2; }'; reconcile; PRELUDE=""
receivers_unknown "a reader that prints a row, then exits 2"
fresh; PRELUDE='ai_tools_installed_agents() { return 2; }'; reconcile; PRELUDE=""
receivers_unknown "an installed-agents reader that exits 2"
fresh; chmod 0775 "${AGENTS_D}"; reconcile; chmod 0755 "${AGENTS_D}"
receivers_unknown "an untrusted manifest directory"
dynamic_skill; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"
chmod 0664 "${AGENTS_D}/beta.conf"; reconcile; chmod 0644 "${AGENTS_D}/beta.conf"
expect_state "${SKILL}" linked "an untrusted manifest beside a trusted one: the asset is held to the agent that resolved"
fresh; rm -rf "${HOME_DIR}"/.acme/*; AGENTS_LINE=""; write_conf "${SKILL}" "${SUB}"; reconcile
if [[ "${RC}" == 0 ]] && linked skills/acme-pdf "${PKG}/acme/skills/acme-pdf" && absent "${HOME_DIR}/.acme/skills"; then
    pass "AI_TOOLS_AGENTS=[] is a valid empty set: the view links, and no agent's directory is touched"
else
    fail "AI_TOOLS_AGENTS=[]: rc ${RC}, $(ls -la "${HOME_DIR}/.acme" 2>&1 | tr '\n' '|') ${OUT:0:300}"
fi

# ── Clash and shadowing ──────────────────────────────────────────────────────────────────────────────────────────────
section "assets: the clash rule, shadowing"
fresh
asset_signing_build_set "${PKG}" acme-two acme-pdf; write_conf "${SKILL}" acme-two/skills/acme-pdf; reconcile
expect_state "${SKILL}" name-clash "two sets naming one skill: the first"
expect_state acme-two/skills/acme-pdf name-clash "two sets naming one skill: the second"
expect_unlinked skills/acme-pdf "a clash"
write_conf acme-two/skills/acme-pdf; reconcile
if linked skills/acme-pdf "${PKG}/acme-two/skills/acme-pdf"; then pass "disabling one side of a clash links the other"; else fail "after the clash the view holds $(readlink "${HOME_DIR}/skills/acme-pdf" 2>&1)"; fi
fresh
asset_signing_build_set "${LOCAL}" acme; reconcile
if linked skills/acme-pdf "${LOCAL}/acme/skills/acme-pdf"; then pass "a copy in the local root shadows the packaged one"; else fail "shadowing: the view holds $(readlink "${HOME_DIR}/skills/acme-pdf" 2>&1)"; fi
rm -rf "${LOCAL:?}/acme"; mkdir -p "${LOCAL}/acme/agents"
printf 'format=1\n' > "${LOCAL}/acme/set.conf"; cp "${PKG}/acme/agents/acme-reviewer.md" "${LOCAL}/acme/agents/"
asset_signing_write_binding acme "${KEYS}/signer.gpg" "openpgp:${SIGNER}"
asset_signing_seal "${LOCAL}/acme"; reconcile
if linked skills/acme-pdf "${PKG}/acme/skills/acme-pdf"; then pass "a local copy holding one asset overrides that asset alone"; else fail "partial shadowing: $(readlink "${HOME_DIR}/skills/acme-pdf" 2>&1)"; fi
expect_state "${SUB}" set-invalid "the local copy holding the subagent is the one read, and refused"

# ── The view ─────────────────────────────────────────────────────────────────────────────────────────────────────────
section "assets: the view is non-displacing, atomic, and removes only its own links"
fresh
rm -f "${HOME_DIR}/skills/acme-pdf"; mkdir "${HOME_DIR}/skills/acme-pdf"; printf 'mine\n' > "${HOME_DIR}/skills/acme-pdf/SKILL.md"
before="$(find "${HOME_DIR}/skills/acme-pdf" -printf '%P %s %M\n' | sort; cat "${HOME_DIR}/skills/acme-pdf/SKILL.md")"
reconcile
expect_state "${SKILL}" view-occupied "a real directory at the name"
[[ "$(find "${HOME_DIR}/skills/acme-pdf" -printf '%P %s %M\n' | sort; cat "${HOME_DIR}/skills/acme-pdf/SKILL.md")" == "${before}" ]] \
    && pass "the real directory is left as it was" || fail "the real directory changed"
fresh
rm -f "${HOME_DIR}/subagents/acme-reviewer.md"; printf 'mine\n' > "${HOME_DIR}/subagents/acme-reviewer.md"; reconcile
expect_state "${SUB}" view-occupied "a real file at the name"
[[ "$(cat "${HOME_DIR}/subagents/acme-reviewer.md")" == mine ]] && pass "the real file is left as it was" || fail "the real file changed"
fresh
ln -sfn /etc/hostname "${HOME_DIR}/skills/acme-pdf"; reconcile
expect_state "${SKILL}" view-occupied "a link elsewhere at the name"
[[ "$(readlink "${HOME_DIR}/skills/acme-pdf")" == /etc/hostname ]] && pass "the link elsewhere is left as it was" || fail "the link elsewhere was repointed"
fresh
mkdir "${HOME_DIR}/skills/ai-tools-seeded"
printf -- '---\nname: ai-tools-seeded\nx-ai-tools-managed: true\n---\n' > "${HOME_DIR}/skills/ai-tools-seeded/SKILL.md"
ln -s /etc "${HOME_DIR}/skills/foreign"
ln -s "${PKG}/acme/skills/acme-pdf" "${HOME_DIR}/skills/.acme-pdf.ai-tools-assets.tmp"
asset_signing_build_set "${LOCAL}" acme
probe_flag="${TESTDIR}/probe"; : > "${probe_flag}"
( misses=0; reads=0; while [[ -e "${probe_flag}" ]]; do reads=$(( reads + 1 ))
      [[ -L "${HOME_DIR}/skills/acme-pdf" ]] || misses=$(( misses + 1 )); done
  printf '%s %s\n' "${reads}" "${misses}" > "${TESTDIR}/probe-result" ) &
probe_pid=$!
reconcile
rm -f "${probe_flag}"; wait "${probe_pid}" || true
read -r reads misses < "${TESTDIR}/probe-result"
if linked skills/acme-pdf "${LOCAL}/acme/skills/acme-pdf" && [[ "${misses}" == 0 && "${reads}" -gt 0 ]]; then
    pass "a repoint leaves the name present at every read (${reads} reads during the run)"
else
    fail "a repoint: ${misses} of ${reads} reads found the name missing, view $(readlink "${HOME_DIR}/skills/acme-pdf" 2>&1)"
fi
absent "${HOME_DIR}/skills/.acme-pdf.ai-tools-assets.tmp" && pass "the temporary name is absent after the run, a leftover one removed" \
    || fail "a temporary name is left in the view"
[[ -f "${HOME_DIR}/skills/ai-tools-seeded/SKILL.md" ]] && pass "a seeded managed copy survives" || fail "the seeded copy is gone"
[[ "$(readlink "${HOME_DIR}/skills/foreign")" == /etc ]] && pass "a foreign link survives" || fail "the foreign link is gone"
has_row view-foreign "${HOME_DIR}/skills/foreign" && pass "the foreign link is reported view-foreign" || fail "no view-foreign row: ${OUT:0:300}"
[[ "$(readlink "${HOME_DIR}/.acme/skills/ai-tools-seeded")" == "${HOME_DIR}/skills/ai-tools-seeded" ]] \
    && pass "the agent's directory links the seeded copy too" || fail "the seeded copy is not linked into the agent's directory"
write_conf "${SUB}"; reconcile
absent "${HOME_DIR}/skills/acme-pdf" && absent "${HOME_DIR}/.acme/skills/acme-pdf" \
    && pass "a resolver link whose asset left the list is removed, with the agent's link" || fail "the link of a disabled asset stays"
[[ -L "${HOME_DIR}/.acme/skills/ai-tools-seeded" ]] && pass "the seeded copy's agent link stays" || fail "the seeded copy's agent link was removed"

# ── A listing that fails is not an empty directory ───────────────────────────────────────────────────────────────────
section "assets: a view or agent directory that cannot be listed is reported and not planned"
# failing_find <directory> [name] : a PRELUDE whose find, asked to list <directory> one level down, prints <name> (when
# given) and exits 1; every other find runs as it is.
failing_find() {
    printf 'find() { if [[ "$2" == %q && " $* " == *" -maxdepth 1 "* ]]; then %s return 1; fi; command find "$@"; }' \
        "$1" "${2:+printf '%s\\0' $(printf '%q' "$2");}"
}
# listing_failed <what> <foreign> : the last run wrote an unreadable error row, exited 5, and left <foreign> as it was.
listing_failed() {
    if has_row_at unreadable error && [[ "${RC}" == 5 ]]; then
        pass "$1: an unreadable error row, exit 5"
    else
        fail "$1: rc ${RC}, ${OUT:0:400}"
    fi
    [[ "$(find "$2" -printf '%P %y %s %m\n' | sort)" == "${foreign_before}" ]] && pass "$1: the foreign entry is as it was" \
        || fail "$1: the foreign entry changed"
}
for partial in "" foreign-dir; do
    fresh
    mkdir "${HOME_DIR}/skills/foreign-dir"; printf 'mine\n' > "${HOME_DIR}/skills/foreign-dir/SKILL.md"
    foreign_before="$(find "${HOME_DIR}/skills/foreign-dir" -printf '%P %y %s %m\n' | sort)"
    PRELUDE="$(failing_find "${HOME_DIR}/skills" "${partial}")"; reconcile; PRELUDE=""
    listing_failed "the view listing fails${partial:+ after one name}" "${HOME_DIR}/skills/foreign-dir"
    [[ "$(finding "${SKILL}")" == error ]] && pass "the view listing fails${partial:+ after one name}: the entry is not reported linked" \
        || fail "the view listing fails: the entry reads '$(finding "${SKILL}")'"
done
fresh; write_conf "${SUB}"
PRELUDE="$(failing_find "${HOME_DIR}/skills")"; reconcile; PRELUDE=""
if has_row_at unreadable error && [[ "${RC}" == 5 ]] && linked skills/acme-pdf "${PKG}/acme/skills/acme-pdf"; then
    pass "the view listing fails as the last skill is disabled: its resolver link stays, reported, exit 5"
else
    fail "the last skill disabled under a failed listing: rc ${RC}, ${OUT:0:300}"
fi
for partial in "" acme-gone; do
    fresh
    ln -s "${HOME_DIR}/skills/acme-gone" "${HOME_DIR}/.acme/skills/acme-gone"
    mkdir "${HOME_DIR}/.acme/skills/own"; printf 'mine\n' > "${HOME_DIR}/.acme/skills/own/SKILL.md"
    foreign_before="$(find "${HOME_DIR}/.acme/skills/own" -printf '%P %y %s %m\n' | sort)"
    PRELUDE="$(failing_find "${HOME_DIR}/.acme/skills" "${partial}")"; reconcile; PRELUDE=""
    listing_failed "the agent's listing fails${partial:+ after one name}" "${HOME_DIR}/.acme/skills/own"
    [[ -L "${HOME_DIR}/.acme/skills/acme-gone" ]] && pass "the agent's listing fails: the stale link stays in place" \
        || fail "the agent's listing fails: the stale link was removed"
done

# ── The strict rule: resolver links and base's seeded copies alone ───────────────────────────────────────────────────
section "assets: an agent links the view's resolver links and base's seeded copies alone"
fresh
SKILLS_VIEW="${HOME_DIR}/skills"; MARKER=$'---\nname: x\nx-ai-tools-managed: true\n---\n'
mkdir "${SKILLS_VIEW}/own-skill"; printf -- '---\nname: own-skill\n---\n' > "${SKILLS_VIEW}/own-skill/SKILL.md"
mkdir "${SKILLS_VIEW}/ai-tools-forged"; printf '%s' "${MARKER}" > "${SKILLS_VIEW}/ai-tools-forged/SKILL.md"
chown -R "${PROJECTS_USER}" "${SKILLS_VIEW}/ai-tools-forged"
ln -s /etc "${SKILLS_VIEW}/etc-link"; ln -s "${TESTDIR}/nowhere" "${SKILLS_VIEW}/dangling"
mkdir "${SKILLS_VIEW}/tab"$'\t'"name"; printf '%s' "${MARKER}" > "${SKILLS_VIEW}/tab"$'\t'"name/SKILL.md"
mkdir -- "${SKILLS_VIEW}/-leading"; printf '%s' "${MARKER}" > "${SKILLS_VIEW}/-leading/SKILL.md"
mkdir "${SKILLS_VIEW}/.hidden"; printf '%s' "${MARKER}" > "${SKILLS_VIEW}/.hidden/SKILL.md"
printf '%s' "${MARKER}" > "${SKILLS_VIEW}/ai-tools-file-skill"
mkdir "${HOME_DIR}/subagents/ai-tools-dir-sub.md"; printf '%s' "${MARKER}" > "${HOME_DIR}/subagents/ai-tools-dir-sub.md/x"
mkdir "${SKILLS_VIEW}/ai-tools-seeded"; printf '%s' "${MARKER}" > "${SKILLS_VIEW}/ai-tools-seeded/SKILL.md"
mkdir "${SKILLS_VIEW}/ai-tools-edited"; printf '%s\nAn edit made in place.\n' "${MARKER}" > "${SKILLS_VIEW}/ai-tools-edited/SKILL.md"
view_snapshot() { find "${HOME_DIR}/skills" "${HOME_DIR}/subagents" -printf '%P %y %l %U %m %s\n' | LC_ALL=C sort; }
before="$(view_snapshot)"
reconcile
for name in own-skill ai-tools-forged etc-link dangling "tab"$'\t'"name" -leading .hidden ai-tools-file-skill; do
    if has_row view-foreign "${SKILLS_VIEW}/${name%%$'\t'*}" && absent "${HOME_DIR}/.acme/skills/${name}"; then
        pass "view-foreign, not linked into the agent's directory: $(printf '%q' "${name}")"
    else
        fail "$(printf '%q' "${name}"): $(ls -la "${HOME_DIR}/.acme/skills" 2>&1 | tr '\n' '|') ${OUT:0:200}"
    fi
done
if has_row view-foreign "${HOME_DIR}/subagents/ai-tools-dir-sub.md" && absent "${HOME_DIR}/.acme/agents/ai-tools-dir-sub.md"; then
    pass "view-foreign, not linked into the agent's directory: a directory where a subagent file goes"
else
    fail "a directory where a subagent file goes: ${OUT:0:300}"
fi
[[ "$(view_snapshot)" == "${before}" ]] && pass "every entry of the view is as it was" || fail "the view changed"
for name in ai-tools-seeded ai-tools-edited; do
    [[ "$(readlink -- "${HOME_DIR}/.acme/skills/${name}")" == "${SKILLS_VIEW}/${name}" ]] \
        && pass "a copy base seeded is linked: ${name}" || fail "${name} is not linked into the agent's directory"
done

# ── No last-good fallback ────────────────────────────────────────────────────────────────────────────────────────────
section "assets: no last-good fallback"
fresh
printf 'tampered\n' >> "${PKG}/acme/README.md"; reconcile
expect_unlinked skills/acme-pdf "a set that linked and then fails verification"
expect_unlinked subagents/acme-reviewer.md "the same set's subagent"
has_row unlinked "${HOME_DIR}/skills/acme-pdf" && pass "the removal is reported unlinked" || fail "no unlinked row: ${OUT:0:300}"

# ── The lock ─────────────────────────────────────────────────────────────────────────────────────────────────────────
section "assets: the lock serializes runs"
fresh
( flock 9; sleep 3 ) 9>>"${LOCK}" &
holder=$!
sleep 0.5
started="$(date +%s)"
reconcile
waited=$(( $(date +%s) - started ))
wait "${holder}" || true
if [[ "${RC}" == 0 && "${waited}" -ge 2 ]]; then pass "a run waits for the lock another holds (${waited}s), then completes"; else fail "the lock: rc ${RC} after ${waited}s"; fi
( reconcile; printf '%s\n' "${RC}" > "${TESTDIR}/rc-a" ) & first=$!
( reconcile; printf '%s\n' "${RC}" > "${TESTDIR}/rc-b" ) & second=$!
wait "${first}" "${second}" || true
reconcile
if [[ "$(cat "${TESTDIR}/rc-a" "${TESTDIR}/rc-b")" == $'0\n0' ]] && linked skills/acme-pdf "${PKG}/acme/skills/acme-pdf" \
        && ! awk -F'\t' 'NR > 1 && $5 == "info" { found = 1 } END { exit !found }' <<< "${OUT}"; then
    pass "two concurrent runs leave one consistent view"
else
    fail "two concurrent runs: rc $(cat "${TESTDIR}/rc-a" "${TESTDIR}/rc-b" | tr '\n' ' '), view $(readlink "${HOME_DIR}/skills/acme-pdf" 2>&1)"
fi

section "assets: the lock is root's alone, and the wait for it is bounded"
# refused_lock <what> : the last run refused under the lock's code and exited 1.
refused_lock() {
    if [[ "${RC}" == 1 ]]; then pass "$1: exit 1"; else fail "$1: exit ${RC}: ${ERR:0:200}"; fi
    assert_msg MSG-M8T9 "${ERR}" "$1: refused under the lock's code"
}
fresh; rm -rf "${LOCK%/*}"; PRELUDE='umask 000'; reconcile; PRELUDE=""
if [[ "$(stat -c '%U %a' "${LOCK%/*}")" == "root 700" && "$(stat -c '%U %a' "${LOCK}")" == "root 600" ]]; then
    pass "under umask 000 the lock directory is born 0700 and the lock file 0600, both root's"
else
    fail "the lock: $(stat -c '%n %U %a' "${LOCK%/*}" "${LOCK}" 2>&1 | tr '\n' '|')"
fi
# shellcheck disable=SC2016  # the $1 is the inner shell's
if runuser -u "${PROJECTS_USER}" -- bash -c 'exec {fd}<"$1"' _ "${LOCK}" 2>/dev/null; then
    fail "the projects user opened the lock read-only, so it could hold it"
else
    pass "the projects user cannot open the lock, read-only included"
fi
mv "${LOCK}" "${LOCK}.real"; ln -s "${TESTDIR}/lock-elsewhere" "${LOCK}"; reconcile
refused_lock "a symlink at the lock path"
absent "${TESTDIR}/lock-elsewhere" && pass "a symlink at the lock path: its target is not created" || fail "the lock symlink's target was created"
rm -f "${LOCK}"; mv "${LOCK}.real" "${LOCK}"
mv "${LOCK%/*}" "${LOCK%/*}.real"; ln -s "${LOCK%/*}.real" "${LOCK%/*}"; reconcile
refused_lock "a symlink at the lock directory"
rm -f "${LOCK%/*}"; mv "${LOCK%/*}.real" "${LOCK%/*}"
( flock 9; sleep 4 ) 9>>"${LOCK}" &
holder=$!
sleep 0.5
reconcile AI_TOOLS_ASSETS_LOCK_WAIT=1
wait "${holder}" || true
refused_lock "a lock another run holds past AI_TOOLS_ASSETS_LOCK_WAIT"

section "assets: the lock pair the provisioning paths hold"
PRISTINE="${TESTDIR}/pristine"
mkdir -p "${PRISTINE}/skills/ai-tools-seedme"
printf -- '---\nname: ai-tools-seedme\ndescription: A seeded fixture.\nx-ai-tools-managed: true\nx-ai-tools-version: 1\n---\n' \
    > "${PRISTINE}/skills/ai-tools-seedme/SKILL.md"
chmod -R a+rX "${PRISTINE}"
# provision <reconcile-command> [NAME=value...] : seed PRISTINE's skills into the view and run <reconcile-command>
# under the lock pair, as a provisioning path does, in a fresh shell whose $1 is the library; the status in RC,
# the seconds it took in TOOK.
provision() {
    local started
    started="$(date +%s)"; RC=0
    # shellcheck disable=SC2016  # the $1 to $4 are the inner shell's
    env "${HOOKS[@]}" "${@:2}" bash -c 'source "${1%/*}/msg.lib.sh"; source "$1" || exit 99
        ai_tools_assets_lock || exit 1
        AI_TOOLS_ASSUME_YES=1 ai_tools_seed_managed_assets "$2" "$3" root skills >/dev/null
        eval "$4" || exit 2
        ai_tools_assets_unlock' _ "${LIB}" "${PRISTINE}" "${HOME_DIR}" "$1" >/dev/null 2>&1 || RC=$?
    TOOK=$(( $(date +%s) - started ))
}
fresh
( flock 9; sleep 3 ) 9>>"${LOCK}" &
holder=$!
sleep 0.5
provision 'ai_tools_assets_reconcile root >/dev/null'
wait "${holder}" || true
if [[ "${RC}" == 0 && "${TOOK}" -ge 2 && -L "${HOME_DIR}/.acme/skills/ai-tools-seedme" ]]; then
    pass "a seed and a reconcile under the pair wait for a lock another run holds, then run (${TOOK}s)"
else
    fail "a seed and a reconcile under the pair: rc ${RC} after ${TOOK}s, $(ls -la "${HOME_DIR}/.acme/skills" 2>&1 | tr '\n' '|')"
fi
fresh
# shellcheck disable=SC2016  # the $1 is the inner shell's
provision 'bash -c '"'"'source "$1" || exit 99; ai_tools_assets_reconcile root >/dev/null'"'"' _ "$1"' AI_TOOLS_ASSETS_LOCK_WAIT=5
if [[ "${RC}" == 0 && "${TOOK}" -lt 5 && -L "${HOME_DIR}/.acme/skills/ai-tools-seedme" ]]; then
    pass "a reconcile run as a child of the lock's holder adopts the lock it inherited (${TOOK}s)"
else
    fail "a child reconcile under the parent's lock: rc ${RC} after ${TOOK}s"
fi
# in_order <file> <text>... : succeed when each <text> occurs in <file> after the one before it.
in_order() {
    local rest text
    rest="$(<"$1")"; shift
    for text in "$@"; do
        [[ "${rest}" == *"${text}"* ]] || return 1
        rest="${rest#*"${text}"}"
    done
}
for provisioner in install.sh src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh; do
    if [[ ! -r "${CHECKOUT}/${provisioner}" ]]; then
        skip "${provisioner}" "no checkout holds it"
    elif in_order "${CHECKOUT}/${provisioner}" ai_tools_assets_lock ai_tools_seed_managed_assets ai_tools_remove_retired_assets \
            "ai-tools-admin assets reconcile" ai_tools_assets_unlock; then
        pass "${provisioner} holds the lock across the seed, the retire pass and the reconcile"
    else
        fail "${provisioner} does not take ai_tools_assets_lock before the seed and release it after the reconcile"
    fi
done
if [[ ! -r "${CHECKOUT}/packaging/ai-tools.spec" ]]; then
    skip "packaging/ai-tools.spec" "no checkout holds it"
elif in_order "${CHECKOUT}/packaging/ai-tools.spec" 'ai_tools_assets_lock || exit 0; for kind' \
        'ai_tools_seed_managed_assets "$1" /opt/ai-tools ai-tools "${kind}"' 'ai_tools_remove_retired_assets' \
        '"$2" assets reconcile' ai_tools_assets_unlock; then
    pass "base's %post holds the lock across the seed, the retire pass and the reconcile, in one bash"
else
    fail "base's %post does not hold ai_tools_assets_lock across its seed and its reconcile"
fi

# ── The per-agent rules ──────────────────────────────────────────────────────────────────────────────────────────────
section "assets: the per-agent rules"
fresh
rm -f "${HOME_DIR}/.acme/skills/acme-pdf"; mkdir "${HOME_DIR}/.acme/skills/acme-pdf"; printf 'own\n' > "${HOME_DIR}/.acme/skills/acme-pdf/SKILL.md"
reconcile
if has_row agent-occupied "${HOME_DIR}/.acme/skills/acme-pdf" && [[ "$(cat "${HOME_DIR}/.acme/skills/acme-pdf/SKILL.md")" == own ]]; then
    pass "a real entry in the agent's directory is kept and reported agent-occupied"
else
    fail "a real entry: ${OUT:0:300}"
fi
has_row agent-entry-untrusted "${HOME_DIR}/.acme/skills/acme-pdf" && fail "a root-owned real entry reported untrusted" || pass "a root-owned real entry is not agent-entry-untrusted"
chown -R "${SANDBOX_USER}" "${HOME_DIR}/.acme/skills/acme-pdf"; reconcile
has_row agent-entry-untrusted "${HOME_DIR}/.acme/skills/acme-pdf" && pass "a sandbox-owned real entry is agent-entry-untrusted" || fail "a sandbox-owned entry: ${OUT:0:300}"
fresh
ln -sfn /etc/hostname "${HOME_DIR}/.acme/skills/acme-pdf"; reconcile
if has_row agent-occupied "${HOME_DIR}/.acme/skills/acme-pdf" && [[ "$(readlink "${HOME_DIR}/.acme/skills/acme-pdf")" == /etc/hostname ]]; then
    pass "a link elsewhere in the agent's directory is reported and not repointed"
else
    fail "a link elsewhere: $(readlink "${HOME_DIR}/.acme/skills/acme-pdf") ${OUT:0:300}"
fi
fresh
ln -sfn "${HOME_DIR}/skills/acme-gone" "${HOME_DIR}/.acme/skills/acme-gone"; reconcile
absent "${HOME_DIR}/.acme/skills/acme-gone" && pass "a link into the view whose entry is gone is removed" || fail "the dangling view link stays"
fresh
AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; reconcile
mkdir -p "${HOME_DIR}/skills/ai-tools-seeded"
printf -- '---\nname: ai-tools-seeded\nx-ai-tools-managed: true\n---\n' > "${HOME_DIR}/skills/ai-tools-seeded/SKILL.md"
reconcile
[[ -L "${HOME_DIR}/.beta/skills/acme-pdf" ]] && pass "an enabled second agent receives the view" || fail "beta did not receive the view"
AGENTS_LINE="agent-acme"; write_conf "${SKILL}" "${SUB}"; reconcile
if absent "${HOME_DIR}/.beta/skills/acme-pdf" && [[ -L "${HOME_DIR}/.beta/skills/ai-tools-seeded" ]]; then
    pass "disabling an installed agent removes its resolver links and keeps the seeded copy's"
else
    fail "a disabled agent: $(ls -la "${HOME_DIR}/.beta/skills" 2>&1 | tr '\n' '|')"
fi

# ── Destinations ─────────────────────────────────────────────────────────────────────────────────────────────────────
section "assets: a destination directory that is not root's alone is reported and not written"
OUTSIDE="${TESTDIR}/outside"
mkdir -p "${OUTSIDE}/skills"; printf 'sentinel\n' > "${OUTSIDE}/sentinel"; chmod 0755 "${OUTSIDE}" "${OUTSIDE}/skills"
outside_snapshot() { find "${OUTSIDE}" -printf '%P %y %U %G %m %s\n' | LC_ALL=C sort; }
outside_before="$(outside_snapshot)"
# two_agents : the control state with acme and beta enabled and beta's directory empty, not yet reconciled.
two_agents() { fresh; AGENTS_LINE="agent-acme, agent-beta"; write_conf "${SKILL}" "${SUB}"; rm -rf "${HOME_DIR}"/.beta/*; }
# destination_case <what> <finding> : the last run reported <finding>, exited 4, and left the tree outside as it was;
# for an agent's directory, the sibling agent beta's link was placed.
destination_case() {
    if has_row "$2" "${HOME_DIR}" && [[ "${RC}" == 4 ]]; then pass "$1: $2, exit 4"; else fail "$1: rc ${RC}: ${OUT:0:400}"; fi
    [[ "$(outside_snapshot)" == "${outside_before}" ]] && pass "$1: the tree outside is as it was" \
        || fail "$1: the tree outside changed: $(outside_snapshot | tr '\n' '|')"
    if [[ "$2" == agent-dir-untrusted ]]; then
        [[ "$(readlink -- "${HOME_DIR}/.beta/skills/acme-pdf")" == "${HOME_DIR}/skills/acme-pdf" ]] \
            && pass "$1: the sibling agent's link is placed" || fail "$1: beta holds $(ls -la "${HOME_DIR}/.beta/skills" 2>&1 | tr '\n' '|')"
    fi
}
two_agents; mv "${HOME_DIR}/skills" "${TESTDIR}/skills-real"; ln -s "${OUTSIDE}/skills" "${HOME_DIR}/skills"; reconcile
destination_case "a symlinked view" view-dir-untrusted
expect_state "${SKILL}" view-dir-untrusted "a symlinked view: the entry of its kind"
rm -f "${HOME_DIR}/skills"; mv "${TESTDIR}/skills-real" "${HOME_DIR}/skills"
two_agents; rm -rf "${HOME_DIR}/.acme/skills"; ln -s "${OUTSIDE}/skills" "${HOME_DIR}/.acme/skills"; reconcile
destination_case "a symlinked kind directory" agent-dir-untrusted
rm -f "${HOME_DIR}/.acme/skills"
two_agents; mv "${HOME_DIR}/.acme" "${TESTDIR}/acme-real"; ln -s "${OUTSIDE}" "${HOME_DIR}/.acme"; reconcile
destination_case "a symlinked config directory" agent-dir-untrusted
rm -f "${HOME_DIR}/.acme"; mv "${TESTDIR}/acme-real" "${HOME_DIR}/.acme"
two_agents; chown "${PROJECTS_USER}" "${HOME_DIR}/.acme/skills"; reconcile
destination_case "a kind directory owned by the projects user" agent-dir-untrusted
two_agents; chmod 0775 "${HOME_DIR}/.acme/skills"; reconcile
destination_case "a root-owned, group-writable kind directory" agent-dir-untrusted
two_agents; rm -rf "${HOME_DIR}/.acme/skills"
PRELUDE="install() { mkdir -- \"\${@: -1}\" && chown ${PROJECTS_USER} -- \"\${@: -1}\"; }"; reconcile; PRELUDE=""
destination_case "a kind directory taken between the plan and the apply (a stubbed install)" agent-dir-untrusted
if [[ "$(stat -c %U "${HOME_DIR}/.acme/skills")" == "${PROJECTS_USER}" && -z "$(ls -A "${HOME_DIR}/.acme/skills")" ]]; then
    pass "a kind directory taken between the plan and the apply: nothing is written into it, and it is not re-owned"
else
    fail "a kind directory taken between the plan and the apply: $(ls -la "${HOME_DIR}/.acme/skills" 2>&1 | tr '\n' '|')"
fi
rm -rf "${HOME_DIR}/.acme/skills"

# ── The planning half does not write ─────────────────────────────────────────────────────────────────────────────────
section "assets: the plan reads and does not write"
fresh
printf 'tampered\n' >> "${PKG}/acme/README.md"
snapshot() { find "${HOME_DIR}" -printf '%p %y %l %m %U\n' | LC_ALL=C sort; }
before="$(snapshot)"
# shellcheck disable=SC2016
env "${HOOKS[@]}" bash -c 'source "$1"; ai_tools_assets_plan' _ "${LIB}" >/dev/null 2>&1 || true
[[ "$(snapshot)" == "${before}" ]] && pass "ai_tools_assets_plan leaves the view and the agents' directories as they are" \
    || fail "the plan changed the tree"

# ── The conformance checker reads the validator's status ─────────────────────────────────────────────────────────────
section "assets: the conformance checker reads the validator's status as well as its findings"
CHECKER="${CHECKOUT}/tools/checkers/assets-conformance.sh"
if [[ ! -r "${CHECKER}" ]]; then
    skip "the conformance checker" "no checkout holds ${CHECKER}"
else
    FIX="${TESTDIR}/fixtures"
    # fixture <pass|fail> <name> <conf-line>... : a fixture holding the set acme, built to pass every rule base
    # enforces, with a fixture.conf of the lines given.
    fixture() {
        local dir="${FIX}/$1/$2"
        shift 2
        rm -rf "${dir}"; mkdir -p "${dir}"; asset_signing_build_set "${dir}" acme
        printf '%s\n' "$@" > "${dir}/fixture.conf"
    }
    # conformance <prelude> : the checker's run_fixtures over FIX, read out of the checker into a shell where <prelude>
    # ran after the library loaded; the output in CHECK_OUT, the status in CHECK_RC.
    conformance() {
        CHECK_RC=0
        # shellcheck disable=SC2016  # the $1 to $5 are the inner shell's
        CHECK_OUT="$(bash -c 'set -euo pipefail; LIB_DIR="$1"; source "${LIB_DIR}/assets.lib.sh"
            die() { printf "%s\n" "$*"; exit 1; }
            eval "$2"; eval "$3"; eval "$4"; run_fixtures "$5"' _ "${LIB%/*}" "$(extract_function "${CHECKER}" selected)" \
            "$(extract_function "${CHECKER}" run_fixtures)" "$1" "${FIX}" 2>&1)" || CHECK_RC=$?
    }
    fixture pass acme expect=pass
    fixture fail kind.shape expect=fail rule=kind.shape
    : > "${FIX}/fail/kind.shape/acme/skills/notes.md"
    conformance :
    if [[ "${CHECK_RC}" == 0 && "${CHECK_OUT}" == *"2 fixtures checked, 0 disagree"* ]]; then
        pass "control: a pass fixture and a fail fixture agree, exit 0"
    else
        fail "control: rc ${CHECK_RC}: ${CHECK_OUT:0:300}"
    fi
    # disagrees <what> <name> <substring> : the last run exited 1 with a FAIL line for fixture <name> carrying
    # <substring>.
    disagrees() {
        if [[ "${CHECK_RC}" == 1 ]] && grep -q "^FAIL $2: .*$3" <<< "${CHECK_OUT}"; then
            pass "$1: a disagreement, exit 1"
        else
            fail "$1: rc ${CHECK_RC}: ${CHECK_OUT:0:300}"
        fi
    }
    fixture pass acme expect=pass profile=unsupported; conformance :
    disagrees "a pass fixture under profile=unsupported" acme "profile=unsupported"
    fixture pass acme expect=pass; conformance 'ai_tools_assets_validate_set() { return 2; }'
    disagrees "a validator that prints nothing and returns 2" acme "status 2"
    conformance 'ai_tools_assets_validate_set() { printf "kind.shape\tskills/notes.md\tx\n"; return 3; }'
    disagrees "the expected finding, then a return of 3" kind.shape "status 3"
    fixture pass acme rule=none; conformance :
    disagrees "a fixture.conf without expect" acme "expect=(absent)"
fi

# ── Marker-aware code meets a view link ──────────────────────────────────────────────────────────────────────────────
section "assets: a managed-copy site skips a symlink"
fresh
# shellcheck disable=SC2016
withdraw_out="$(bash -c 'source "$1"; ai_tools_withdraw_asset "$2" skills acme-pdf "test"; echo "rc=$?"' _ "${MANAGED_LIB}" "${HOME_DIR}" 2>&1)"
if [[ "${withdraw_out}" == *rc=0* && "${withdraw_out}" != *kept* ]] && linked skills/acme-pdf "${PKG}/acme/skills/acme-pdf"; then
    pass "ai_tools_withdraw_asset returns 0 over a resolver link without a move or a report"
else
    fail "ai_tools_withdraw_asset over a link: ${withdraw_out}"
fi
mkdir -p "${TESTDIR}/managed"; printf -- '---\nx-ai-tools-managed: true\n---\n' > "${TESTDIR}/managed/SKILL.md"
ln -s "${TESTDIR}/managed" "${TESTDIR}/managed-link"
# shellcheck disable=SC2016
if bash -c 'source "$1"; _ai_tools_asset_is_stale_copy "$2" "$3"' _ "${MANAGED_LIB}" "${TESTDIR}/managed" "${TESTDIR}/managed-link"; then
    fail "_ai_tools_asset_is_stale_copy reads a symlink as a stale copy"
else
    pass "_ai_tools_asset_is_stale_copy skips a symlink"
fi

finish
