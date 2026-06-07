#!/usr/bin/env bash
# selinux/diag-nvm-update.sh -- diagnose the SELinux gaps that block the sandbox's
# own Node/npm self-management: claude's internal auto-update, AI_TOOLS_GLOBAL_TOOLS
# install/update, and the SYMLINK handback verb nvm-update.sh uses to repoint
# /opt/ai-tools/bin/claude after a Node upgrade.
#
# RUN AS THE AGENT (ai-tools UID, ai_tools_t domain) from inside an approved
# project. Read-only except for one bridge call at the end (SYMLINK against the
# CURRENTLY ACTIVE versioned binary -- idempotent, exactly what a successful
# nvm-update run's last step does).
#
# Pairs with the [[selinux-enforcing-status]] memory's nvm-update/npm-prefix
# findings: this script reproduces both gaps on demand so a policy fix can be
# verified by re-running it (PASS=N FAIL=0 means both are closed).

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
# 2. Write-access probes -- the npm-prefix gap
#
# npm install -g / npm update -g (claude's own auto-update, and any
# AI_TOOLS_GLOBAL_TOOLS package) must be able to write here -- it is the
# sandbox's OWN npm-managed tree, owned ai-tools:ai-tools. But ai_tools_t only
# holds libs_read_lib_files / files_read_usr_files (read-only) for usr_t/lib_t;
# only the carved-out ai_tools_home_t paths (.npm, .cache, .config, .local) are
# agent-writable. A FAIL here is the live reproduction of claude's own
# "Auto-update failed: no write permission to npm prefix".
########################################
step "2. Write-access probes in the npm prefix (expect FAIL until a writable label is carved out for this tree)"
probe_write() {
    local dir="$1" note_extra="${2:-}" f
    f="${dir}/.diag-write-test.$$"
    if ( : > "${f}" ) 2>/dev/null; then
        rm -f "${f}"
        pass "write OK     ${dir}  ($(label_of "${dir}"))${note_extra:+  $note_extra}"
    else
        fail "write DENIED ${dir}  ($(label_of "${dir}"))${note_extra:+  $note_extra}"
    fi
}
probe_write "${pkg_dir}"
probe_write "${npm_dir}"
probe_write "${ver_root}/lib/node_modules"
probe_write "${ver_root}/bin"
probe_write "${ver_root}/lib"
probe_write "${HOME}/.npm" "(control: ai_tools_home_t carve-out, should PASS)"

########################################
# 3. Symlink-resolution chain -- where the SYMLINK-verb gap actually lives
#
# ai-tools-claude-symlink (root, ai_tools_handback_t) does `[[ -e TARGET ]]`,
# which stat()s through the versioned bin/claude symlink to its resolved end,
# claude.exe (ai_tools_exec_t). ai_tools_handback_t holds NO grant on that type
# (grep ai_tools_exec_t selinux/ai_tools.te -- only ai_tools_t and the
# domtrans_pattern sources do), so that stat() is denied and bash's -e silently
# reports false -- the same swallowed-EACCES shape as the ai_tools_run_t getattr
# finding. This step runs the identical stat chain from ai_tools_t (which DOES
# hold libs_read_lib_files + the entrypoint grant) to confirm the chain itself
# is sound and the break is specific to the handback domain's missing grant.
########################################
step "3. Symlink-resolution chain (same stat() chain ai-tools-claude-symlink follows, run from ai_tools_t)"
if [[ -e "${versioned_claude}" ]]; then
    pass "[[ -e ${versioned_claude} ]] resolves OK from ai_tools_t -- chain is sound; libs_read_lib_files covers it here"
else
    fail "[[ -e ${versioned_claude} ]] does not resolve even from ai_tools_t -- a broader break than the handback-domain gap"
fi
note "resolves to: $(readlink -f "${versioned_claude}" 2>/dev/null || echo '<unresolvable>')  ($(label_of "${exe}"))"
note "ai_tools_handback_t has no grant on that type -- its [[ -e ]] on the same chain reports \"target does not exist\""

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
note "A FAIL in section 2 reproduces the live-console \"Auto-update failed: no write"
note "permission to npm prefix\"; a FAIL in section 4 reproduces nvm-update.sh's"
note "\"failed to repoint ... via handback SYMLINK\" -> \"ai-tools update failed\" chain."
note "Pull the AVCs for both windows (ausearch -m avc -ts recent) and let them"
note "dictate the exact grants -- see [[selinux-enforcing-status]] for what's known."
[[ ${FAIL} -eq 0 ]]
