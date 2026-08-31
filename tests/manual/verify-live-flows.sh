#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/manual/verify-live-flows.sh
# Operator-run verification of the project-lifecycle flows the automated suite cannot drive:
# claim, lockdown and unclaim end to end, as the operator, against a throwaway project, with
# `ai-tools --status` read from the vantage point that actually has to read it.
#
# Why this exists alongside tests/: run.sh is invoked as root and exercises the root helpers
# directly with its own allowlist override. The CLI runs as the OPERATOR, prompts on /dev/tty,
# sudo's for each root step, and writes the operator's real allowlist -- none of which a root-run
# hermetic suite can reproduce. So this script is not dispatched by run.sh and asserts what only a
# live run shows: that the flows complete, that a seal survives them, and that what the operator is
# told matches what happened.
#
# WHAT IT TOUCHES, AND WHAT IT WILL NOT. One workspace directory that `mktemp -d` creates under
# ${HOME} for this run, holding the project, a copy of it and a hardlink target; and the two
# operator registries the claim itself writes -- the allowlist and git safe.directory -- for that
# one project, removed again by the unclaim it then drives.
#
# It never adopts anything that already exists. Every path is one it created inside that fresh
# workspace, and removal refuses any path that is not inside it, so there is no input -- a stale
# directory, an unset variable, a symlink swapped in -- that can point the cleanup at something
# else. It runs no `sudo rm`: nothing it does needs root to undo.
#
# The single exception is --for-drill, which is opt-in for exactly that reason: it creates one
# project in the shared clone area, owned by another operator, and deletes it again through
# --project-remove. Nothing else this script does reaches outside the workspace.
#
# Nothing installed is modified: no unit started, stopped or enabled, no package state, no
# control-plane file, no policy, and no shared runtime state -- notably the updater's last-run
# stamp, which is READ and never written, because a check worth having is not worth breaking the
# reporting of a real update run for. That bounds what it can prove: a state the host does not
# already happen to be in is reported and skipped rather than manufactured, and the unit suites
# cover those from the other side, against fixtures they own.
#
# REQUIREMENTS. Run as an enrolled operator (in OPERATORS and in ai-ops), NOT as root and NOT
# under sudo -- the claim, lockdown and unclaim steps invoke sudo themselves, exactly as they do
# for any project, so run this where you can answer a password prompt. A completed install and
# provisioned toolchain are assumed.
#
# THE ONE DESTRUCTIVE CHECK IS OPT-IN. `ai-tools --stop` terminates EVERY agent session on the
# host, which is what it is for and cannot be proven any other way -- a stop that is scoped to a
# fixture proves the mechanism, not the rung. It runs only with --stop-all-drill, and only when a
# session is actually running; without the flag the section still exercises everything that is
# reversible (the dry run, the refusals, the trail). Run it when no session holds work you want.
#
# A SECOND OPT-IN COVERS --for. --project-create/--project-remove are the two verbs that touch the
# filesystem AS the operator they act for (`sudo -u <target>`), so proving them needs a second
# enrolled operator and a Runas grant -- neither of which this script may manufacture. With
# --for-drill it uses one that ALREADY exists on the host, and skips with the reason otherwise.
#
# It is the one section that writes OUTSIDE the workspace, and both halves of that are forced by
# what it is testing: the tree is created as the OTHER operator, who cannot write inside this
# operator's home, so it goes in the shared clone area (/var/opt/ai-tools/sandbox-projects, the one
# place on a stock install both reach) and is deleted again by the --project-remove that follows.
# That is also why it is opt-in: the tree is owned by that account, so if the removal does not
# complete, clearing the remains needs a privilege this script deliberately never takes -- it says
# so and prints the command.
#
# usage: tests/manual/verify-live-flows.sh [--keep] [--stop-all-drill] [--for-drill]
#   --keep             leave the workspace and its registry entries in place for inspection
#   --stop-all-drill   also TERMINATE EVERY RUNNING AGENT SESSION, to prove the incident ladder's stop
#                      rung on this host. Destructive by design; see section 8.
#   --for-drill        also drive --project-create/--project-remove --for another enrolled operator
#                      (section 3b). Needs a second operator to already exist; skipped if none does.

set -uo pipefail          # deliberately NOT -e: a failing check must be recorded, not fatal

KEEP=false
STOP_ALL_DRILL=false
FOR_DRILL=false
for a in "$@"; do
    case "${a}" in
        --keep)           KEEP=true ;;
        --stop-all-drill) STOP_ALL_DRILL=true ;;
        --for-drill)      FOR_DRILL=true ;;
        -h|--help) sed -n '3,65p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s (see --help)\n' "${a}" >&2; exit 2 ;;
    esac
done

readonly CLI=/usr/local/bin/ai-tools
readonly SANDBOX_GROUP=ai-tools
# The shared clone area: root-owned, carrying g:ai-ops:rwX plus a default ACL from the install, and
# deliberately outside the protected-paths set. Section 3b needs a parent BOTH operators can write,
# because --project-create --for runs its mkdir as the target.
readonly SANDBOX_ROOT=/var/opt/ai-tools/sandbox-projects
readonly STAMP=/var/opt/ai-tools/state/nvm-update.status
ME="$(id -un)"; MY_GROUP="$(id -gn)"
readonly ME MY_GROUP

# ── result vocabulary (this script prints its own; the harness is root-oriented) ──────────────
declare -i PASSED=0 FAILED=0 SKIPPED=0
declare -a FAILURES=()
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
[[ -t 1 ]] || { C_G=""; C_R=""; C_Y=""; C_D=""; C_B=""; C_0=""; }
section() { printf '\n%s── %s%s\n' "${C_B}" "$*" "${C_0}"; }
pass() { PASSED+=1; printf '  %sPASS%s  %s\n' "${C_G}" "${C_0}" "$*"; }
fail() { FAILED+=1; FAILURES+=("$*"); printf '  %sFAIL%s  %s\n' "${C_R}" "${C_0}" "$*"; }
skip() { SKIPPED+=1; printf '  %sSKIP%s  %s\n' "${C_Y}" "${C_0}" "$*"; }
note() { printf '        %s%s%s\n' "${C_D}" "$*" "${C_0}"; }
# sudo_why <what needs it> : say what the imminent "[sudo] password for ..." prompt is for. The
# CLI invokes sudo itself, once per root helper, so the prompt arrives with no context of its own
# and the operator would otherwise be typing a password blind. Printed immediately above the
# command that triggers it. sudo caches for a few minutes, so not every line is followed by a
# prompt -- which is why it names the step rather than promising one.
sudo_why() { printf '  %ssudo%s  %s\n' "${C_Y}" "${C_0}" "$*"; }
# check <description> <condition-cmd...> : run the condition, record pass/fail.
check() { local d="$1"; shift; if "$@"; then pass "${d}"; else fail "${d}"; fi; }
# has_acl <entry-prefix> <path> : 0 when the path carries an ACL entry starting <entry-prefix>.
has_acl() { getfacl -c -- "$2" 2>/dev/null | grep -q "^$1"; }
mode_of()  { stat -c '%a' "$1" 2>/dev/null; }
group_of() { stat -c '%G' "$1" 2>/dev/null; }
owner_of() { stat -c '%U:%G' "$1" 2>/dev/null; }

