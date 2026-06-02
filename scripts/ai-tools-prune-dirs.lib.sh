#!/usr/bin/env bash
# /usr/local/lib/ai-tools/prune-dirs.lib.sh
# Single source of truth for the directory NAMES pruned from the recursive walks
# in the ai-tools sandbox helpers:
#   - sandbox-sweep.sh    (ownership handback, Stop + SessionStart)
#   - ai-tools-setgid      (setgid normalization, SessionStart)
#   - ai-tools-lockdown    (pre-flight secret lockdown, user-run)
# Centralised so the three agree and a new build/dependency tree is added in ONE
# place instead of drifting across scripts.
#
# These are heavy/transient VCS, build, and dependency trees -- not where shared
# hand-authored files live -- so walking them every pass is wasteful and pruning
# them is safe. NOTE: 'bin'/'obj'/'packages' are pruned by .NET build convention;
# a project that hand-authors shared files under such a name will not be
# swept/setgid there (an acceptable tradeoff for the common case).
#
# Sourced (not executed) so every consumer gets the array by the SAME definition.
# Root-owned 644 in a non-ai-tools-writable dir; readable from ai_tools_t (the
# agent-context sweep sources it too). Consumers fall back to an empty list when it
# is unreadable -- the walk is then slower but still correct.
#
# Deploy: installed to /usr/local/lib/ai-tools/prune-dirs.lib.sh (644 root root).

# shellcheck disable=SC2034  # consumed by the sourcing scripts
AI_TOOLS_PRUNE_NAMES=(.git node_modules .venv __pycache__ bin obj packages)
