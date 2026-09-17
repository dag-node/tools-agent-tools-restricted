#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/codex-package.sh
# Unit test for the files ai-tools-agents-codex-restricted ships, held to the seams they plug into before any host
# installs them: the manifest to the readers that parse it, the fragment to the session-env contract, the wrapper
# to the gate library's three calls, the two managed TOML files to the shape codex was measured to accept, and the two
# hook adapters to the payload shapes codex sends. Each property is one a host would otherwise discover at the first
# launch:
#
#   1. THE MANIFEST'S TWO PATHS AGREE. `launcher_target` names the file the launcher is re-linked
#      at and `entrypoint_fcontext` names the file that takes the exec label; the re-link refuses
#      a target the pattern does not cover, so a manifest whose two keys drift does not launch.
#      Driven through the real re-link on a fixture version directory.
#   2. THE FRAGMENT PINS ONE VARIABLE AND DOES NOTHING ELSE. It runs in ai-tools-run's own shell.
#   3. THE WRAPPER IS THE GATE LIBRARY'S THREE CALLS IN ORDER, and refuses when the library will
#      not load, citing the code claude's wrapper defines for the same situation.
#   4. A BARE KEY SITS AHEAD OF THE FIRST TABLE HEADER. A bare key written after one belongs to that
#      table and is silently ignored -- the shape two harness runs measured a pin as "accepted"
#      with. Read with a TOML parser, so the assertion is on what codex reads, not on the text.
#   5. THE HOOK DECLARATIONS NAME SHIPPED SCRIPTS, and the adapters read codex's keys: `Bash`
#      carries tool_input.command, `apply_patch` carries the patch text and no file_path, so
#      the paths come from the patch's own `*** ... File:` lines.
#
# Pure: every library and file is read from the checkout, the fixtures are trees this file builds, and no host state is
# read or written. Run without root. The re-link fixture needs the executable bit VISIBLE (a noexec mount hides it),
# so that one section takes agent-installs.sh's probe and fallback and skips where neither qualifies.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${ROOT}/src"
LIB_DIR="${SRC}/usr/local/lib/ai-tools"
[[ -d "${SRC}" ]] || { LIB_DIR="/usr/local/lib/ai-tools"; SRC=""; }

section "codex package: manifest, fragment, wrapper, managed files, hook adapters (unit)"

if [[ -z "${SRC}" ]]; then
    skip "codex package" "not a source checkout (no ${ROOT}/src); the package files are read from the tree"
    finish; exit
fi

readonly MANIFEST="${LIB_DIR}/agents.d/codex.conf"
readonly FRAGMENT="${LIB_DIR}/session-env.d/codex.env.sh"
readonly WRAPPER="${SRC}/usr/local/bin/codex.sh"
readonly REQUIREMENTS="${SRC}/etc/codex/requirements.toml"
readonly MANAGED_CONFIG="${SRC}/etc/codex/managed_config.toml"
readonly HOOK_SRC_DIR="${SRC}/opt/ai-tools/agents/codex"
readonly HOOK_LIVE_DIR="/opt/ai-tools/.codex"

for f in "${MANIFEST}" "${FRAGMENT}" "${WRAPPER}" "${REQUIREMENTS}" "${MANAGED_CONFIG}" \
         "${HOOK_SRC_DIR}/post-tool-hook.sh" "${HOOK_SRC_DIR}/session-hook.sh"; do
    if [[ ! -r "${f}" ]]; then
        fail "package file missing from the tree: ${f}"; finish; exit
    fi
done

# shellcheck source=../../src/usr/local/lib/ai-tools/conf.lib.sh
# shellcheck source=../../src/usr/local/lib/ai-tools/providers.lib.sh
# shellcheck source=../../src/usr/local/lib/ai-tools/relabel.lib.sh
if ! source "${LIB_DIR}/conf.lib.sh" \
        || ! source "${LIB_DIR}/providers.lib.sh" \
        || ! source "${LIB_DIR}/relabel.lib.sh" \
        || ! declare -F ai_tools_launcher_target_valid   >/dev/null 2>&1 \
        || ! declare -F ai_tools_relink_launcher         >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_sweeps_at_exit    >/dev/null 2>&1 \
        || ! declare -F ai_tools_entrypoint_fcontext_valid >/dev/null 2>&1 \
        || ! declare -F ai_tools_agent_config_dir_valid  >/dev/null 2>&1; then
    fail "could not source the libraries the manifest is read with"; finish; exit
fi

mktestdir