# ── preflight ────────────────────────────────────────────────────────────────────────────────
[[ "${ME}" == root ]] && { echo "run as your operator account, not root" >&2; exit 2; }
[[ -x "${CLI}" ]] || { echo "ai-tools is not installed at ${CLI}" >&2; exit 2; }
command -v getfacl >/dev/null 2>&1 || { echo "getfacl/setfacl are required" >&2; exit 2; }

# ── workspace: created, never adopted ────────────────────────────────────────────────────────
# Every path this script touches is one IT created, in a directory mktemp made fresh. Nothing
# pre-existing is reused, written into, or removed -- an existing path is a hard stop, not
# something to clean up, because a script that deletes what it did not create is one typo away
# from deleting the wrong thing. WORKSPACE is the single root; the removal rails below refuse any
# path that is not inside it.
[[ -n "${HOME:-}" && -d "${HOME}" ]] || { echo "HOME is unset or not a directory" >&2; exit 2; }
WORKSPACE="$(mktemp -d "${HOME}/ai-tools-verify-XXXXXXXX")" \
    || { echo "could not create a workspace under ${HOME}" >&2; exit 2; }
# mktemp makes it 700, which BLOCKS the sandbox account -- and a claim under a blocking ancestor
# offers to grant a traverse-only ACL on it. Inside the workspace that is ours to give, so make it
# traversable up front and the offer never arises here. 711 is enter-but-not-list, the same shape
# the claim's own grant has.
chmod 711 "${WORKSPACE}"
readonly WORKSPACE
readonly PROJ="${WORKSPACE}/project"
readonly COPY="${WORKSPACE}/project-copy"
readonly OUTSIDE="${WORKSPACE}/hardlink-target"

# safe_rm <path>: remove a path ONLY if every rail holds -- non-empty, absolute, strictly inside
# the workspace mktemp created for this run, and not a symlink (which rm -r would follow into by
# name if the path were swapped). Unprivileged, always: nothing here may need root to undo, and a
# `sudo rm -rf` in a cleanup path is exactly the shape of accident this guards against. A path it
# refuses is reported for the operator to look at, never forced.
safe_rm() {
    local p="${1:-}"
    [[ -n "${p}" ]]                        || return 0
    [[ "${p}" == "${WORKSPACE}/"* ]]       || { note "refusing to remove ${p} (outside the workspace)"; return 0; }
    [[ ! -L "${p}" && -e "${p}" ]]         || return 0
    rm -rf --one-file-system -- "${p}" 2>/dev/null \
        || note "could not remove ${p} -- remove it by hand"
}

cat <<EOF

${C_B}ai-tools live flow verification${C_0}
  operator  : ${ME} (group ${MY_GROUP})
  workspace : ${WORKSPACE}   ${C_D}(created just now, empty)${C_0}
              project, a copy of it, and a hardlink target inside it
  cleanup   : $(${KEEP} && echo "DISABLED (--keep) -- unclaim and remove the workspace by hand" || echo "the workspace only, on exit")

${C_B}What it changes${C_0}
  * the workspace above -- created by this run, and the only thing it ever removes
  * the allowlist and git safe.directory entries for that one project, added by the
    claim it drives and removed by the unclaim it then drives

${C_B}What it does not${C_0}
  * this script is NOT run with sudo and refuses to run as root; the claim, lockdown
    and unclaim steps invoke sudo themselves, as they do for any project -- every
    password prompt is preceded by a "sudo" line naming the step that needs it
  * nothing installed: no unit started, stopped or enabled, no package, no
    control-plane file, no policy. The updater's last-run stamp is READ, never written
  * no path outside the workspace is created, written or deleted -- an existing path
    is never adopted, and removal refuses anything that is not inside it

EOF
read -r -p "Proceed? [y/N] " _ans < /dev/tty || true
[[ "${_ans:-}" =~ ^[Yy] ]] || { rmdir "${WORKSPACE}" 2>/dev/null; echo "aborted"; exit 0; }

# No credential caching: each step asks when it needs to, under the line that says what it is
# for. A password entered up front buys fewer prompts at the cost of the one thing worth having
# here -- knowing which step you are authorizing.

cleanup() {
    local rc=$?
    if ${KEEP}; then
        note "--keep: left ${WORKSPACE} and its registry entries in place"
        note "        undo with: ai-tools --project-unclaim -y --group ${MY_GROUP} ${PROJ} && rm -rf ${WORKSPACE}"
        return "${rc}"
    fi
    # Drop the registry entries first (while the paths still exist, which the helper requires),
    # then remove what we created. Best-effort throughout: cleanup must not turn a reported
    # failure into a crash, and a half-built fixture must still be removable.
    "${CLI}" --project-unclaim -y --group "${MY_GROUP}" "${PROJ}" >/dev/null 2>&1 || true
    "${CLI}" --project-unclaim -y --group "${MY_GROUP}" "${COPY}" >/dev/null 2>&1 || true
    safe_rm "${PROJ}"; safe_rm "${COPY}"; safe_rm "${OUTSIDE}"
    # rmdir, not rm -r: it removes the workspace only if the removals above emptied it, so
    # anything unexpected still in there is preserved for the operator to look at.
    if rmdir "${WORKSPACE}" 2>/dev/null; then
        note "removed ${WORKSPACE} and the registry entries for it"
    else
        note "left ${WORKSPACE} in place (not empty) -- inspect and remove it by hand"
    fi
    return "${rc}"
}
trap cleanup EXIT

# ── fixture ──────────────────────────────────────────────────────────────────────────────────
# The shape the operator's sketch describes: a project with a directory sealed 700 holding a 600
# file, a secret-named file, ordinary content, and a git repo so the .git and safe.directory paths
# are exercised too.
#
# EVERY MODE IS PINNED, none inherited from the invoking shell's umask. Under a umask of 077 the
# project ROOT is born 700 -- owner-only -- and the claim then correctly seals the whole tree and
# grants nothing, so the ordinary half of this fixture (the half that must be opened up) silently
# stops existing and every later check has nothing to act on. What the fixture is FOR is the
# contrast between a sealed path and an ordinary one, so both sides are stated outright.
section "Fixture"
mkdir "${PROJ}"                                # fails if it exists; it cannot, mktemp just made ${WORKSPACE}
git -C "${PROJ}" init -q 2>/dev/null || true
git -C "${PROJ}" config user.email verify@example.invalid 2>/dev/null || true
git -C "${PROJ}" config user.name  "ai-tools verify"      2>/dev/null || true

