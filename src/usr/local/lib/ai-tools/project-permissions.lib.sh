#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/project-permissions.lib.sh
# The POSIX ACL a claim grants on a project tree, and the per-path checks that read whether a path carries
# what the claim gives it. ai-tools-setfacl applies the specification; the claim (ai-tools) collects its drift
# and verifies its repairs with the checks, so the verifier tests the entries the helper writes rather than a copy
# of them.
#
# Sourcing the library defines functions and does not touch the filesystem or resolve a name. The specification is
# a pure function over the identities its caller passes: the helper passes names, the checks pass numeric ids, which is
# the form `getfacl --numeric` prints them in. The checks read -- `restorecon -n`, `getfacl`, `stat`, `lstat` -- and do
# not write anything but the caller's own work directory. Each resolves an output it cannot read to `unknown`, never
# to `match`, and runs its tools under LC_ALL=C, since a translated message or file type would not parse. Its domain
# rule is cli.rule.md.

if [[ -n "${_AI_TOOLS_PROJECT_PERMISSIONS_LIB:-}" ]]; then
    return 0
fi
readonly _AI_TOOLS_PROJECT_PERMISSIONS_LIB=1

# ai_tools_project_permissions_build_acl_specification <output-variable> <operator> <sandbox-group>  -- set
# <output-variable> to the `setfacl -m` specification a claim applies: the operator's named grant, the sandbox group's,
# and `other::---`. `rwX` grants execute only on a directory or a file that already has an execute bit. Returns 1
# with the variable empty when an identity is empty or holds a character outside `[A-Za-z0-9._-]`, since a `,` or `:`
# in one would add an entry of its own to the specification; returns 2 on an invalid variable name.
ai_tools_project_permissions_build_acl_specification() {
    local _output="$1" _operator="$2" _group="$3"
    [[ "${_output}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    printf -v "${_output}" '%s' ''
    local LC_ALL=C
    [[ "${_operator}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    [[ "${_group}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 1
    printf -v "${_output}" 'user:%s:rwX,group:%s:rwX,other::---' "${_operator}" "${_group}"
}

# _ai_tools_project_permissions_read_capture <file> <output-variable>  -- set <output-variable> to the whole content
# of a stream a check captured, and return 0. Returns 1 with the variable empty when the file is missing, is anything
# but a regular file, fails to read, or holds a NUL: a shell string cannot carry one, and a read that stopped at it
# would hide every byte after it. The length read is compared with the file's size, so a short read is refused as well.
_ai_tools_project_permissions_read_capture() {
    local _file="$1" _size
    local -n _capture_out="$2"
    local LC_ALL=C
    _capture_out=""
    [[ -f "${_file}" && ! -L "${_file}" && -r "${_file}" ]] || return 1
    _size="$(stat -c '%s' -- "${_file}" 2>/dev/null)" || return 1
    if IFS= read -r -d '' _capture_out 2>/dev/null < "${_file}"; then
        _capture_out=""
        return 1
    fi
    if (( ${#_capture_out} != _size )); then
        _capture_out=""
        return 1
    fi
}

# ── SELinux label ────────────────────────────────────────────────────────────────────────────────────────────────────

# ai_tools_project_permissions_context_type <output-variable> <context>  -- set <output-variable> to the type
# of a SELinux context shaped user:role:type:level, where the level may carry `:`-joined categories, and return 0. Each
# field is held to the characters a policy identifier and an MLS level are written with, so a context of any other shape
# -- a space in it, an empty field -- returns 1 with the variable empty, and two malformed contexts cannot yield empty
# types that compare equal.
ai_tools_project_permissions_context_type() {
    local -n _context_type_out="$1"
    local LC_ALL=C
    local pattern='^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:([A-Za-z0-9_.-]+):[A-Za-z0-9_.,:-]+$'
    _context_type_out=""
    [[ "$2" =~ ${pattern} ]] || return 1
    _context_type_out="${BASH_REMATCH[1]}"
}

# ai_tools_project_permissions_parse_restorecon_record <record> <path-var> <from-type-var> <to-type-var>  -- split one
# `restorecon -v` record, `Would relabel <path> from <context> to <context>` without its LF, into the path and the two
# types. Both contexts are cut from the right: a context does not hold a space, while a path may hold ` from `
# or ` to `. Returns 1 with every variable empty when the record has another shape or either context does not validate.
ai_tools_project_permissions_parse_restorecon_record() {
    local _record="$1"
    local -n _split_path="$2" _split_from="$3" _split_to="$4"
    local LC_ALL=C _rest _from_context _to_context
    _split_path="" _split_from="" _split_to=""
    [[ "${_record}" == "Would relabel "* ]] || return 1
    _rest="${_record#Would relabel }"
    [[ "${_rest}" == *" to "* ]] || return 1
    _to_context="${_rest##* to }"
    _rest="${_rest% to *}"
    [[ "${_rest}" == *" from "* ]] || return 1
    _from_context="${_rest##* from }"
    _rest="${_rest% from *}"
    if [[ -z "${_rest}" ]] \
            || ! ai_tools_project_permissions_context_type _split_from "${_from_context}" \
            || ! ai_tools_project_permissions_context_type _split_to "${_to_context}"; then
        _split_from="" _split_to=""
        return 1
    fi
    _split_path="${_rest}"
}

# ai_tools_project_permissions_label_check <path> <work-dir> <outcome-var> <from-type-var> <to-type-var>  --
# the single-path form of the batch's label test: `restorecon -n -v -F -- <path>`, not recursive. <outcome-var> gets
# `match` on complete output (exit 0, empty stderr, a capture read whole) that has no record, or one record for these
# exact bytes whose two types agree (the user, role or range alone differ, which a claim does not count); `drift`
# for that record with the types differing, both type variables set; `unknown` for anything else. The record is matched
# by its known prefix, so a path holding LF, whose record spans two lines, is read like any other. The captured streams
# are written into <work-dir>.
ai_tools_project_permissions_label_check() {
    local _path="$1" _work="$2"
    local -n _label_outcome="$3" _label_from="$4" _label_to="$5"
    local LC_ALL=C _status=0 _stdout="" _prefix _rest
    _label_outcome=unknown _label_from="" _label_to=""
    { LC_ALL=C restorecon -n -v -F -- "${_path}" \
        > "${_work}/label-check.out" 2> "${_work}/label-check.err"; } 2>/dev/null || _status=$?
    (( _status == 0 )) || return 0
    [[ -f "${_work}/label-check.err" && ! -s "${_work}/label-check.err" ]] || return 0
    _ai_tools_project_permissions_read_capture "${_work}/label-check.out" _stdout || return 0
    if [[ -z "${_stdout}" ]]; then
        _label_outcome=match
        return 0
    fi
    _prefix="Would relabel ${_path} from "
    [[ "${_stdout}" == "${_prefix}"* && "${_stdout}" == *$'\n' ]] || return 0
    _rest="${_stdout#"${_prefix}"}"
    _rest="${_rest%$'\n'}"
    [[ "${_rest}" != *$'\n'* && "${_rest}" == *" to "* ]] || return 0
    if ! ai_tools_project_permissions_context_type _label_from "${_rest% to *}" \
            || ! ai_tools_project_permissions_context_type _label_to "${_rest##* to }"; then
        _label_from="" _label_to=""
        return 0
    fi
    if [[ "${_label_from}" == "${_label_to}" ]]; then
        _label_outcome=match
    else
        _label_outcome=drift
    fi
}

# ai_tools_project_permissions_label_batch <list-file> <work-dir> <listed-set> <drift-map> [-i]  -- one non-recursive
# dry run over the NUL-separated paths in <list-file>, `restorecon -n -v -F -0 [-i] -f -`, its stdout and stderr
# captured apart into <work-dir>. <listed-set> is the caller's associative array keyed by each listed path's exact
# bytes, none holding LF; <drift-map> receives `<from-type> TAB <to-type>` under each path whose valid record shows
# the two types differing.
#
# Returns 0 on complete output: exit 0, empty stderr, a capture read whole, and every line an LF-terminated valid record
# naming a listed path once. Only then does a listed path absent from <drift-map> match. Returns 1 otherwise,
# and <drift-map> holds only the drift records the output carried whole: every other listed path is unknown, a final
# line without its LF is not read, and a record naming a path outside the set is not evidence about any path. `-i` skips
# a listed path that does not exist, which the collection passes and the verification does not (cli.rule.md).
ai_tools_project_permissions_label_batch() {
    local _list="$1" _work="$2" _ignore_missing="${5:-}"
    local -n _batch_listed="$3" _batch_drift="$4"
    local LC_ALL=C _status=0 _incomplete=0 _output="" _line _path _from _to
    local -a _arguments=(-n -v -F -0) _lines=()
    local -A _seen=()
    [[ "${_ignore_missing}" == -i ]] && _arguments+=(-i)
    { LC_ALL=C restorecon "${_arguments[@]}" -f - < "${_list}" \
        > "${_work}/label-batch.out" 2> "${_work}/label-batch.err"; } 2>/dev/null || _status=$?
    (( _status == 0 )) || _incomplete=1
    [[ -f "${_work}/label-batch.err" && ! -s "${_work}/label-batch.err" ]] || _incomplete=1
    if ! _ai_tools_project_permissions_read_capture "${_work}/label-batch.out" _output; then
        _incomplete=1
        _output=""
    fi
    if [[ -n "${_output}" && "${_output}" != *$'\n' ]]; then
        _incomplete=1
        if [[ "${_output}" == *$'\n'* ]]; then _output="${_output%$'\n'*}"$'\n'; else _output=""; fi
    fi
    [[ -n "${_output}" ]] && mapfile -t _lines <<< "${_output%$'\n'}"
    for _line in "${_lines[@]}"; do
        if ! ai_tools_project_permissions_parse_restorecon_record "${_line}" _path _from _to \
                || [[ -z "${_batch_listed[${_path}]+set}" || -n "${_seen[${_path}]+set}" ]]; then
            _incomplete=1
            continue
        fi
        _seen["${_path}"]=1
        [[ "${_from}" != "${_to}" ]] && _batch_drift["${_path}"]="${_from}"$'\t'"${_to}"
    done
    return "${_incomplete}"
}

# ── Absence ──────────────────────────────────────────────────────────────────────────────────────────────────────────

# ai_tools_project_permissions_lstat_outcomes <list-file> <work-dir> <outcome-array>  -- look up each NUL-separated path
# in <list-file> with an errno-preserving lstat and fill the caller's indexed <outcome-array>, in list order,
# with `exists`, `gone` (ENOENT or ENOTDIR: no entry at that path), or `unknown` (any other error: EACCES
# from an ancestor without search permission for the caller, ELOOP, EIO). A dangling symlink exists. The paths stay
# bytes from the file to os.lstat, so a name that is not UTF-8 is looked up as it is. python3 failing, a token outside
# those three, or a count differing from the list's makes every entry `unknown`; a list the redirect fails to open
# returns 1 with the array empty. `-I` keeps the interpreter from importing a module out of the caller's working
# directory.
ai_tools_project_permissions_lstat_outcomes() {
    local _list="$1" _work="$2"
    local -n _lstat_out="$3"
    local -a _paths=() _tokens=()
    local _status=0 _token _index
    _lstat_out=()
    mapfile -d '' -t _paths 2>/dev/null < "${_list}" || return 1
    { /usr/bin/python3 -I -c '
import errno, os, sys
paths = sys.stdin.buffer.read().split(b"\0")
if paths and paths[-1] == b"":
    paths.pop()
for path in paths:
    try:
        os.lstat(path)
        token = "exists"
    except OSError as error:
        token = "gone" if error.errno in (errno.ENOENT, errno.ENOTDIR) else "unknown"
    sys.stdout.write(token + "\n")
' < "${_list}" > "${_work}/lstat.out" 2> "${_work}/lstat.err"; } 2>/dev/null || _status=$?
    mapfile -t _tokens 2>/dev/null < "${_work}/lstat.out" || _tokens=()
    if (( _status != 0 )) || [[ -s "${_work}/lstat.err" ]] || (( ${#_tokens[@]} != ${#_paths[@]} )); then
        _tokens=()
    fi
    for _token in "${_tokens[@]}"; do
        case "${_token}" in
            exists|gone|unknown) ;;
            *) _tokens=(); break ;;
        esac
    done
    for _index in "${!_paths[@]}"; do
        _lstat_out[_index]="${_tokens[_index]:-unknown}"
    done
}

# ── Group and ACL ────────────────────────────────────────────────────────────────────────────────────────────────────

# ai_tools_project_permissions_parse_acl <capture-file> <access-map> <default-map>  -- parse a captured
# `getfacl --absolute-names --omit-header --numeric --no-effective` output into two associative arrays keyed
# `<tag>:<qualifier>` (`user:`, `user:1000`, `group:`, `mask:`, `other:`), each value an `rwx` triple; the `default:`
# entries go into <default-map>, which stays empty when the path has none. Returns 0 when every set present is
# structurally complete: exactly one `user::`, `group::` and `other::` entry, no tag and qualifier twice, and a `mask::`
# wherever a named entry is present (acl(5)). Returns 1 -- the ACL is unknown -- on a capture that is not read whole
# (_ai_tools_project_permissions_read_capture), a line that does not parse (a blank separator line is accepted),
# or a set that is incomplete.
ai_tools_project_permissions_parse_acl() {
    local _capture="$1"
    local -n _acl_access="$2" _acl_default="$3"
    local LC_ALL=C _text="" _line _set _key
    local pattern='^(default:)?(user|group|mask|other):([0-9]*):([r-][w-][x-])$'
    local -a _lines=()
    _acl_access=() _acl_default=()
    _ai_tools_project_permissions_read_capture "${_capture}" _text || return 1
    [[ -n "${_text}" ]] && mapfile -t _lines <<< "${_text%$'\n'}"
    for _line in "${_lines[@]}"; do
        [[ -z "${_line}" ]] && continue
        [[ "${_line}" =~ ${pattern} ]] || return 1
        _key="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
        case "${BASH_REMATCH[2]}" in
            mask|other) [[ -z "${BASH_REMATCH[3]}" ]] || return 1 ;;
        esac
        if [[ -n "${BASH_REMATCH[1]}" ]]; then
            [[ -z "${_acl_default[${_key}]+set}" ]] || return 1
            _acl_default["${_key}"]="${BASH_REMATCH[4]}"
        else
            [[ -z "${_acl_access[${_key}]+set}" ]] || return 1
            _acl_access["${_key}"]="${BASH_REMATCH[4]}"
        fi
    done
    for _set in _acl_access _acl_default; do
        local -n _acl_set="${_set}"
        if [[ "${_set}" == _acl_default && "${#_acl_set[@]}" -eq 0 ]]; then
            unset -n _acl_set
            continue
        fi
        [[ -n "${_acl_set[user:]+set}" && -n "${_acl_set[group:]+set}" && -n "${_acl_set[other:]+set}" ]] || return 1
        for _key in "${!_acl_set[@]}"; do
            if [[ "${_key}" =~ ^(user|group):[0-9]+$ && -z "${_acl_set[mask:]+set}" ]]; then
                return 1
            fi
        done
        unset -n _acl_set
    done
    return 0
}

# ai_tools_project_permissions_read_acl <path> <work-dir> <access-map> <default-map>  -- read <path>'s ACL by name
# with getfacl, capturing both streams into <work-dir>, and parse it (ai_tools_project_permissions_parse_acl). Returns 1
# on a getfacl failure, any stderr, or a parse failure. group_check reads through a pinned descriptor instead.
ai_tools_project_permissions_read_acl() {
    local _path="$1" _work="$2" _status=0
    { LC_ALL=C getfacl --absolute-names --omit-header --numeric --no-effective -- "${_path}" \
        > "${_work}/acl.out" 2> "${_work}/acl.err"; } 2>/dev/null || _status=$?
    (( _status == 0 )) || return 1
    [[ -f "${_work}/acl.err" && ! -s "${_work}/acl.err" ]] || return 1
    ai_tools_project_permissions_parse_acl "${_work}/acl.out" "$3" "$4"
}

# ai_tools_project_permissions_acl_effective_permissions <output-variable> <acl-map> <key>  -- set <output-variable>
# to the permissions entry <key> of a parsed set grants in effect, or to the empty string when the set does not carry
# the entry. The mask limits named-user entries, `group::` and named-group entries alone; `user::` and `other::` are
# read as they are (acl(5)).
ai_tools_project_permissions_acl_effective_permissions() {
    local -n _effective_out="$1" _effective_set="$2"
    local _key="$3" _entry _mask _index _result=""
    _effective_out=""
    [[ -n "${_effective_set[${_key}]+set}" ]] || return 0
    _entry="${_effective_set[${_key}]}"
    case "${_key}" in
        user:|other:) _effective_out="${_entry}"; return 0 ;;
    esac
    _mask="${_effective_set[mask:]:-rwx}"
    for _index in 0 1 2; do
        if [[ "${_entry:_index:1}" != - && "${_mask:_index:1}" != - ]]; then
            _result+="${_entry:_index:1}"
        else
            _result+=-
        fi
    done
    _effective_out="${_result}"
}

# _ai_tools_project_permissions_pinned_read <path> <work-dir> <output-variable>  -- read one filesystem object's owner,
# group, mode, type and ACL, all from the same object. The path's own identity and type are read without following it;
# a child opens the path, reads the identity, owner, group, mode and type through that descriptor
# into <work-dir>/pinned.stat, and runs getfacl on the descriptor into <work-dir>/acl.out and acl.err; the path's
# identity is read again afterwards. <output-variable> gets `<uid> <gid> <mode> <type>`. Returns 0 when the descriptor's
# object is the path's before and after; 2 with the variable holding the type when the path is neither a regular file
# nor a directory (not opened, so a FIFO does not block the open); 1 otherwise. The child is bounded by `timeout`, since
# a path replaced by a FIFO between the first read and the open blocks it. What it returns is an observation
# of that object, not a guarantee against a later change.
_ai_tools_project_permissions_pinned_read() {
    local _path="$1" _work="$2" _before="" _after="" _pinned="" _status=0
    local -n _pinned_out="$3"
    local LC_ALL=C
    _pinned_out=""
    _before="$(LC_ALL=C stat -c '%d:%i %F' -- "${_path}" 2>/dev/null)" || return 1
    case "${_before#* }" in
        directory|"regular file"|"regular empty file") ;;
        *) _pinned_out="${_before#* }"; return 2 ;;
    esac
    # shellcheck disable=SC2016  # the $1, $2 and ${fd} are the child's
    { LC_ALL=C timeout 10 bash -c '
        exec {fd}< "$1" || exit 3
        stat -L -c "%d:%i %u %g %a %F" "/proc/self/fd/${fd}" > "$2/pinned.stat" || exit 4
        getfacl --absolute-names --omit-header --numeric --no-effective -- "/proc/self/fd/${fd}" \
            > "$2/acl.out" 2> "$2/acl.err" || exit 5
    ' _ "${_path}" "${_work}"; } 2>/dev/null || _status=$?
    (( _status == 0 )) || return 1
    [[ -f "${_work}/acl.err" && ! -s "${_work}/acl.err" ]] || return 1
    _ai_tools_project_permissions_read_capture "${_work}/pinned.stat" _pinned || return 1
    _pinned="${_pinned%$'\n'}"
    _after="$(LC_ALL=C stat -c '%d:%i %F' -- "${_path}" 2>/dev/null)" || return 1
    [[ "${_after}" == "${_before}" && "${_pinned%% *}" == "${_before%% *}" ]] || return 1
    _pinned_out="${_pinned#* }"
}

# ai_tools_project_permissions_group_check <path> <work-dir> <operator-uid> <sandbox-uid> <sandbox-gid> <outcome-var>
# <detail-var>  -- test the postconditions a claim's group and ACL repair establishes on <path>, reading the owner,
# group, mode and ACL from one pinned object (_ai_tools_project_permissions_pinned_read). <outcome-var> gets `match`
# when every one holds, `drift` with <detail-var> naming the first that does not, or `unknown` with <detail-var> naming
# what could not be read. In order:
#   * the path is a regular file or a directory (a symlink, FIFO, device or socket is `unknown`: the repair does not
#     apply to it), and the object read is the one the path names;
#   * its owner, by numeric UID, is the operator or the sandbox account (the helper's own eligibility rule, so a path
#     the helper refused cannot pass on a group and ACL that already matched);
#   * it is not owner-only (the claim honours that seal, and the path is still not shared);
#   * its group is the sandbox group, and a directory carries setgid;
#   * each named entry of the specification grants in effect `rw`, plus `x` on a directory or on a file whose mode has
#     an execute bit, and `other::` is `---`; on a directory the default set holds the same.
ai_tools_project_permissions_group_check() {
    local _path="$1" _work="$2" _operator_uid="$3" _sandbox_uid="$4" _sandbox_gid="$5"
    local -n _group_outcome="$6" _group_detail="$7"
    local LC_ALL=C _read="" _status=0 _uid _gid _mode _type _specification _entry _key _need _have _set _index
    local -A _access=() _default=()
    local -a _entries=() _sets=(_access)
    _group_outcome=unknown _group_detail=""
    _ai_tools_project_permissions_pinned_read "${_path}" "${_work}" _read || _status=$?
    case "${_status}" in
        0) ;;
        2) _group_detail="a ${_read} does not take the project ACL"; return 0 ;;
        *) _group_detail="its owner, group, mode and ACL could not be read from one object"; return 0 ;;
    esac
    IFS=' ' read -r _uid _gid _mode _type <<< "${_read}"
    [[ "${_uid}" =~ ^[0-9]+$ && "${_gid}" =~ ^[0-9]+$ && "${_mode}" =~ ^[0-7]+$ ]] || {
        _group_detail="its owner, group and mode could not be read"; return 0; }
    _group_outcome=drift
    if [[ "${_uid}" != "${_operator_uid}" && "${_uid}" != "${_sandbox_uid}" ]]; then
        _group_detail="owned by uid ${_uid}, neither the operator nor the sandbox account"
        return 0
    fi
    if (( (8#${_mode} & 8#077) == 0 )); then
        _group_detail="owner-only (mode ${_mode}): the claim leaves a sealed path as it is"
        return 0
    fi
    if [[ "${_gid}" != "${_sandbox_gid}" ]]; then
        _group_detail="group ${_gid} is not the sandbox group"
        return 0
    fi
    if [[ "${_type}" == directory ]] && (( (8#${_mode} & 8#2000) == 0 )); then
        _group_detail="the directory does not carry setgid"
        return 0
    fi
    if ! ai_tools_project_permissions_parse_acl "${_work}/acl.out" _access _default; then
        _group_outcome=unknown _group_detail="its ACL could not be read"
        return 0
    fi
    if ! ai_tools_project_permissions_build_acl_specification _specification \
            "${_operator_uid}" "${_sandbox_gid}"; then
        _group_outcome=unknown _group_detail="no ACL specification for uid ${_operator_uid}"
        return 0
    fi
    _need=rw-
    if [[ "${_type}" == directory ]] || (( (8#${_mode} & 8#111) != 0 )); then _need=rwx; fi
    if [[ "${_type}" == directory ]]; then
        _sets+=(_default)
        if (( ${#_default[@]} == 0 )); then
            _group_detail="the directory has no default ACL"
            return 0
        fi
    fi
    IFS=, read -r -a _entries <<< "${_specification}"
    for _set in "${_sets[@]}"; do
        for _entry in "${_entries[@]}"; do
            _key="${_entry%:*}"
            if [[ "${_key}" == other: ]]; then
                ai_tools_project_permissions_acl_effective_permissions _have "${_set}" other:
                [[ "${_have}" == --- ]] && continue
                _group_detail="${_set#_}: other:: grants ${_have}, not ---"
                return 0
            fi
            ai_tools_project_permissions_acl_effective_permissions _have "${_set}" "${_key}"
            for _index in 0 1 2; do
                if [[ "${_need:_index:1}" != - && "${_have:_index:1}" != "${_need:_index:1}" ]]; then
                    _group_detail="${_set#_}: ${_key}: grants ${_have:-no entry} in effect, not ${_need}"
                    return 0
                fi
            done
        done
    done
    _group_outcome=match _group_detail=""
}