# field <key>: the manifest's value for <key>, through the parser every reader uses.
field() { ai_tools_conf_get "${MANIFEST}" "$1"; }

# ── 1. The manifest ───────────────────────────────────────────────────────────────────────────
section "codex.conf: what the readers parse out of it"
[[ "$(field launcher)" == "codex" ]] \
    && pass "launcher=codex" || fail "launcher is '$(field launcher)', expected codex"
[[ "$(field npm_package)" == "@openai/codex" ]] \
    && pass "npm_package=@openai/codex" || fail "npm_package is '$(field npm_package)'"
[[ "$(field default_enable)" == "no" ]] \
    && pass "default_enable=no: the package ships disabled" || fail "default_enable is '$(field default_enable)', expected no"
[[ "$(field display_name)" == "Codex" ]] \
    && pass "display_name=Codex" || fail "display_name is '$(field display_name)'"

# handback=none is the hybrid: the shim's session-end sweep runs, and the package's hooks add cadence on top.
if [[ "$(field handback)" == "none" ]] && ai_tools_agent_sweeps_at_exit "$(field handback)"; then
    pass "handback=none: ai-tools-run sweeps at session end (the hooks are cadence, not the guarantee)"
else
    fail "handback is '$(field handback)' or does not switch the shim's sweep on"
fi

for key in config_dir memory_file; do
    if ai_tools_agent_config_dir_valid "$(field "${key}")"; then
        pass "${key}=$(field "${key}") is one plain component under the sandbox home"
    else
        fail "${key}='$(field "${key}")' is not a valid single component"
    fi
done
[[ "$(field config_dir)" == ".codex" ]] || fail "config_dir is '$(field config_dir)', expected .codex (the fragment pins CODEX_HOME there)"
[[ "$(field memory_file)" == "AGENTS.md" ]] || fail "memory_file is '$(field memory_file)', expected AGENTS.md (codex's global scope)"

# Codex reads skills from its admin scope (/etc/codex/skills) and has no subagent directory of claude's shape,
# so neither asset-directory key is declared; a value here would make the seeder place links in .codex that codex does
# not read.
for key in skills_dir subagents_dir release_manifest_url release_key release_fingerprint; do
    if ai_tools_conf_read "${MANIFEST}" "${key}"; then
        fail "${key} is set (${_ai_tools_conf_value}); the codex manifest declares no ${key}"
    else
        pass "${key} is not declared"
    fi
done

# The two managed files are declared, so the status reports compare the live copies against the shipped ones. Each
# declared path is a file the package ships under src/etc, read by basename -- a declared path with no shipped source is
# a status line that can only ever read `unknown`.
declare -a managed_declared=()
ai_tools_conf_split managed_declared "$(field managed_files)"
if [[ "${managed_declared[*]}" == "/etc/codex/requirements.toml /etc/codex/managed_config.toml" ]]; then
    pass "managed_files names the two files under /etc/codex, in the shipped order"
else
    fail "managed_files is '${managed_declared[*]}', expected the two /etc/codex files"
fi
for path in "${managed_declared[@]}"; do
    [[ -f "${SRC}/etc/codex/${path##*/}" ]] \
        && pass "managed file ${path} has its shipped source ${SRC}/etc/codex/${path##*/}" \
        || fail "managed file ${path} has no shipped source under ${SRC}/etc/codex"
done

# Enablement, through the real resolver over this manifest: the package ships disabled, an operator names it to enable
# it, and a manifest the trust predicate refuses stays disabled however operator.conf reads. The resolver trusts
# root-owned inputs only, so the fixtures are built where this file runs as root; unprivileged, the section skips.
section "codex.conf: enablement through the resolver (fails closed)"
if [[ "${EUID}" -ne 0 ]]; then
    skip "enablement rows" "the resolver trusts root-owned inputs only; run under sudo"