mkdir "${PROJ}/src" "${PROJ}/prod-files"
printf 'API_TOKEN=not-a-real-secret\n' > "${PROJ}/prod-files/variables"
printf 'DB_PASSWORD=not-a-real-secret\n' > "${PROJ}/.env"   # secret by NAME
printf 'int main(void){return 0;}\n' > "${PROJ}/src/main.c"
: > "${OUTSIDE}"; ln -f "${OUTSIDE}" "${PROJ}/src/hardlinked" 2>/dev/null || true
# The ordinary half: group-accessible, so the claim has something to open up.
chmod 755 "${PROJ}" "${PROJ}/src"
chmod 644 "${PROJ}/.env" "${PROJ}/src/main.c" "${PROJ}/src/hardlinked"
# The sealed half: the operator's standing seal, by MODE, which the claim must honour.
chmod 600 "${PROJ}/prod-files/variables"
chmod 700 "${PROJ}/prod-files"
git -C "${PROJ}" add -A >/dev/null 2>&1 || true
git -C "${PROJ}" commit -qm "verification fixture" >/dev/null 2>&1 || true
note "modes pinned: project 755, src 755, files 644; prod-files 700 holding a 600 file"

# A sealed directory whose setgid belongs to a THIRD group -- the one piece of residue a claim
# keeps rather than strips, so the Review block has to say so. "Third" is relative to the claim's
# rule (neither the sandbox group nor the owner's own primary group), so one of the operator's own
# SECONDARY groups qualifies -- and chgrp to a group you are in needs no privilege, which keeps
# this script's own sudo use at zero. Without such a group the case is skipped, never faked with
# root.
THIRD_GROUP=""
for g in $(id -nG); do
    [[ "${g}" == "${MY_GROUP}" || "${g}" == "${SANDBOX_GROUP}" ]] && continue
    THIRD_GROUP="${g}"; break
done
if [[ -n "${THIRD_GROUP}" ]]; then
    mkdir "${PROJ}/third-party-sealed"
    # chgrp before chmod: chgrp can clear setgid, so the mode is set last and stands.
    chgrp "${THIRD_GROUP}" "${PROJ}/third-party-sealed"
    chmod 2700 "${PROJ}/third-party-sealed"
    note "sealed third-party fixture: ${PROJ}/third-party-sealed (group ${THIRD_GROUP}, 2700)"
else
    note "no secondary group to stand in for a third party -- that check will skip"
fi
note "fixture built"

# ── 1. claim ─────────────────────────────────────────────────────────────────────────────────
# AI_TOOLS_ASSUME_YES answers the default-YES questions (secret lockdown, .git normalization);
# -y answers the claim's own default-NO proceed prompt. The reachability opt-in is default-NO and
# stays declined, which is right here: nothing launches a session.
section "1. ai-tools --project-claim"
sudo_why "the claim's root steps: the secret scan and lockdown, then group+setgid, the ACL walk, and the SELinux label"
CLAIM_OUT="$(AI_TOOLS_ASSUME_YES=1 "${CLI}" --project-claim -y "${PROJ}" 2>&1)"; CLAIM_RC=$?
printf '%s\n' "${CLAIM_OUT}" | sed 's/^/        /'
check "the claim completes (rc=${CLAIM_RC})" test "${CLAIM_RC}" -eq 0

# The seal holds: mode unchanged, never pulled into the agent's group, no ACL grant of either kind.
check "sealed dir keeps mode 700"                  test "$(mode_of "${PROJ}/prod-files")" = 700
check "sealed dir stays out of ${SANDBOX_GROUP}"   test "$(group_of "${PROJ}/prod-files")" != "${SANDBOX_GROUP}"
if has_acl "group:${SANDBOX_GROUP}:" "${PROJ}/prod-files" || has_acl "user:${ME}:" "${PROJ}/prod-files"; then
    fail "sealed dir was granted an ACL entry: $(getfacl -c -- "${PROJ}/prod-files" | tr '\n' ' ')"
else
    pass "sealed dir carries neither the agent's nor the operator's ACL grant"
fi
check "sealed file keeps mode 600"                 test "$(mode_of "${PROJ}/prod-files/variables")" = 600
# ... while the rest of the tree IS opened up: that is what makes the seal a decision, not a bug.
check "ordinary dir is group ${SANDBOX_GROUP}"     test "$(group_of "${PROJ}/src")" = "${SANDBOX_GROUP}"
check "ordinary dir is setgid"                     test "$(mode_of "${PROJ}/src")" = 2770
check "ordinary file carries the agent ACL"        has_acl "group:${SANDBOX_GROUP}:" "${PROJ}/src/main.c"
# The secret-named file is quarantined to the operator's own group at 600 by the claim's gate.
check "secret-named .env locked to ${ME}:${MY_GROUP} 600" \
      test "$(owner_of "${PROJ}/.env") $(mode_of "${PROJ}/.env")" = "${ME}:${MY_GROUP} 600"

# The third-party setgid is KEPT, and the Review block says so.
if [[ -n "${THIRD_GROUP}" ]]; then
    check "third-party setgid survives the claim" \
          test "$(mode_of "${PROJ}/third-party-sealed") $(group_of "${PROJ}/third-party-sealed")" \
             = "2700 ${THIRD_GROUP}"
    if grep -qi 'setgid on an owner-only directory' <<<"${CLAIM_OUT}"; then
        pass "the Review block reports the third-party setgid it kept"
    else
        fail "the claim kept a third-party setgid without reporting it"
    fi
else
    skip "third-party setgid notice (no suitable group on this host)"
fi

# Did the claim actually open the ordinary half? Everything after this point acts on a granted
# tree -- the residue a seal strips, the group an unclaim hands back, the fingerprint --force
# looks for -- so a tree that was never granted produces a page of failures that all say the same
# thing and none of them about the code. Decide it once, here, and skip what depends on it.
TREE_CLAIMED=false
[[ "$(group_of "${PROJ}/src")" == "${SANDBOX_GROUP}" ]] && TREE_CLAIMED=true
if ! ${TREE_CLAIMED}; then
    note "the claim granted nothing on this tree -- the checks below have nothing to act on"
    note "if the project root reads as owner-only above, its mode was not what this fixture set"
fi

# ── 2. lockdown --dry-run then apply ─────────────────────────────────────────────────────────
# A directory born INSIDE the claimed tree inherits group, setgid and the default ACL; sealing it
# with chmod masks all three without removing any. That is the residue the seal pass strips.
section "2. ai-tools --lockdown (dry run, then apply)"
if ! ${TREE_CLAIMED}; then
    skip "the whole lockdown section (nothing was granted, so nothing inherits residue)"
