#!/usr/bin/env bash
# selinux/diag-nvm-update.sh -- assert the SELinux posture around the sandbox's Node
# tree and the SYMLINK handback verb that nvm-update.sh uses to repoint
# /opt/ai-tools/bin/claude after a Node upgrade. Two invariants:
#   1. the agent's Node tree (.nvm/versions/node/*) is READ-ONLY to ai_tools_t -- the
#      agent must not rewrite its own toolchain mid-session. Node/claude updates are
#      the unconfined scheduled nvm-update timer's job, never the agent's; in-session
#      npm self-update is denied by design.
#   2. the SYMLINK handback verb resolves and repoints cleanly (the timer's last step),
#      which needs ai_tools_handback_t getattr on the ai_tools_exec_t entrypoint.
#
# RUN AS THE AGENT (ai-tools UID, ai_tools_t domain) from inside an approved project.
# Read-only except for one bridge call at the end (SYMLINK against the CURRENTLY ACTIVE
# versioned binary -- idempotent, exactly what a successful nvm-update run's last step does).
#
# PASS=N FAIL=0 means the posture is healthy. A section-2 FAIL means the node tree
# became agent-WRITABLE (an integrity regression -- it must stay read-only); a section-4
# FAIL means the SYMLINK verb is broken (the timer's repoint would fail with
# "failed to repoint ... via handback SYMLINK").

set -uo pipefail
IFS=$'\n\t'

note() { printf '\033[1;36m[diag]\033[0m %s\n' "$*"; }
step() { printf '\033[1;33m--- %s\033[0m\n' "$*"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; }
label_of() { stat -c '%C' "$1" 2>/dev/null | awk -F: '{print $3}'; }

########################################
# Preflight: must be confined -- otherwise this reproduces nothing
########################################
ctx="$(id -Z 2>/dev/null || true)"
case "${ctx}" in
  *:ai_tools_t:*) note "confined OK -- running as ${ctx}" ;;
  *) printf '[diag] ABORT: this process is %s, not ai_tools_t -- none of the denials below would reproduce unconfined.\n' "${ctx:-<no SELinux context>}" >&2
     exit 2 ;;
esac

########################################
# Resolve the active Node version and the paths in play
########################################
node_bin="$(readlink -f "$(command -v node)")"
ver_root="${node_bin%/bin/node}"
note "active Node root: ${ver_root}"

claude_link="/opt/ai-tools/bin/claude"
versioned_claude="${ver_root}/bin/claude"
exe="${ver_root}/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
pkg_dir="${ver_root}/lib/node_modules/@anthropic-ai/claude-code"
npm_dir="${ver_root}/lib/node_modules/npm"

########################################
# 1. Label survey
########################################
step "1. Label survey (expect: usr_t version root, bin_t for */bin, lib_t for lib/node_modules/**, ai_tools_exec_t only for claude.exe)"
for p in "${ver_root}" "${ver_root}/bin" "${versioned_claude}" "${ver_root}/lib" \
         "${ver_root}/lib/node_modules" "${pkg_dir}" "${exe}" "${claude_link}"; do
    printf '  %-92s %s\n' "${p}" "$(label_of "${p}")"
done