else
    en_dir="${TESTDIR}/agents.d"; mkdir -p "${en_dir}"; chmod 0755 "${en_dir}"
    install -m 0644 "${MANIFEST}" "${en_dir}/codex.conf"
    en_conf="${TESTDIR}/operator.conf"
    enabled_names() { AI_TOOLS_AGENTS_DIR="${en_dir}" AI_TOOLS_OPERATOR_CONF="$1" ai_tools_enabled_agents 2>/dev/null | cut -f1 | tr '\n' ' '; }
    printf 'OPERATORS="x"\n' > "${en_conf}"; chmod 0644 "${en_conf}"
    [[ "$(enabled_names "${en_conf}")" == "" ]] \
        && pass "AI_TOOLS_AGENTS unset: codex stays disabled (default_enable=no)" \
        || fail "codex resolved as enabled with AI_TOOLS_AGENTS unset: '$(enabled_names "${en_conf}")'"
    printf 'AI_TOOLS_AGENTS="codex"\n' > "${en_conf}"
    [[ "$(enabled_names "${en_conf}")" == "codex " ]] \
        && pass "AI_TOOLS_AGENTS=codex: codex resolves as enabled" \
        || fail "codex did not resolve as enabled when named: '$(enabled_names "${en_conf}")'"
    chmod 0664 "${en_dir}/codex.conf"
    en_warn="$(AI_TOOLS_AGENTS_DIR="${en_dir}" AI_TOOLS_OPERATOR_CONF="${en_conf}" ai_tools_enabled_agents 2>&1 >/dev/null)"
    [[ "$(enabled_names "${en_conf}")" == "" ]] \
        && pass "a group-writable codex.conf is skipped even when named: less access, never more" \
        || fail "an untrusted codex.conf still resolved as enabled"
    assert_msg MSG-M3A5 "${en_warn}" "the untrusted manifest is refused on stderr, not silently"
    chmod 0644 "${en_dir}/codex.conf"
fi

target="$(field launcher_target)"
pattern="$(field entrypoint_fcontext)"
if ai_tools_launcher_target_valid "${target}"; then
    pass "launcher_target passes the shape check"
else
    fail "launcher_target '${target}' is refused by ai_tools_launcher_target_valid"
fi
if ai_tools_entrypoint_fcontext_valid "${pattern}"; then
    pass "entrypoint_fcontext passes the containment check (anchored under ${AI_TOOLS_ENTRYPOINT_ROOT})"
else
    fail "entrypoint_fcontext '${pattern}' is refused by ai_tools_entrypoint_fcontext_valid"
fi
resolved_shape="${AI_TOOLS_ENTRYPOINT_ROOT}/v1.2.3/${target}"
if [[ "${resolved_shape}" =~ ${pattern} ]]; then
    pass "entrypoint_fcontext covers the file launcher_target names (the two keys agree)"
else
    fail "entrypoint_fcontext does not match ${resolved_shape}: the re-link would refuse this manifest"
fi

# The same agreement through the real re-link, on a version directory shaped like npm leaves it.
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}
FIXTURE_ROOT="${TESTDIR}"
if ! x_bit_visible "${FIXTURE_ROOT}"; then
    mk_fixture_dir FIXTURE_ROOT "${PROJECTS_HOME}" codexpackage 2>/dev/null || FIXTURE_ROOT=""
    [[ -n "${FIXTURE_ROOT}" ]] && chmod 0755 "${FIXTURE_ROOT}"
fi
if [[ -z "${FIXTURE_ROOT}" ]] || ! x_bit_visible "${FIXTURE_ROOT}"; then
    skip "re-link through the manifest's own keys" "no directory here reports a 0755 file as executable (a noexec mount)"
else
    ver="${FIXTURE_ROOT}/versions/node/v1.2.3"
    mkdir -p "${ver}/bin" "${ver}/lib/node_modules/@openai/codex/bin" "${ver}/${target%/*}"
    printf '#!/bin/sh\n' > "${ver}/lib/node_modules/@openai/codex/bin/codex.js"
    chmod 0755 "${ver}/lib/node_modules/@openai/codex/bin/codex.js"
    printf '#!/bin/sh\n' > "${ver}/${target}"; chmod 0755 "${ver}/${target}"
    ln -s "../lib/node_modules/@openai/codex/bin/codex.js" "${ver}/bin/codex"
    # The pattern is anchored at the real toolchain root; the fixture lives elsewhere, so the pattern's head is
    # rewritten onto the fixture root for this run alone -- ai_tools_entrypoint_fcontext_valid already held the real
    # head.
    fixture_pattern="${pattern/#\/opt\/ai-tools\/\\.nvm\/versions\/node/${FIXTURE_ROOT}/versions/node}"
    out="$(ai_tools_relink_launcher "${ver}" codex "${target}" "${fixture_pattern}" 2>"${TESTDIR}/relink.err")" && rc=0 || rc=$?
    if [[ "${rc}" -eq 0 && "${out}" == "linked" && "$(realpath -e "${ver}/bin/codex")" == "$(realpath -e "${ver}/${target}")" ]]; then
        pass "the re-link accepts the manifest's launcher_target under its entrypoint_fcontext: bin/codex -> the vendor binary"
    else
        fail "the re-link refused the manifest's own keys (rc ${rc}, out '${out}'): $(head -c 200 "${TESTDIR}/relink.err")"
    fi