else
# Two sealed fixtures, because the strip's three arms are not all reachable on one path. A
# directory grouped to the sandbox account cannot carry a setgid bit an OPERATOR set: the kernel
# clears S_ISGID on chmod when the caller is not in the file's group, and the operator is
# deliberately not in that one. So the sandbox-grouped fixture exercises the ACL and group arms,
# and a second fixture -- grouped to the operator's OWN group, where chmod does keep setgid --
# exercises the setgid arm. Both are states an operator reaches by hand; neither needs root.
SEALED_SBX="${PROJ}/inherited-then-sealed"       # group ai-tools: ACL + group arms
SEALED_OWN="${PROJ}/own-group-sealed"            # group <you>, setgid: the setgid arm

mkdir "${SEALED_SBX}"; : > "${SEALED_SBX}/data"  # born group ai-tools, setgid, default ACL
chmod 700 "${SEALED_SBX}"                        # the operator's seal (setgid goes with it)
mkdir "${SEALED_OWN}"; : > "${SEALED_OWN}/data"
chgrp "${MY_GROUP}" "${SEALED_OWN}"              # my own group: now chmod may keep setgid
chmod 2700 "${SEALED_OWN}"
BEFORE="$(mode_of "${SEALED_SBX}") $(group_of "${SEALED_SBX}")"
BEFORE_ACL="$(getfacl -c -- "${SEALED_SBX}" 2>/dev/null | tr '\n' ',')"
BEFORE_OWN="$(mode_of "${SEALED_OWN}") $(group_of "${SEALED_OWN}")"
note "sealed fixtures: ${BEFORE} (inherited group + default ACL), ${BEFORE_OWN} (setgid)"
# The residue has to actually be there, or "nothing was stripped" proves nothing about stripping.
[[ "${BEFORE}" == "700 ${SANDBOX_GROUP}" ]] \
    || fail "sandbox-grouped seal fixture is '${BEFORE}', want '700 ${SANDBOX_GROUP}' -- the checks below cannot mean anything"
[[ "${BEFORE_OWN}" == "2700 ${MY_GROUP}" ]] \
    || fail "own-group seal fixture is '${BEFORE_OWN}', want '2700 ${MY_GROUP}' -- the setgid arm is not exercised"

sudo_why "the lockdown helper, in preview mode (it still runs as root to read the whole tree)"
DRY_OUT="$(cd "${PROJ}" && "${CLI}" --lockdown -n "${PROJ}" 2>&1)"; DRY_RC=$?
printf '%s\n' "${DRY_OUT}" | sed 's/^/        /'
check "the dry run completes (rc=${DRY_RC})" test "${DRY_RC}" -eq 0
if grep -q 'inherited-then-sealed' <<<"${DRY_OUT}" && grep -q 'own-group-sealed' <<<"${DRY_OUT}"; then
    pass "the dry run names both sealed paths it would strip"
else
    fail "the dry run did not name both sealed paths (the seal pass was not fully previewed)"
fi
AFTER_DRY="$(mode_of "${SEALED_SBX}") $(group_of "${SEALED_SBX}")"
AFTER_DRY_ACL="$(getfacl -c -- "${SEALED_SBX}" 2>/dev/null | tr '\n' ',')"
check "the dry run changed nothing" \
      test "${BEFORE}|${BEFORE_ACL}|${BEFORE_OWN}" \
         = "${AFTER_DRY}|${AFTER_DRY_ACL}|$(mode_of "${SEALED_OWN}") $(group_of "${SEALED_OWN}")"

sudo_why "the lockdown helper, applying: locks the secret and strips the sealed path's residue"
LOCK_OUT="$(cd "${PROJ}" && "${CLI}" --lockdown -y "${PROJ}" 2>&1)"; LOCK_RC=$?
printf '%s\n' "${LOCK_OUT}" | sed 's/^/        /'
check "the lockdown completes (rc=${LOCK_RC})" test "${LOCK_RC}" -eq 0
# The strip may only ever REMOVE reach, so every arm is checked against a mode that did not widen.
# A path that came back wider (0670, say) would mean the ACL mask was recalculated upward -- a
# strip that grants, which is the failure `setfacl -n` exists to prevent.
check "the seal takes the sealed dir out of ${SANDBOX_GROUP}, mode unchanged at 700" \
      test "$(mode_of "${SEALED_SBX}") $(group_of "${SEALED_SBX}")" != "${BEFORE}"
check "  and its mode is still exactly 700" test "$(mode_of "${SEALED_SBX}")" = 700
if has_acl "group:${SANDBOX_GROUP}:" "${SEALED_SBX}" \
        || has_acl "default:group:${SANDBOX_GROUP}:" "${SEALED_SBX}"; then
    fail "the sealed dir still carries an agent ACL entry after the seal pass"
else
    pass "the seal removes both the access and default agent ACL entries"
fi
# The setgid arm, on the fixture that can carry one: 2700 -> 700, owner's rwx untouched.
check "the seal strips a setgid bit it may clear (2700 -> 700)" \
      test "$(mode_of "${SEALED_OWN}")" = 700
check "  and leaves that dir's group alone (it was never the agent's)" \
      test "$(group_of "${SEALED_OWN}")" = "${MY_GROUP}"
fi

# ── 2b. disable / enable: the park-and-restore round trip, on the REAL registry ───────────────
# Runs while the project is still claimed, and needs no sudo at all: the pair edits one line of
# this operator's own allowlist. That is exactly why it belongs in a live run rather than only in
# the hermetic suites -- what it proves is that the edit lands in the FILE the launch gate reads,
# at the position the operator left it, and comes back byte-identical.
section "2b. ai-tools --project-disable / --project-enable"
AL="${HOME}/.config/ai-tools/allowed-projects"
if [[ ! -r "${AL}" ]]; then
    skip "the park/restore round trip (no readable allowlist at ${AL})"
elif ! ${TREE_CLAIMED}; then
    skip "the park/restore round trip (the claim did not complete, so there is no entry to park)"