########################################
# 2. Write-access probes -- the node tree must stay READ-ONLY to the agent
#
# The sandbox's Node tree is deliberately left at its default usr_t/bin_t/lib_t, for
# which ai_tools_t holds only read access (files_read_usr_files / libs_read_lib_files /
# corecmd_exec_bin). The agent must NOT be able to write it -- a writable tree would let
# it rewrite its own program tree mid-session. So here a DENIED write is the healthy
# result (PASS) and a SUCCESSFUL write is a regression (FAIL): it means a writable label
# (e.g. ai_tools_home_t) leaked onto the tree. Only the carved-out ai_tools_home_t paths
# (.npm, .cache, .config, .local) are legitimately agent-writable -- the control probe.
########################################
step "2. Write-access probes -- the node tree MUST be read-only to the agent (a writable path is a regression)"
# probe_ro: a path that must be read-only to the agent -- DENIED is PASS, writable is FAIL.
probe_ro() {
    local dir="$1" f
    f="${dir}/.diag-write-test.$$"
    if ( : > "${f}" ) 2>/dev/null; then
        rm -f "${f}"
        fail "WRITABLE  ${dir}  ($(label_of "${dir}"))  -- expected read-only!"
    else
        pass "read-only ${dir}  ($(label_of "${dir}"))"
    fi
}
# probe_rw: a path that must stay agent-writable (the ai_tools_home_t control).
probe_rw() {
    local dir="$1" note_extra="${2:-}" f
    f="${dir}/.diag-write-test.$$"
    if ( : > "${f}" ) 2>/dev/null; then
        rm -f "${f}"
        pass "writable  ${dir}  ($(label_of "${dir}"))${note_extra:+  $note_extra}"
    else
        fail "DENIED    ${dir}  ($(label_of "${dir}"))${note_extra:+  $note_extra} -- expected writable!"
    fi
}
probe_ro "${pkg_dir}"
probe_ro "${npm_dir}"
probe_ro "${ver_root}/lib/node_modules"
probe_ro "${ver_root}/bin"
probe_ro "${ver_root}/lib"
probe_rw "${HOME}/.npm" "(control: ai_tools_home_t carve-out, must stay writable)"

########################################
# 3. Symlink-resolution chain -- the stat() the SYMLINK verb depends on
#
# ai-tools-claude-symlink (root, ai_tools_handback_t) does `[[ -e TARGET ]]`, which
# stat()s through the versioned bin/claude symlink to its resolved end, claude.exe
# (ai_tools_exec_t). This step runs the identical chain from ai_tools_t (which holds
# libs_read_lib_files + the entrypoint grant) as a sanity check that the chain itself
# is sound. ai_tools_handback_t is granted getattr on ai_tools_exec_t in ai_tools.te,
# so its own [[ -e ]] resolves too -- section 4 exercises that path live through the
# bridge. (A denied getattr there silently reports false -- the swallowed-EACCES shape
# -- and the helper fails closed with "target does not exist".)
########################################
step "3. Symlink-resolution chain (same stat() chain ai-tools-claude-symlink follows, run from ai_tools_t)"
if [[ -e "${versioned_claude}" ]]; then
    pass "[[ -e ${versioned_claude} ]] resolves OK from ai_tools_t -- chain is sound; libs_read_lib_files covers it here"
else
    fail "[[ -e ${versioned_claude} ]] does not resolve even from ai_tools_t -- a broader break than the handback-domain gap"
fi
note "resolves to: $(readlink -f "${versioned_claude}" 2>/dev/null || echo '<unresolvable>')  ($(label_of "${exe}"))"
note "ai_tools_handback_t holds getattr on this type -- section 4 confirms its [[ -e ]] resolves live"

########################################
# 4. Live SYMLINK verb through the handback bridge
#
# Idempotent: repoints the stable symlink at the CURRENTLY ACTIVE versioned
# binary -- exactly nvm-update.sh's last step, and a no-op for this running
# session (claude_link already resolves here). A clean OK proves the bridge AND
# ai_tools_handback_t's policy are sufficient end-to-end; "target does not
# exist" is the live reproduction of the gap that makes nvm-update.sh die with
# "failed to repoint ... via handback SYMLINK" -> "ai-tools update failed".
########################################
step "4. Live SYMLINK verb (/usr/local/bin/ai-tools-handback-client SYMLINK ...)"
if out="$(/usr/local/bin/ai-tools-handback-client SYMLINK "${versioned_claude}" 2>&1)"; then
    pass "SYMLINK verb OK -- ${out}"
else
    fail "SYMLINK verb FAILED -- ${out}"
fi

########################################
# Summary
########################################
step "Summary"
note "PASS=${PASS}  FAIL=${FAIL}"
note "Section 2 FAIL = the node tree became agent-writable (integrity regression -- it"
note "must stay read-only). Section 4 FAIL = the SYMLINK verb is broken, so the timer's"
note "repoint dies with \"failed to repoint ... via handback SYMLINK\"."
note "For any FAIL, pull the AVCs: ausearch -m avc -ts recent"
[[ ${FAIL} -eq 0 ]]