fi

# ── 2. The fragment ───────────────────────────────────────────────────────────────────────────
section "codex.env.sh: one pin, the session-env contract"
fragment_out="$(bash -c '
    set -euo pipefail
    declare -a session_environment_options=() session_path_entries=()
    source "$1"
    printf "%s\n" "${session_environment_options[@]}"
    printf "PATH:%s\n" "${session_path_entries[@]+"${session_path_entries[@]}"}"
' _ "${FRAGMENT}" 2>&1)" && frc=0 || frc=$?
if [[ "${frc}" -eq 0 && "${fragment_out}" == $'--setenv=CODEX_HOME=/opt/ai-tools/.codex\nPATH:' ]]; then
    pass "the fragment appends exactly --setenv=CODEX_HOME=/opt/ai-tools/.codex and no PATH entry"
else
    fail "the fragment's effect is not the one pin (rc ${frc}): $(tr '\n' '|' <<<"${fragment_out}")"
fi
if ! grep -qE '^[^#]*\b(exit|exec|export|read)\b' "${FRAGMENT}"; then
    pass "the fragment does not exit, exec, export, or read stdin"
else
    fail "the fragment carries an exit/exec/export/read outside a comment: $(grep -nE '^[^#]*\b(exit|exec|export|read)\b' "${FRAGMENT}" | head -3 | tr '\n' '|')"
fi
[[ "$(field config_dir)" == ".codex" ]] && grep -q 'CODEX_HOME=/opt/ai-tools/.codex' "${FRAGMENT}" \
    && pass "the fragment's CODEX_HOME and the manifest's config_dir name the same directory" \
    || fail "the fragment's CODEX_HOME and the manifest's config_dir disagree"

# ── 3. The wrapper ────────────────────────────────────────────────────────────────────────────
section "codex.sh: the gate library's three calls, in order, and the fail-closed load"
if bash -n "${WRAPPER}" 2>"${TESTDIR}/wrapper.syntax"; then
    pass "codex.sh parses"
else
    fail "codex.sh does not parse: $(head -c 200 "${TESTDIR}/wrapper.syntax")"
fi
init_line="$(grep -n '^ai_tools_launch_init codex$' "${WRAPPER}" | cut -d: -f1 | head -1)"
gates_line="$(grep -n '^ai_tools_launch_gates "\$@"$' "${WRAPPER}" | cut -d: -f1 | head -1)"
session_line="$(grep -n '^ai_tools_launch_session "\$@"$' "${WRAPPER}" | cut -d: -f1 | head -1)"
if [[ -n "${init_line}" && -n "${gates_line}" && -n "${session_line}" \
        && "${init_line}" -lt "${gates_line}" && "${gates_line}" -lt "${session_line}" ]]; then
    pass "init codex -> gates \"\$@\" -> session \"\$@\", in that order, with no resolver between"
else
    fail "the three library calls are missing or out of order (init ${init_line:-none}, gates ${gates_line:-none}, session ${session_line:-none})"
fi
if ! grep -q 'claude-prompt\|claude-endpoint\|CLAUDE_' "${WRAPPER}"; then
    pass "the wrapper carries no claude-code launch input"
else
    fail "the wrapper names a claude-code input: $(grep -n 'claude-prompt\|claude-endpoint\|CLAUDE_' "${WRAPPER}" | head -2 | tr '\n' '|')"
fi
# The fail-closed load, driven: a copy whose library path points at an absent file must refuse with the twin code.
cp "${WRAPPER}" "${TESTDIR}/codex-nolib.sh"
sed "s|^readonly LAUNCH_LIB=.*|readonly LAUNCH_LIB=\"${TESTDIR}/no-such-lib.sh\"|" "${WRAPPER}" > "${TESTDIR}/codex-nolib.sh"
out="$(cd "${TESTDIR}" && bash "${TESTDIR}/codex-nolib.sh" --version 2>&1)" && wrc=0 || wrc=$?
if [[ "${wrc}" -eq 1 ]]; then
    pass "a wrapper whose gate library will not load exits 1"
else
    fail "a wrapper whose gate library will not load exited ${wrc}: $(head -c 200 <<<"${out}")"
fi
assert_msg MSG-R3Q4 "${out}" "the refusal cites MSG-R3Q4, the code claude's wrapper defines for the unloadable library"
grep -q '^codex: cannot load the launch gate library' <<<"${out}" \
    && pass "the refusal opens with the launcher's own name" \
    || fail "the refusal does not open with 'codex: cannot load ...': $(head -c 200 <<<"${out}")"