else
    AL_BEFORE="$(cat "${AL}")"
    AL_LINE_BEFORE="$(grep -nxF "${PROJ}" "${AL}" | cut -d: -f1 | head -n1)"
    DIS_OUT="$("${CLI}" --project-disable "${PROJ}" 2>&1)"; DIS_RC=$?
    check "the disable completes (rc=${DIS_RC})" test "${DIS_RC}" -eq 0
    if grep -qxF "!${PROJ}" "${AL}"; then
        pass "the entry is parked in the operator's real allowlist"
    else
        fail "the entry was not parked: $(printf '%s' "${DIS_OUT}" | tail -2 | tr '\n' ' ')"
    fi
    AL_LINE_AFTER="$(grep -nxF "!${PROJ}" "${AL}" | cut -d: -f1 | head -n1)"
    check "it kept its line number (${AL_LINE_BEFORE:-?} -> ${AL_LINE_AFTER:-?})" \
          test "${AL_LINE_BEFORE:-x}" = "${AL_LINE_AFTER:-y}"
    # The consequence an operator has to be told about, since it is the one that costs data:
    # while parked, the handback no longer restores files written under this path.
    check "the disable says the ownership handback stops" grep -qi 'handback' <<<"${DIS_OUT}"

    # A parked project is not an unclaimed one, and the verbs that would silently no-op say so.
    REC_OUT="$("${CLI}" --reclaim "${PROJ}" 2>&1)"; REC_RC=$?
    if [[ "${REC_RC}" -ne 0 ]] && ! grep -qi 'not a claimed project' <<<"${REC_OUT}"; then
        pass "--reclaim over the parked project does not report it as unclaimed"
    else
        fail "--reclaim called the parked project unclaimed: $(printf '%s' "${REC_OUT}" | tail -2 | tr '\n' ' ')"
    fi

    ENA_OUT="$("${CLI}" --project-enable "${PROJ}" 2>&1)"; ENA_RC=$?
    if [[ "${ENA_RC}" -eq 0 ]]; then
        pass "the enable completes"
    else
        fail "the enable failed (rc=${ENA_RC}): $(printf '%s' "${ENA_OUT}" | tail -2 | tr '\n' ' ')"
    fi
    if [[ "$(cat "${AL}")" == "${AL_BEFORE}" ]]; then
        pass "the round trip left the allowlist byte-identical"
    else
        fail "the round trip changed the allowlist -- diff it against what you had"
    fi
fi

# ── 3b. --for on --project-create / --project-remove (opt-in) ─────────────────────────────────
# The two verbs that act on the FILESYSTEM as the operator they run for, which is a sudoers
# question of its own (Runas), separate from the ai-tools helper grants. Nothing hermetic can
# prove it: it needs a second enrolled operator, and enrolling one would modify the host.
#
# So this uses one that already exists, and is opt-in because the tree it builds is owned by that
# account -- if the removal does not complete, clearing it needs a privilege this script never
# takes. Without --for-drill the section still reports whether the host COULD run it.
section "3b. --for on --project-create / --project-remove"
OTHER_OP=""
if [[ -r /etc/ai-tools/operator.conf ]]; then
    while IFS= read -r cand; do
        [[ -n "${cand}" && "${cand}" != "${ME}" && "${cand}" != "ai-tools" && "${cand}" != root ]] || continue
        id -u "${cand}" >/dev/null 2>&1 || continue
        OTHER_OP="${cand}"; break
    done < <(sed -n 's/^[[:space:]]*OPERATORS[[:space:]]*=[[:space:]]*//p' /etc/ai-tools/operator.conf \
             | tr -d '"'"'"'"' | tr ',' ' ' | tr ' ' '\n')
fi
if [[ -z "${OTHER_OP}" ]]; then
    skip "--for create/remove (no second enrolled operator on this host)"
    note "enrol one with: sudo ai-tools-admin operator add <user>   -- then re-run with --for-drill"
elif ! ${FOR_DRILL}; then
    skip "--for create/remove (would act for ${OTHER_OP}; re-run with --for-drill)"
    note "the run would create a tree owned by ${OTHER_OP} and delete it again"
else
    # WHERE the project goes is the first thing this drill teaches. --project-create --for runs
    # `mkdir` AS the target, so the parent must be a directory that operator can write -- and the
    # invoker's own home is exactly what that is not (0700, and owned by someone else). Putting it
    # there fails with a bare "Permission denied" from mkdir, which is the same reachability rule
    # the claim enforces for the sandbox account, arriving one layer earlier.
    #
    # The shared sandbox area is the one place on a stock install that both operators reach: it
    # carries g:ai-ops:rwX plus a default ACL, applied at install, and is deliberately outside the
    # protected-paths set. If this host has not got it, the drill skips rather than inventing a
    # location.
    if [[ ! -d "${SANDBOX_ROOT}" ]]; then
        skip "--for create/remove (${SANDBOX_ROOT} does not exist on this host)"
    elif [[ ! -w "${SANDBOX_ROOT}" ]]; then
        skip "--for create/remove (${SANDBOX_ROOT} is not writable by ${ME}; the ai-ops ACL is what makes it shared)"
    else
        FOR_PROJ="${SANDBOX_ROOT}/for-drill-$$-${OTHER_OP}"
        note "the project goes in the shared area, not the workspace: it is created AS ${OTHER_OP},"
        note "who cannot write inside ${HOME}"
        sudo_why "creating a project AS ${OTHER_OP} (sudo -u), and its claim's root steps"
        FC_OUT="$("${CLI}" --project-create --for "${OTHER_OP}" "${FOR_PROJ}" 2>&1)"; FC_RC=$?
        printf '%s\n' "${FC_OUT}" | sed 's/^/        /'
        if grep -qi 'holds no sudo grant to run' <<<"${FC_OUT}"; then
            # The refusal this section exists to be able to see: helper grants are not a Runas
            # grant, and a host can give every ai-tools helper and still restrict which accounts
            # you may act as. It must fire BEFORE anything is created.
            pass "the Runas refusal fires up front, naming the account and the command"
            check "and nothing was created" test ! -e "${FOR_PROJ}"
        elif [[ "${FC_RC}" -ne 0 ]]; then
            fail "the create failed (rc=${FC_RC}) -- see the output above"
            note "a bare 'Permission denied' from mkdir means ${OTHER_OP} cannot write ${SANDBOX_ROOT}"
            skip "the rest of the --for drill (there is no tree to act on)"
        else
            pass "the create completes"
            check "the tree exists"                test -d "${FOR_PROJ}"
            check "and it is owned by ${OTHER_OP}" test "$(stat -c '%U' "${FOR_PROJ}" 2>/dev/null)" = "${OTHER_OP}"
            note "ownership is the point: a claim FOR an operator over a tree they do not own grants nothing"

            # The cross-operator half of the enable/disable pair: the invoker cannot even read
            # that registry, so both go through the ai-tools-allowlist root helper.
            for pair_verb in --project-disable --project-enable; do
                PAIR_OUT="$("${CLI}" "${pair_verb}" --for "${OTHER_OP}" "${FOR_PROJ}" 2>&1)"; PAIR_RC=$?
                if [[ "${PAIR_RC}" -eq 0 ]]; then
                    pass "${pair_verb} --for ${OTHER_OP} completes (through the root helper)"
                else
                    fail "${pair_verb} --for failed (rc=${PAIR_RC}): $(printf '%s' "${PAIR_OUT}" | tail -2 | tr '\n' ' ')"
                fi
            done

            sudo_why "deleting that project AS ${OTHER_OP}"
            FR_OUT="$("${CLI}" --project-remove --for "${OTHER_OP}" -y "${FOR_PROJ}" 2>&1)"; FR_RC=$?
            printf '%s\n' "${FR_OUT}" | sed 's/^/        /'
            if [[ "${FR_RC}" -eq 0 ]] && [[ ! -e "${FOR_PROJ}" ]]; then
                pass "the remove completes and the tree is gone"
            else
                fail "the removal did not complete (rc=${FR_RC}) -- clear it yourself:"
                note "sudo rm -rf ${FOR_PROJ}    # owned by ${OTHER_OP}, outside this workspace"
            fi
        fi
    fi
fi

# ── 3. unclaim: classification, then the real thing ──────────────────────────────────────────
section "3. ai-tools --project-unclaim"
INSIDE_OUT="$("${CLI}" --project-unclaim "${PROJ}/src" 2>&1)"; INSIDE_RC=$?
if [[ "${INSIDE_RC}" -ne 0 ]] && grep -q 'inside a claimed project' <<<"${INSIDE_OUT}"; then
    pass "a path inside the project is refused, naming the claimed parent"
else
    fail "the descendant case was not refused as expected: ${INSIDE_OUT}"
fi

# A stray copy of a claimed tree, at a path no allowlist names: the case --force exists for. It is
# built INSIDE the claimed project and then moved out, because an unprivileged `cp -a` cannot
# reproduce it -- the operator is deliberately not a member of the sandbox group, so it may not
# chgrp to it, and POSIX lets cp -p drop uid/gid silently when it may not set them. Staged inside,
# the copy inherits group and default ACL from the setgid parent; `mv` is a rename, so it carries
# both out intact. That is also how the real case arises: the tree is moved, not re-created.
STAGE="${PROJ}/copy-staging"
mkdir "${STAGE}" && cp -a "${PROJ}/src" "${STAGE}/src" 2>/dev/null
if [[ "$(group_of "${STAGE}/src")" == "${SANDBOX_GROUP}" ]] && mv "${STAGE}" "${COPY}" 2>/dev/null; then
    note "staged a copy inside the claimed tree and moved it to ${COPY} (group $(group_of "${COPY}/src"))"
else
    note "could not stage a fingerprinted copy -- the --force section will say so and skip"
    rm -rf -- "${STAGE}" 2>/dev/null
fi

sudo_why "the unclaim's root steps: revert the SELinux label, then the filesystem hand-back"
UNCLAIM_OUT="$("${CLI}" --project-unclaim -y --group "${MY_GROUP}" "${PROJ}" 2>&1)"; UNCLAIM_RC=$?
printf '%s\n' "${UNCLAIM_OUT}" | sed 's/^/        /'
check "the unclaim completes (rc=${UNCLAIM_RC})" test "${UNCLAIM_RC}" -eq 0
if grep -qi 'unbound variable' <<<"${UNCLAIM_OUT}"; then
    fail "the unclaim aborted on an unbound variable (the hand-back hint regression)"
else
    pass "the unclaim ran through its hand-back without an unbound-variable abort"
fi
if grep -q "^${PROJ}\$" "${HOME}/.config/ai-tools/allowed-projects" 2>/dev/null; then
    fail "the allowlist entry survived the unclaim"
else
    pass "the allowlist entry is gone"
fi
# The hand-back itself, and the hardlink refusal that qualifies it. Both describe what an unclaim
# does to a GRANTED tree, so both are skipped rather than asserted against one that never was.
if ! ${TREE_CLAIMED}; then
    skip "the hand-back assertions (nothing was granted to hand back)"
elif [[ -e "${PROJ}/src/hardlinked" ]] && [[ "$(stat -c '%h' "${PROJ}/src/hardlinked")" -gt 1 ]]; then
    check "the work tree is handed back to ${MY_GROUP}" test "$(group_of "${PROJ}/src")" = "${MY_GROUP}"
    check "group write is removed"                      test "$(mode_of "${PROJ}/src/main.c")" = 640
    if grep -q 'hardlinked file' <<<"${UNCLAIM_OUT}" && grep -q 'links +1' <<<"${UNCLAIM_OUT}"; then
        pass "the hardlink refusal is reported with the find that lists the files"
    else
        fail "hardlinked files were left without the disclosure naming them"
    fi
    # The disclosed consequence: refusing leaves the inode in the agent's group, which is exactly
    # why the message has to say so. Assert the file the walk refused, not one it handed back.
    check "the hardlinked file keeps its group (the disclosed consequence)" \
          test "$(group_of "${PROJ}/src/hardlinked")" = "${SANDBOX_GROUP}"
else
    check "the work tree is handed back to ${MY_GROUP}" test "$(group_of "${PROJ}/src")" = "${MY_GROUP}"
    check "group write is removed"                      test "$(mode_of "${PROJ}/src/main.c")" = 640
    skip "hardlink disclosure (no hardlink in the fixture)"
fi

# ── 4. unclaim --force on the unregistered copy ──────────────────────────────────────────────
section "4. ai-tools --project-unclaim --force (unregistered copy)"
# --force acts on the ai-tools fingerprint, so the copy must carry one. Establish that FIRST:
# without it the command correctly refuses ("nothing to unclaim here"), and asserting anything
# past that point measures the fixture, not the flag. The two checks after the apply would even
# PASS on such a copy -- no abort, group already the operator's -- which is the worst outcome a
# check can have.
if [[ ! -d "${COPY}" ]]; then
    skip "--force checks (the copy could not be made)"
elif [[ "$(group_of "${COPY}/src")" != "${SANDBOX_GROUP}" ]]; then
    skip "--force checks (the copy carries no ai-tools fingerprint -- was the original granted?)"
else
    pass "the copy carries the agent group, so --force has something to act on"
    FORCE_DRY="$("${CLI}" --project-unclaim --force -n "${COPY}" 2>&1)"; FORCE_DRY_RC=$?
    printf '%s\n' "${FORCE_DRY}" | head -20 | sed 's/^/        /'
    check "the --force dry run completes (rc=${FORCE_DRY_RC})" test "${FORCE_DRY_RC}" -eq 0
    check "the dry run changed nothing" test "$(group_of "${COPY}/src")" = "${SANDBOX_GROUP}"
    sudo_why "the --force hand-back on the unregistered copy (the dry run above needed none)"
    FORCE_OUT="$("${CLI}" --project-unclaim --force -y --group "${MY_GROUP}" "${COPY}" 2>&1)"; FORCE_RC=$?
    printf '%s\n' "${FORCE_OUT}" | sed 's/^/        /'
    check "the --force unclaim completes (rc=${FORCE_RC})" test "${FORCE_RC}" -eq 0
    if grep -qi 'unbound variable' <<<"${FORCE_OUT}"; then
        fail "the --force unclaim aborted on an unbound variable"
    else
        pass "the --force unclaim ran through its hand-back cleanly"
    fi
    check "the copy is normalized to ${MY_GROUP}" test "$(group_of "${COPY}/src")" = "${MY_GROUP}"
fi