# ── 4. The managed files ──────────────────────────────────────────────────────────────────────
section "/etc/codex: the two managed files, as codex parses them"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import tomllib' 2>/dev/null; then
    skip "managed files" "python3 with tomllib (3.11+) not available to parse TOML"
else
    # toml_get <file> <dotted.key>: the value at that key as JSON, or "MISSING". A bare key that landed inside a table
    # is MISSING at the top level, which is the property this test exists for.
    toml_get() {
        python3 - "$1" "$2" <<'PY'
import json, sys, tomllib
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
node = doc
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        print("MISSING"); sys.exit(0)
    node = node[part]
print(json.dumps(node, sort_keys=True))
PY
    }
    for f in "${REQUIREMENTS}" "${MANAGED_CONFIG}"; do
        if python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "${f}" 2>"${TESTDIR}/toml.err"; then
            pass "$(basename "${f}") parses as TOML"
        else
            fail "$(basename "${f}") does not parse: $(head -c 200 "${TESTDIR}/toml.err")"
        fi
    done
    # req <dotted.key> <expected-json> <what>
    req() {
        local got; got="$(toml_get "${REQUIREMENTS}" "$1")"
        [[ "${got}" == "$2" ]] && pass "requirements.toml: $3" || fail "requirements.toml: $3 -- $1 is ${got}, expected $2"
    }
    req allowed_sandbox_modes '["read-only", "danger-full-access"]' "allowed_sandbox_modes lists read-only and the pin (a bare key, above every table)"
    req allowed_approval_policies '["never"]' "allowed_approval_policies = [never]"
    req allowed_login_methods '["chatgpt"]' "allowed_login_methods = [chatgpt]"
    req allow_managed_hooks_only 'true' "allow_managed_hooks_only = true: the managed hooks are the only hooks"
    req default_permissions '":danger-full-access"' "default_permissions names the pin's profile"
    req 'allowed_permission_profiles.:danger-full-access' 'true' "the profile table lists full access alone"
    req marketplaces.restrict_to_allowed_sources 'true' "marketplaces restricted with no allowed source"
    req hooks.managed_dir "\"${HOOK_LIVE_DIR}\"" "hooks.managed_dir is the agent's config directory"
    # Each declared event runs the shipped script it names, with the argument the script dispatches on.
    hook_cmd() { toml_get "${REQUIREMENTS}" "hooks.$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(h["command"] for e in d for h in e.get("hooks", [])))'; }
    hook_timeout() { toml_get "${REQUIREMENTS}" "hooks.$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(str(h.get("timeout","")) for e in d for h in e.get("hooks", [])))'; }
    declare -A want_cmd=(
        [SessionStart]="${HOOK_LIVE_DIR}/session-hook.sh session-start"
        [PostToolUse]="${HOOK_LIVE_DIR}/post-tool-hook.sh"
        [Stop]="${HOOK_LIVE_DIR}/session-hook.sh"
        [SessionEnd]="${HOOK_LIVE_DIR}/session-hook.sh session-end"
    )
    for ev in SessionStart PostToolUse Stop SessionEnd; do
        got="$(hook_cmd "${ev}" 2>/dev/null || true)"
        if [[ "${got}" == "${want_cmd[$ev]}" ]]; then
            pass "requirements.toml: ${ev} runs '${want_cmd[$ev]}'"
        else
            fail "requirements.toml: ${ev} runs '${got:-<none>}', expected '${want_cmd[$ev]}'"
        fi
        script="${got%% *}"; script="${script##*/}"
        [[ -n "${script}" && -r "${HOOK_SRC_DIR}/${script}" ]] \
            && pass "requirements.toml: ${ev}'s script ${script} ships in the package" \
            || fail "requirements.toml: ${ev} names ${script:-nothing}, which the package does not ship"
    done
    [[ "$(hook_timeout Stop)" == "600" ]] \
        && pass "requirements.toml: the Stop sweep has the 600 s timeout codex holds a hook to" \
        || fail "requirements.toml: Stop timeout is '$(hook_timeout Stop)', expected 600"
    [[ "$(toml_get "${REQUIREMENTS}" "hooks.SessionStart" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("matcher",""))')" == "startup|resume" ]] \
        && pass "requirements.toml: SessionStart matches startup|resume, the sources the unbounded pass acts on" \
        || fail "requirements.toml: SessionStart's matcher is not startup|resume"
    # cfg <dotted.key> <expected-json> <what>
    cfg() {
        local got; got="$(toml_get "${MANAGED_CONFIG}" "$1")"
        [[ "${got}" == "$2" ]] && pass "managed_config.toml: $3" || fail "managed_config.toml: $3 -- $1 is ${got}, expected $2"
    }
    cfg sandbox_mode '"danger-full-access"' "sandbox_mode is the pin (a bare key, above every table)"
    cfg approval_policy '"never"' "approval_policy = never"
    cfg check_for_update_on_startup 'false' "the in-session update check is off (nvm-update maintains the toolchain)"
    cfg agents.enabled 'false' "sub-agents off"
    cfg analytics.enabled 'false' "analytics off"
    cfg feedback.enabled 'false' "feedback off"
    cfg otel.exporter '"none"' "otel exporter none"
    cfg otel.trace_exporter '"none"' "otel trace exporter none"
    cfg otel.metrics_exporter '"none"' "otel metrics exporter none"
    cfg otel.log_user_prompt 'false' "otel does not log the prompt"
    cfg model_instructions_file 'MISSING' "the custom-prompt key ships commented (no prompt configured)"
    cfg openai_base_url 'MISSING' "the endpoint key ships commented (the built-in endpoint)"
    # An operator uncommenting a shipped key must land it at the top level: the commented key lines sit ahead
    # of the first table header, or they would become keys of that table and be ignored (the trap the harness met
    # twice). The live bare keys are held to the same placement by the parsed reads of req and cfg.
    for f in "${REQUIREMENTS}" "${MANAGED_CONFIG}"; do
        first_table="$(grep -n '^\[' "${f}" | head -1 | cut -d: -f1 || true)"
        last_commented="$(grep -nE '^#[a-z_]+ *=' "${f}" | tail -1 | cut -d: -f1 || true)"
        if [[ -z "${last_commented}" ]]; then
            pass "$(basename "${f}"): no commented key to place"
        elif [[ -n "${first_table}" && "${last_commented}" -lt "${first_table}" ]]; then
            pass "$(basename "${f}"): every commented key sits above the first table header"
        else
            fail "$(basename "${f}"): a commented key at line ${last_commented} follows the first table header at line ${first_table:-none}"
        fi
    done
fi
# A config header is read in a terminal, which does not reflow it: 72 columns, like the other operator-held files.
for f in "${REQUIREMENTS}" "${MANAGED_CONFIG}"; do
    wide="$(awk 'BEGIN{n=0} /^#/ && length($0) > 72 {n++} END{print n}' "${f}")"
    [[ "${wide}" -eq 0 ]] \
        && pass "$(basename "${f}"): every comment line holds to 72 columns" \
        || fail "$(basename "${f}"): ${wide} comment line(s) exceed 72 columns"
done

# ── 5. The hook adapters ──────────────────────────────────────────────────────────────────────
section "the hook adapters: codex's payload shapes"
if ! command -v jq >/dev/null 2>&1; then
    skip "hook adapters" "jq not available (the hooks parse their events with it)"
    finish; exit
fi
# Copies with the sandbox tokens substituted, in the testdir: the session hook derives its state files from its own
# location, so a copy keeps the checkout clean.
HOOKS="${TESTDIR}/hooks"; mkdir -p "${HOOKS}"
for h in post-tool-hook.sh session-hook.sh; do
    sed -e "s/@SANDBOX_USER@/${SANDBOX_USER}/g" -e "s/@SANDBOX_GROUP@/${SANDBOX_GROUP}/g" \
        "${HOOK_SRC_DIR}/${h}" > "${HOOKS}/${h}"
    if bash -n "${HOOKS}/${h}" 2>"${TESTDIR}/hook.syntax"; then
        pass "${h} parses"
    else
        fail "${h} does not parse: $(head -c 200 "${TESTDIR}/hook.syntax")"
    fi
done

# The payload shapes run 7 captured (the key sets are the measured ones; the values are this test's).
PROJECT="${TESTDIR}/project"; mkdir -p "${PROJECT}/src"
bash_event='{"cwd":"'"${PROJECT}"'","hook_event_name":"PostToolUse","model":"gpt-5","permission_mode":"bypassPermissions","session_id":"s1","tool_input":{"command":"git status --short"},"tool_name":"Bash","tool_response":{"exit_code":0},"tool_use_id":"t1","transcript_path":"/x","turn_id":"u1"}'
patch_text='*** Begin Patch\n*** Update File: src/a.txt\n@@\n-x\n+y\n*** Add File: b.txt\n+hi\n*** Delete File: gone.txt\n*** Update File: src/old.txt\n*** Move to: src/new.txt\n*** Add File: /abs/c.txt\n+z\n*** End Patch'
patch_event='{"cwd":"'"${PROJECT}"'","hook_event_name":"PostToolUse","model":"gpt-5","permission_mode":"bypassPermissions","session_id":"s1","tool_input":{"input":"'"${patch_text}"'"},"tool_name":"apply_patch","tool_response":{},"tool_use_id":"t2","transcript_path":"/x","turn_id":"u1"}'
patch_event_alt='{"cwd":"'"${PROJECT}"'","hook_event_name":"PostToolUse","tool_input":{"patch":"*** Begin Patch\n*** Add File: only.txt\n+1\n*** End Patch"},"tool_name":"apply_patch","session_id":"s1","permission_mode":"bypassPermissions","transcript_path":"/x","turn_id":"u1"}'
other_event='{"cwd":"'"${PROJECT}"'","hook_event_name":"PostToolUse","tool_input":{"query":"x"},"tool_name":"web_search","session_id":"s1","permission_mode":"bypassPermissions","transcript_path":"/x","turn_id":"u1"}'

# Source the adapter to reach its parsers (the guard at its end stops it before main). Its readonly constants land
# in this shell once, which is why this section runs last.
# shellcheck source=/dev/null
if ! source "${HOOKS}/post-tool-hook.sh" \
        || ! declare -F format_tool_call_record >/dev/null 2>&1 \
        || ! declare -F patch_written_paths >/dev/null 2>&1; then
    fail "post-tool-hook.sh cannot be sourced for its parsers"; finish; exit
fi

# record <event-json>: the record's parts, one per line (MESSAGE first).
record() { format_tool_call_record "$1" | tr '\037' '\n'; }

got="$(record "${bash_event}")"
if grep -qxF "tool=Bash cwd=${PROJECT} cmd=\"git status\" argc=3" <<<"${got}" \
        && grep -qxF "AI_TOOLS_CMD=git status" <<<"${got}" && grep -qxF "AI_TOOLS_ARGC=3" <<<"${got}" \
        && grep -qxF "AI_TOOLS_TOOL=Bash" <<<"${got}"; then
    pass "a Bash event records its two leading words and the word count, from tool_input.command"
else
    fail "a Bash event's record is wrong: $(tr '\n' '|' <<<"${got}")"
fi
got="$(record "${patch_event}")"
if grep -qxF "tool=apply_patch cwd=${PROJECT} path=src/a.txt files=6" <<<"${got}" \
        && grep -qxF "AI_TOOLS_PATH=src/a.txt" <<<"${got}" && grep -qxF "AI_TOOLS_TOOL=apply_patch" <<<"${got}"; then
    pass "an apply_patch event records the first path the patch names and the count of names"
else
    fail "an apply_patch event's record is wrong: $(tr '\n' '|' <<<"${got}")"
fi
got="$(record "${patch_event_alt}")"
grep -qxF "AI_TOOLS_PATH=only.txt" <<<"${got}" && ! grep -q 'files=' <<<"${got}" \
    && pass "the patch text is read under the tool_input.patch spelling too, and one file carries no count" \
    || fail "the tool_input.patch spelling is not read: $(tr '\n' '|' <<<"${got}")"
got="$(record "${other_event}")"
grep -qxF "tool=web_search cwd=${PROJECT} path=-" <<<"${got}" \
    && pass "a tool that writes no file records path=-" \
    || fail "an unknown tool's record is wrong: $(tr '\n' '|' <<<"${got}")"
ctrl_event='{"cwd":"/p","tool_name":"apply_patch","tool_input":{"input":"*** Add File: bad\u001bname.txt\n+1"}}'
got="$(record "${ctrl_event}")"
grep -qxF 'AI_TOOLS_PATH=bad?name.txt' <<<"${got}" \
    && pass "a control byte in a patched path is replaced before it reaches the trail" \
    || fail "a control byte survived into the record: $(tr '\n' '|' <<<"${got}" | od -c | head -2 | tr '\n' ' ')"

mapfile -t paths < <(patch_written_paths "${patch_event}")
want_paths=( "${PROJECT}/src/a.txt" "${PROJECT}/b.txt" "${PROJECT}/gone.txt" "${PROJECT}/src/old.txt" "${PROJECT}/src/new.txt" "/abs/c.txt" )
if [[ "${paths[*]}" == "${want_paths[*]}" ]]; then
    pass "patch_written_paths joins a relative path to cwd, keeps an absolute one, and reads Move to"
else
    fail "patch_written_paths printed: $(printf '%s|' "${paths[@]}")"
fi
[[ -z "$(patch_written_paths "${bash_event}")" && -z "$(patch_written_paths "${other_event}")" ]] \
    && pass "patch_written_paths prints nothing for a tool that is not apply_patch" \
    || fail "patch_written_paths printed paths for a non-patch event"
[[ -z "$(patch_written_paths 'not json')" ]] \
    && pass "patch_written_paths prints nothing for an unparsable event" \
    || fail "patch_written_paths printed something for an unparsable event"
# The handback loop over fixtures this user owns does not reach the socket (the owner guard) and returns 0.
printf 'y\n' > "${PROJECT}/src/a.txt"; printf 'hi\n' > "${PROJECT}/b.txt"
if hand_back_patch_paths "${patch_event}"; then
    pass "hand_back_patch_paths returns 0 over paths the sandbox account does not own (no call made)"
else
    fail "hand_back_patch_paths failed over operator-owned fixtures"
fi
# The whole script: an empty stdin is a no-op exit 0.
if bash "${HOOKS}/post-tool-hook.sh" </dev/null >/dev/null 2>&1; then
    pass "post-tool-hook.sh with no event on stdin exits 0"
else
    fail "post-tool-hook.sh with no event on stdin did not exit 0"
fi

# The session hook, in the modes that touch no root helper: a Stop sweep over an operator-owned tree does not find
# a path to hand back and advances its marker; session-end clears the clean-exit marker; a session-start whose source is
# not a fresh process exits before writing anything.
stop_event='{"cwd":"'"${PROJECT}"'","hook_event_name":"Stop","last_assistant_message":"done","model":"gpt-5","permission_mode":"bypassPermissions","session_id":"s1","stop_hook_active":false,"transcript_path":"/x","turn_id":"u1"}'
if bash "${HOOKS}/session-hook.sh" <<<"${stop_event}" >/dev/null 2>&1 && [[ -f "${HOOKS}/.sweep-marker" ]]; then
    pass "session-hook.sh stop: exits 0 and advances .sweep-marker beside itself"
else
    fail "session-hook.sh stop did not exit 0 or left no .sweep-marker in ${HOOKS}"
fi
printf '%s\n' "${PROJECT}" > "${HOOKS}/.session-active"
end_event='{"cwd":"'"${PROJECT}"'","hook_event_name":"SessionEnd","reason":"exit","session_id":"s1","transcript_path":"/x"}'
if bash "${HOOKS}/session-hook.sh" session-end <<<"${end_event}" >/dev/null 2>&1 && [[ ! -e "${HOOKS}/.session-active" ]]; then
    pass "session-hook.sh session-end: exits 0 and clears .session-active"
else
    fail "session-hook.sh session-end did not clear .session-active"
fi
compact_event='{"cwd":"'"${PROJECT}"'","hook_event_name":"SessionStart","model":"gpt-5","permission_mode":"bypassPermissions","session_id":"s1","source":"compact","transcript_path":"/x"}'
if bash "${HOOKS}/session-hook.sh" session-start <<<"${compact_event}" >/dev/null 2>&1 && [[ ! -e "${HOOKS}/.session-active" ]]; then
    pass "session-hook.sh session-start on source=compact: exits 0 without stamping .session-active"
else
    fail "session-hook.sh session-start on source=compact acted on a live process"
fi
out="$(bash "${HOOKS}/session-hook.sh" <<<'{"hook_event_name":"Stop"}' 2>&1)" && src_rc=0 || src_rc=$?
[[ "${src_rc}" -eq 0 && -z "${out}" ]] \
    && pass "session-hook.sh with no cwd exits 0 silently" \
    || fail "session-hook.sh with no cwd exited ${src_rc}: ${out}"
# The SessionStart reply carries the context under both spellings a codex release may read. The session hook is sourced
# in a shell of its own: its readonly constants share names with the adapter already sourced here.
reply="$(bash -c 'source "$1"; emit_session_context hello' _ "${HOOKS}/session-hook.sh" 2>/dev/null)"
[[ "$(jq -r '.additionalContext' <<<"${reply}")" == "hello" \
        && "$(jq -r '.hookSpecificOutput.additionalContext' <<<"${reply}")" == "hello" \
        && "$(jq -r '.hookSpecificOutput.hookEventName' <<<"${reply}")" == "SessionStart" ]] 2>/dev/null \
    && pass "emit_session_context carries the text as additionalContext at the top level and in hookSpecificOutput" \
    || fail "emit_session_context's reply is wrong: ${reply}"

finish