# ── 5. --sandbox-create flag validation (parses only; nothing is created) ────────────────────
section "5. ai-tools --sandbox-create flag validation"
for flag in --from --branch --dir; do
    OUT="$("${CLI}" --sandbox-create "${flag}" -oops 2>&1)"; RC=$?
    if [[ "${RC}" -ne 0 ]] && grep -q 'not another option' <<<"${OUT}"; then
        pass "${flag} refuses an option-shaped value"
    else
        fail "${flag} accepted '-oops' (rc=${RC}): ${OUT}"
    fi
done

# ── 6. --status ──────────────────────────────────────────────────────────────────────────────
section "6. ai-tools --status"
STATUS_OUT="$("${CLI}" --status 2>&1)"; STATUS_RC=$?
printf '%s\n' "${STATUS_OUT}" | sed 's/^/        /'
note "exit status ${STATUS_RC} (0 = nothing broken; 1 = something is, which may be true of this host)"
check "the report names the handback socket" grep -q 'ai-tools-handback.socket' <<<"${STATUS_OUT}"
check "the report names the update service"  grep -q 'nvm-update.service'       <<<"${STATUS_OUT}"

# A unit whose file is not installed reads as not-installed, not as unqueryable. Driven by
# pointing the presence lookup at an empty directory rather than by uninstalling anything.
NOUNIT_OUT="$(AI_TOOLS_USER_UNIT_DIRS=/nonexistent-user-units "${CLI}" --status 2>&1)"
if grep -E 'nvm-update\.(timer|service).*not installed' <<<"${NOUNIT_OUT}" >/dev/null; then
    pass "an uninstalled sandbox-user unit reads as 'n/a (not installed)', not '?'"
else
    fail "an uninstalled sandbox-user unit did not read as not-installed: $(grep nvm-update <<<"${NOUNIT_OUT}" | tr '\n' ' ')"
fi

# The timer's verdict must rest on a run SYSTEMD started, which the stamp's TRIGGER records.
# Driving both sides of that would mean rewriting the stamp -- shared runtime state a real update
# run owns -- so this reads the stamp the host already has and asserts the report AGREES with it.
# Whichever value is there, one direction of the rule gets exercised; the other is stated, and
# unit/services.sh drives both against its own fixture.
TIMER_LINE="$(grep 'nvm-update.timer' <<<"${STATUS_OUT}" || true)"
if [[ ! -r "${STAMP}" ]]; then
    skip "TRIGGER agreement (no readable stamp at ${STAMP} -- nodejs integration absent, or no run yet)"
else
    TRIGGER="$(grep -m1 -E '^TRIGGER=' "${STAMP}" 2>/dev/null | cut -d= -f2 || true)"
    FINISHED="$(grep -m1 -E '^FINISHED=' "${STAMP}" 2>/dev/null | cut -d= -f2 || true)"
    note "stamp says TRIGGER=${TRIGGER:-<absent>} FINISHED=${FINISHED:-<absent>}"
    note "timer line: ${TIMER_LINE:-<none>}"
    case "${TRIGGER:-}" in
        unit)
            # A systemd-started run is evidence about the schedule; fresh it reads OK, past the
            # 48h grace STALE. Both are verdicts rather than '?', which is the property here.
            if grep -qE 'OK|STALE' <<<"${TIMER_LINE}"; then
                pass "a systemd-started run gives the timer a verdict of its own (not '?')"
            else
                fail "TRIGGER=unit but the timer reports no verdict: ${TIMER_LINE}"
            fi ;;
        ""|manual)
            # A hand run, or a stamp predating the field, is no evidence about a schedule: the
            # timer must decline rather than read OK off someone else's run.
            if grep -q '?' <<<"${TIMER_LINE}"; then
                pass "a non-systemd run leaves the timer unknown, not falsely OK"
            else
                fail "TRIGGER=${TRIGGER:-<absent>} was counted as evidence the timer fired: ${TIMER_LINE}"
            fi ;;
        *)  skip "TRIGGER agreement (unrecognised value '${TRIGGER}')" ;;
    esac
    note "the service's own line reports that run either way -- declining the timer loses nothing"
fi

# ── 7. the pure unit suites, unprivileged ────────────────────────────────────────────────────
# The harness now takes the invoker as the project user, so these run without sudo. Only from a
# checkout; an installed-only host skips them.
section "7. pure unit suites without sudo"
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../unit" 2>/dev/null && pwd)" || SUITE_DIR=""
if [[ -n "${SUITE_DIR}" && -d "${SUITE_DIR}" ]]; then
    for s in services msg safe-paths skip-dirs confinement; do
        [[ -f "${SUITE_DIR}/${s}.sh" ]] || continue
        if RESULT="$(bash "${SUITE_DIR}/${s}.sh" 2>&1 | tail -1)"; then
            case "${RESULT}" in
                *" 0 failed"*) pass "unit/${s}.sh runs unprivileged (${RESULT# })" ;;
                *)             fail "unit/${s}.sh: ${RESULT# }" ;;
            esac
        else
            fail "unit/${s}.sh did not complete"
        fi
    done
else
    skip "unit suites (not run from a checkout)"
fi

# ── 8. the stop rung: ai-tools --stop ────────────────────────────────────────────────────────
# The incident ladder's stop rung, and the one control here that acts on a session ALREADY
# RUNNING. Everything reversible runs unconditionally; the undeclinable form (`--all`) runs only
# with --stop-all-drill, because proving it means ending every session on the host.
#
# This is also the DRILL: an escalation ladder nobody has ever climbed is a document, not a
# control, so the destructive half is meant to be run deliberately, periodically, with the trail
# read afterwards -- not merely to be tested once.
section "8. ai-tools --stop"

SANDBOX_UID_N="$(id -u "${SANDBOX_GROUP}" 2>/dev/null || true)"
CG2_MOUNT="$(awk '$3 == "cgroup2" { print $2; exit }' /proc/mounts)"
SANDBOX_SLICE_DIR="${CG2_MOUNT:-/sys/fs/cgroup}/user.slice/user-${SANDBOX_UID_N}.slice"
SANDBOX_INIT_SCOPE="${SANDBOX_SLICE_DIR}/user@${SANDBOX_UID_N}.service/init.scope"

# session_task_count: how many tasks the sandbox account's slice holds OUTSIDE the user manager's
# own init.scope -- i.e. how much agent work is running. Read from cgroupfs directly, which is
# world-readable, so this observes the same fact the helper acts on without going through it.
session_task_count() {
    local procs_file cgroup_dir line count=0
    while IFS= read -r procs_file; do
        cgroup_dir="${procs_file%/cgroup.procs}"
        [[ "${cgroup_dir}" == "${SANDBOX_INIT_SCOPE}" ]] && continue
        while read -r line; do [[ -n "${line}" ]] && count=$(( count + 1 )); done \
            < "${procs_file}" 2>/dev/null
    done < <(find "${SANDBOX_SLICE_DIR}" -name cgroup.procs 2>/dev/null)
    printf '%s' "${count}"
}

# manager_is_up: does the sandbox account's user manager hold any task? Read as CONTENT, and
# NEVER with `-s`: every cgroupfs file stats as zero bytes however many tasks it holds, so
# `[[ -s cgroup.procs ]]` is false even for a slice holding hundreds -- an assertion that cannot
# pass, and that reports a healthy restore as a failure. (Verified: the root cgroup.procs stats 0
# with 379 pids in it.) session_task_count above already reads content, for the same reason.
#
# `2>/dev/null` PRECEDES the input redirect, per the rule ai-tools-stop.sh's cgroup_pids states:
# redirections apply left to right, so the other order lets a missing init.scope -- exactly the
# case this asserts against -- write its open failure to the real stderr, mid-report.
manager_is_up() {
    local line
    read -r line 2>/dev/null < "${SANDBOX_INIT_SCOPE}/cgroup.procs" || return 1
    [[ -n "${line}" ]]
}

if [[ -z "${SANDBOX_UID_N}" || ! -d "${SANDBOX_SLICE_DIR}" ]]; then
    skip "--stop (the sandbox account has no per-user slice on this host -- nothing has run yet)"
else
    # A PATH IS REFUSED, and the refusal has to name what to do instead. This is the whole of the
    # argument contract: there is no per-project form, and accepting a path would invert what the
    # operator asked for -- they typed a path to NARROW the command, and it terminates everything.
    OUT="$("${CLI}" --stop /some/project 2>&1)"; RC=$?
    if [[ "${RC}" -eq 2 ]] && grep -q 'takes no path' <<<"${OUT}" && grep -q '/exit' <<<"${OUT}"; then
        pass "--stop refuses a path (rc=2) and names /exit as the way to end one session"
    else
        fail "--stop did not refuse a path properly (rc=${RC}): ${OUT}"
    fi

    # The refusal happens BEFORE sudo: a command that is going to be refused must not first prompt
    # for a password. Asserted by the absence of a prompt, which is why no sudo_why precedes it.
    if ! grep -qi 'password' <<<"${OUT}"; then
        pass "the path refusal lands before any sudo prompt"
    else
        fail "--stop prompted for a password before refusing a path: ${OUT}"
    fi

    TASKS_BEFORE="$(session_task_count)"
    note "sandbox slice holds ${TASKS_BEFORE} task(s) outside the user manager's init.scope"

    # The dry run changes nothing, and says so. Safe whether or not a session is running.
    sudo_why "--stop --dry-run enumerates the sandbox account's cgroups"
    OUT="$("${CLI}" --stop --dry-run 2>&1)"; RC=$?
    printf '%s\n' "${OUT}" | sed 's/^/        /'
    if [[ "${RC}" -eq 0 ]]; then
        pass "--stop --dry-run exits 0"
    else
        fail "--stop --dry-run exited ${RC}"
    fi
    if [[ "$(session_task_count)" == "${TASKS_BEFORE}" ]]; then
        pass "the dry run stopped nothing (task count unchanged)"
    else
        fail "the dry run changed the running task count"
    fi

    if ! ${STOP_ALL_DRILL}; then
        skip "--stop (destructive; re-run with --stop-all-drill to prove the stop rung)"
        note "it ends EVERY agent session on this host, including any in another terminal"
    elif [[ "${TASKS_BEFORE}" -eq 0 ]]; then
        skip "--stop (nothing is running, so a successful stop would prove nothing)"
        note "start a session first: ai-tools claude, in a claimed project, from another terminal"
    else
        printf '  %sDRILL%s  ending every agent session on this host in 5s -- Ctrl-C to abort\n' \
            "${C_R}" "${C_0}"
        sleep 5
        sudo_why "--stop signals the sandbox account's cgroups as root"
        OUT="$("${CLI}" --stop --yes 2>&1)"; RC=$?
        printf '%s\n' "${OUT}" | sed 's/^/        /'
        if [[ "${RC}" -eq 0 ]]; then
            pass "--stop completed and reported success (exit 0)"
        else
            fail "--stop exited ${RC} -- 1 means something survived SIGKILL, 5 that the helper could not run"
        fi
        TASKS_AFTER="$(session_task_count)"
        if [[ "${TASKS_AFTER}" -eq 0 ]]; then
            pass "the reported success is true: the sandbox slice holds no task outside init.scope"
        else
            fail "${TASKS_AFTER} task(s) still in the sandbox slice after a reported success"
        fi
        # THE USER MANAGER IS TERMINATED TOO, AND PUT BACK. It is not spared: an exemption is a
        # cgroup a session can move into on a DAC-only host, so the sweep covers init.scope like
        # everything else and the manager is restarted afterwards. What matters to the next launch
        # is only that it is back -- give it a moment, since the restart is asynchronous.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            manager_is_up && break
            sleep 0.5
        done
        if manager_is_up; then
            pass "the user manager was restored after the stop, so the next launch still works"
        else
            fail "the user manager did not come back; the next launch will have no --user instance -- restore it: sudo systemctl start user@$(id -u "${SANDBOX_GROUP}").service"
        fi
        # IDEMPOTENT IN END STATE, WHICH IS NOT THE SAME AS SILENT -- and the difference follows
        # from the rebuild rather than being a defect in it. The manager the run above restored is
        # itself inside the swept slice, so a second run finds it, stops it, and restarts it again.
        # What must hold is that no AGENT session is found (the first stop took) and the run still
        # exits 0. A second run reporting agent sessions would mean the first one did not.
        OUT="$("${CLI}" --stop --yes 2>&1)"; RC=$?
        if [[ "${RC}" -eq 0 ]] && grep -qi 'no agent session' <<<"${OUT}"; then
            pass "a second --stop finds no agent session and exits 0 (only the restored manager goes)"
        else
            fail "the second --stop still reported agent sessions, or failed (rc=${RC}): ${OUT}"
        fi
        note "the stop cannot run the agent's session-end handback: reclaim each project it named"
    fi

    # The trail is the point of the rung as much as the kill is: who asked, what for, what ended.
    sudo_why "reading the root-only stop trail"
    TRAIL="$(sudo -n cat /var/log/ai-tools/stop.log 2>/dev/null | tail -20 \
             || sudo cat /var/log/ai-tools/stop.log 2>/dev/null | tail -20)"
    if grep -q "${ME}" <<<"${TRAIL}"; then
        pass "the trail names the operator who asked for the stop"
        printf '%s\n' "${TRAIL}" | tail -6 | sed 's/^/        /'
    else
        fail "the stop trail does not name ${ME} (or is unreadable)"
    fi
fi

# ── summary ──────────────────────────────────────────────────────────────────────────────────
printf '\n%s──────────────────────────────────────────%s\n' "${C_B}" "${C_0}"
printf '  %d passed, %d failed, %d skipped\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
if (( FAILED )); then
    printf '\n%sfailures:%s\n' "${C_R}" "${C_0}"
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "${f}"; done
fi
(( FAILED == 0 ))
