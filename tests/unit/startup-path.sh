#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/startup-path.sh
# The runtime half of the start every root helper shares (cli.rule.md, ref-section-g7c8), which the confinement shim
# and the updater under /opt/ai-tools/bin take as well (launch.rule.md, updater.rule.md).
#
# Four parts, each reading more of a host than the one before:
#
#   1. The checker, over fixtures it must report and one it must pass, so a clean reading of the tree is evidence about
#      the tree and not about a checker that accepts every file.
#   2. Every file in the checkout's three program directories: the root helpers, the contributed commands,
#      and /opt/ai-tools/bin. The directory listing is the set, so a program added later is read without a list
#      to maintain. A program's PATH line is the root helpers' value unless PATH_LITERAL_BY_PROGRAM names it.
#   3. The mechanics, on a synthetic program built from each of three real heads (a root helper's, the shim's
#      and the updater's): line 1 through `export PATH`, then a call to the command the program runs first by name.
#      Recorders named `bash`, `id` and `mktemp` lead the caller's PATH, and the run must reach none of them, beside
#      three controls that each undo one part of the head and show what it kept out. The installed updater is not run:
#      its argument is a version, and before its identity guard it installs the EXIT trap that rewrites the live stamp.
#   4. As root, every installed file through the same checker, and two installed helpers run to a usage refusal under
#      a PATH led by a root-owned recorder directory. The recorders are root's own files: a run that reached one would
#      execute it as root, and the suite does not execute a file another account can write (tests.rule.md).
#
# Parts 1 and 2 need neither root nor an install. Parts 3 and 4 exec fixture files, so they need a directory
# where a 0755 file is executable: the testdir where it qualifies, and a fixture directory in the projects user's home
# otherwise, each held first to a chain of directories another account cannot replace an entry in. The boundary half is
# tests/boundary/access.sh: the sandbox account writes none of the directories the PATH names.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CHECKOUT_DIRS=("${ROOT}/src/usr/local/libexec/ai-tools" "${ROOT}/src/usr/local/lib/ai-tools/admin-commands.d"
    "${ROOT}/src/opt/ai-tools/bin")
readonly INSTALLED_DIRS=(/usr/local/libexec/ai-tools /usr/local/lib/ai-tools/admin-commands.d /opt/ai-tools/bin)
readonly NVM_UPDATE_UNIT=/usr/lib/systemd/user/nvm-update.service
readonly SHELL_LINE='#!/usr/bin/bash -p'
readonly PATH_LINE='PATH=/usr/sbin:/usr/bin:/sbin:/bin'
# A program whose PATH line is another value, by program name: the updater carries its unit's PATH (updater.rule.md).
declare -rA PATH_LITERAL_BY_PROGRAM=([nvm-update]='PATH=/usr/local/bin:/usr/bin:/bin')
# The programs that take the shell start whatever their first line, by program name: the shim and the updater,
# which the launch and the update unit run as bash.
declare -rA SHELL_START_PROGRAMS=([ai-tools-run]=1 [nvm-update]=1)
# The Python helpers whose line does not pass `-I`, by name; the rule states why (cli.rule.md, ref-section-g7c8).
readonly PYTHON_WITHOUT_ISOLATION=(ai-tools-handback)

# get_program_name <file>: the program a file is, its basename without `.sh` or `.py`, so a checkout source and its
# installed copy read as one program whichever name the package installs it under.
get_program_name() {
    local name="${1##*/}"
    name="${name%.sh}"
    printf '%s\n' "${name%.py}"
}

# read_startup_finding <file>: print what <file>'s start lacks, or no line where it conforms. A shell program opens
# with SHELL_LINE and its first three statements are a `set` line ending in `pipefail`, its PATH line and `export PATH`,
# comments and blank lines aside; the PATH line is PATH_LINE unless PATH_LITERAL_BY_PROGRAM names the program. A Python
# helper opens with /usr/bin/python3 and one option cluster holding `I`, and with /usr/bin/python3 alone
# where PYTHON_WITHOUT_ISOLATION names it; a program SHELL_START_PROGRAMS names is held to the shell start alone.
# Returns 2 for a file it cannot read, which is a reading not made and never a conforming file.
read_startup_finding() {
    local file="$1" first line name exempt path_line
    local -a statements=()
    [[ -f "${file}" && -r "${file}" ]] || return 2
    IFS= read -r first < "${file}" || return 2
    name="$(get_program_name "${file}")"
    path_line="${PATH_LITERAL_BY_PROGRAM[${name}]:-${PATH_LINE}}"
    if [[ -z "${SHELL_START_PROGRAMS[${name}]:-}" ]]; then
        if [[ "${first}" =~ ^'#!/usr/bin/python3 -'[A-Za-z]*I[A-Za-z]*$ ]]; then
            return 0
        fi
        if [[ "${first}" == '#!/usr/bin/python3' ]]; then
            for exempt in "${PYTHON_WITHOUT_ISOLATION[@]}"; do
                [[ "${name}" != "${exempt}" ]] || return 0
            done
            printf 'the interpreter line does not start Python in isolated mode (-I): %s\n' "${first}"
            return 0
        fi
    fi
    if [[ "${first}" != "${SHELL_LINE}" ]]; then
        printf 'the interpreter line is %s\n' "${first}"
        return 0
    fi
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
        statements+=("${line}")
        (( ${#statements[@]} < 3 )) || break
    done < <(tail -n +2 -- "${file}")
    if [[ ! "${statements[0]:-}" =~ ^set\ -[a-z]+\ pipefail$ ]]; then
        printf 'the first statement is not the set line: %s\n' "${statements[0]:-}"
    elif [[ "${statements[1]:-}" != "${path_line}" ]]; then
        printf 'the statement after the set line is not %s: %s\n' "${path_line}" "${statements[1]:-}"
    elif [[ "${statements[2]:-}" != 'export PATH' ]]; then
        printf 'the PATH line is not followed by export PATH: %s\n' "${statements[2]:-}"
    fi
}

# check_directory <label> <dir>: every regular file in <dir> through the checker. One failure per file that does not
# conform or could not be read, and one pass carrying the count, so a listing that found no file is not a pass.
check_directory() {
    local label="$1" dir="$2" file finding status count=0 bad=0
    for file in "${dir}"/*; do
        [[ -f "${file}" && ! -L "${file}" ]] || continue
        count=$(( count + 1 ))
        status=0
        finding="$(read_startup_finding "${file}")" || status=$?
        if (( status != 0 )); then
            fail "${label}: ${file##*/} could not be read"; bad=$(( bad + 1 ))
        elif [[ -n "${finding}" ]]; then
            fail "${label}: ${file##*/}: ${finding}"; bad=$(( bad + 1 ))
        fi
    done
    if (( count == 0 )); then
        fail "${label}: no file found in ${dir}"
    elif (( bad == 0 )); then
        pass "${label}: each of the ${count} file(s) in ${dir} opens with the fixed interpreter line and PATH"
    fi
}

# require_program <label> <dir> <file>: <dir>/<file> is a regular file and not a link, so check_directory read it.
# The listing is the set a program added later joins; this holds the programs that have no runtime test of their
# installed copy to the read, so a copy absent or replaced by a link does not leave the directory's pass standing.
require_program() {
    local label="$1" dir="$2" file="$3"
    if [[ -f "${dir}/${file}" && ! -L "${dir}/${file}" ]]; then
        pass "${label}: ${dir}/${file} is a regular file and was read"
    else
        fail "${label}: ${dir}/${file} is absent or not a regular file, so its start was not read"
    fi
}

mktestdir

# ── 1. The checker ───────────────────────────────────────────────────────────────────────────
section "program start: the checker reports each departure (unit)"
fixtures="${TESTDIR}/fixtures"
mkdir -p "${fixtures}"
# write_fixture <name> <line>...: one fixture file from its lines.
write_fixture() { local name="$1"; shift; printf '%s\n' "$@" > "${fixtures}/${name}"; }
write_fixture conforming   "${SHELL_LINE}" '# SPDX' '' '# header' 'set -euo pipefail' '' '# why' "${PATH_LINE}" 'export PATH' 'id'
write_fixture no-errexit   "${SHELL_LINE}" 'set -uo pipefail' "${PATH_LINE}" 'export PATH'
write_fixture env-line     '#!/usr/bin/env bash' 'set -euo pipefail' "${PATH_LINE}" 'export PATH'
write_fixture no-privilege '#!/usr/bin/bash' 'set -euo pipefail' "${PATH_LINE}" 'export PATH'
write_fixture no-pin       "${SHELL_LINE}" 'set -euo pipefail' 'readonly NAME=value'
write_fixture late-pin     "${SHELL_LINE}" 'set -euo pipefail' 'NAME="$(id -un)"' "${PATH_LINE}" 'export PATH'
write_fixture other-path   "${SHELL_LINE}" 'set -euo pipefail' 'PATH=/usr/local/bin:/usr/bin' 'export PATH'
write_fixture no-export    "${SHELL_LINE}" 'set -euo pipefail' "${PATH_LINE}" 'readonly NAME=value'
write_fixture no-set       "${SHELL_LINE}" "${PATH_LINE}" 'export PATH'
write_fixture python-isolated      '#!/usr/bin/python3 -I' 'import os'
write_fixture python-cluster       '#!/usr/bin/python3 -IBu' 'import os'
write_fixture ai-tools-handback.py '#!/usr/bin/python3' 'import os'
write_fixture python-bare          '#!/usr/bin/python3' 'import os'
write_fixture python-other-flag    '#!/usr/bin/python3 -B' 'import os'
write_fixture python-env           '#!/usr/bin/env python3' 'import os'
# The updater's literal is read by program name, in both trees' names: under another name the same file is reported,
# and the updater's name with the root helpers' literal is reported too.
write_fixture nvm-update.sh   "${SHELL_LINE}" 'set -euo pipefail' "${PATH_LITERAL_BY_PROGRAM[nvm-update]}" 'export PATH'
write_fixture updater-literal "${SHELL_LINE}" 'set -euo pipefail' "${PATH_LITERAL_BY_PROGRAM[nvm-update]}" 'export PATH'
write_fixture nvm-update      "${SHELL_LINE}" 'set -euo pipefail' "${PATH_LINE}" 'export PATH'
# The shim and the updater are held to the shell start, so an isolated Python line under either name is reported.
mkdir -p "${fixtures}/python-named"
printf '%s\n' '#!/usr/bin/python3 -I' 'import os' > "${fixtures}/python-named/nvm-update.sh"
printf '%s\n' '#!/usr/bin/python3 -I' 'import os' > "${fixtures}/python-named/ai-tools-run"

for name in conforming no-errexit python-isolated python-cluster ai-tools-handback.py nvm-update.sh; do
    status=0; finding="$(read_startup_finding "${fixtures}/${name}")" || status=$?
    if (( status == 0 )) && [[ -z "${finding}" ]]; then
        pass "the checker passes the ${name} fixture"
    else
        fail "the checker reported the ${name} fixture (status ${status}): ${finding}"
    fi
done
while IFS='|' read -r name want; do
    status=0; finding="$(read_startup_finding "${fixtures}/${name}")" || status=$?
    if (( status == 0 )) && [[ "${finding}" == "${want}"* ]]; then
        pass "the checker reports the ${name} fixture"
    else
        fail "the checker read the ${name} fixture as (status ${status}): ${finding:-conforming}"
    fi
done <<'EOF'
env-line|the interpreter line is #!/usr/bin/env bash
no-privilege|the interpreter line is #!/usr/bin/bash
python-env|the interpreter line is #!/usr/bin/env python3
python-bare|the interpreter line does not start Python in isolated mode
python-other-flag|the interpreter line is #!/usr/bin/python3 -B
no-pin|the statement after the set line is not
late-pin|the statement after the set line is not
other-path|the statement after the set line is not
no-export|the PATH line is not followed by export PATH
no-set|the first statement is not the set line
updater-literal|the statement after the set line is not PATH=/usr/sbin:/usr/bin:/sbin:/bin
nvm-update|the statement after the set line is not PATH=/usr/local/bin:/usr/bin:/bin
python-named/nvm-update.sh|the interpreter line is #!/usr/bin/python3 -I
python-named/ai-tools-run|the interpreter line is #!/usr/bin/python3 -I
EOF
status=0; read_startup_finding "${fixtures}/absent" > /dev/null || status=$?
if (( status == 2 )); then
    pass "a file the checker cannot read is a reading not made (status 2)"
else
    fail "a missing file read as status ${status}"
fi

# ── 2. The checkout ──────────────────────────────────────────────────────────────────────────
section "program start: every program in the checkout (unit)"
for dir in "${CHECKOUT_DIRS[@]}"; do
    if [[ -d "${dir}" ]]; then
        check_directory "checkout" "${dir}"
    else
        skip "checkout programs" "${dir} is not in this tree"
    fi
done
if [[ -d "${CHECKOUT_DIRS[2]}" ]]; then
    require_program "checkout" "${CHECKOUT_DIRS[2]}" ai-tools-run.sh
    require_program "checkout" "${CHECKOUT_DIRS[2]}" nvm-update.sh
fi

# ── 3. The mechanics ─────────────────────────────────────────────────────────────────────────
section "program start: a caller's PATH, BASH_ENV and exported function do not reach the program (unit)"
# x_bit_visible <dir>: succeed when a 0755 file created there reads as executable (tests/unit/atr.sh's probe).
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}
# The heads the mechanics are built from, one per line: <label>|<checkout source>|<installed copy>|<first command>.
# The first command is the one the program runs by name before any other, so a head without its PATH lines reaches its
# recorder.
readonly HEAD_SOURCES="root helper|${CHECKOUT_DIRS[0]}/ai-tools-chown.sh|${INSTALLED_DIRS[0]}/ai-tools-chown|id
shim|${CHECKOUT_DIRS[2]}/ai-tools-run.sh|${INSTALLED_DIRS[2]}/ai-tools-run|id
updater|${CHECKOUT_DIRS[2]}/nvm-update.sh|${INSTALLED_DIRS[2]}/nvm-update.sh|mktemp"
# The directory the fixtures are written and run from: the testdir where a 0755 file is executable there, and a fixture
# directory in the projects user's home otherwise. Root writes recorders there by path and part 4 executes them as root,
# so the directory and each ancestor are held first to owners another account cannot replace an entry under, root
# and the projects user (harness.sh, read_unheld_component), and the fixture directory again once mktemp made it.
# A chain that does not hold fails the mechanics with no fixture written there.
work="" work_unheld="" unheld_reading=""
unheld_reading="$(read_unheld_component "${TESTDIR}" 0 "${PROJECTS_UID}")"
if [[ -n "${unheld_reading}" ]]; then
    work_unheld="${unheld_reading}"
else
    mkdir -p "${TESTDIR}/mechanics"
    if x_bit_visible "${TESTDIR}/mechanics"; then work="${TESTDIR}/mechanics"; fi
fi
if [[ -z "${work}" ]]; then
    unheld_reading="$(read_unheld_component "${PROJECTS_HOME}" 0 "${PROJECTS_UID}")"
    if [[ -z "${unheld_reading}" ]] && mk_fixture_dir work "${PROJECTS_HOME}" startup 2>/dev/null && [[ -n "${work}" ]]; then
        unheld_reading="$(read_unheld_component "${work}" 0 "${PROJECTS_UID}")"
        if [[ -n "${unheld_reading}" ]] || ! x_bit_visible "${work}"; then work=""; fi
    else
        work=""
    fi
    [[ -z "${unheld_reading}" ]] || work_unheld+="${work_unheld:+; }${unheld_reading}"
fi
if [[ -z "${work}" && -n "${work_unheld}" ]]; then
    fail "the mechanics: another account could replace an entry in ${work_unheld}, so no fixture is written or run there"
elif [[ -z "${work}" ]]; then
    skip_required "the mechanics" "no directory here reports a 0755 file as executable (a noexec mount)"
else
    chmod 0755 "${work}"
    plant="${work}/plant"; log="${work}/log"
    mkdir -p "${plant}"
    for name in bash id mktemp; do
        printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexit 97\n' "${name}" "${log}" > "${plant}/${name}"
        chmod 0755 "${plant}/${name}"
    done
    printf 'printf "bash-env\\n" >> "%s"\n' "${log}" > "${work}/bash-env"

    # run_start <file>: run <file> through its own interpreter line under the hostile caller's environment; sets
    # start_out (its stdout) and start_log (the recorders' and the BASH_ENV file's lines, one per call).
    run_start() {
        rm -f "${log}"
        start_out="$(env -i PATH="${plant}:/usr/bin:/bin" BASH_ENV="${work}/bash-env" \
            'BASH_FUNC_planted_function%%=() { :; }' "$1" 2>/dev/null)" || true
        start_log=""
        [[ ! -f "${log}" ]] || start_log="$(tr '\n' ' ' < "${log}")"
    }

    # drive_head <label> <source> <command>: a synthetic program from <source>'s own text through its `export PATH`
    # line, whose body calls <command> and names an imported function where it finds one, run with the three controls.
    # The body exits before any line of the program past its head.
    drive_head() {
        local label="$1" source="$2" command="$3" path_line synthetic="${work}/${1// /-}"
        path_line="${PATH_LITERAL_BY_PROGRAM[$(get_program_name "${source}")]:-${PATH_LINE}}"
        {
            sed -n '1,/^export PATH$/p' -- "${source}"
            printf '%s\n' "${command} > /dev/null 2>&1 || true" \
                'if declare -F planted_function > /dev/null; then printf "function\n"; fi' 'printf "end\n"' 'exit 0'
        } > "${synthetic}"
        sed '1s|.*|#!/usr/bin/env bash|' -- "${synthetic}" > "${synthetic}-env-line"
        grep -vxF -e "${path_line}" -e 'export PATH' -- "${synthetic}" > "${synthetic}-no-pin" || true
        sed '1s|.*|#!/usr/bin/bash|' -- "${synthetic}" > "${synthetic}-no-privilege"
        chmod 0755 "${synthetic}" "${synthetic}-env-line" "${synthetic}-no-pin" "${synthetic}-no-privilege"

        if ! grep -qxF "${path_line}" "${synthetic}" || [[ "$(head -n 1 "${synthetic}")" != "${SHELL_LINE}" ]]; then
            fail "the ${label}'s head does not carry the interpreter line and its PATH line, so the mechanics are not driven"
            return 0
        fi
        run_start "${synthetic}"
        if [[ "${start_out}" == end && -z "${start_log}" ]]; then
            pass "the ${label}'s head keeps the caller's bash, ${command}, BASH_ENV file and exported function out of the run"
        else
            fail "the run under the ${label}'s head printed '${start_out}' and reached: ${start_log:-nothing}"
        fi
        run_start "${synthetic}-env-line"
        if [[ "${start_log}" == 'bash ' ]]; then
            pass "control: with an env interpreter line the caller's bash runs in the ${label}'s place"
        else
            fail "control: the ${label}'s head with an env interpreter line did not reach the planted bash (reached: ${start_log:-nothing})"
        fi
        run_start "${synthetic}-no-pin"
        if [[ "${start_out}" == end && "${start_log}" == "${command} " ]]; then
            pass "control: without the PATH lines the ${label} runs the caller's ${command}"
        else
            fail "control: the ${label}'s head without its PATH lines printed '${start_out}' and reached: ${start_log:-nothing}"
        fi
        run_start "${synthetic}-no-privilege"
        if [[ "${start_out}" == $'function\nend' && "${start_log}" == 'bash-env ' ]]; then
            pass "control: without -p the ${label} takes the BASH_ENV file and the exported function"
        else
            fail "control: the ${label}'s head without -p printed '${start_out}' and reached: ${start_log:-nothing}"
        fi
    }

    while IFS='|' read -r head_label head_checkout head_installed head_command; do
        head_source="${head_checkout}"
        [[ -r "${head_source}" ]] || head_source="${head_installed}"
        if [[ -r "${head_source}" ]]; then
            drive_head "${head_label}" "${head_source}" "${head_command}"
        else
            skip "the ${head_label}'s mechanics" "neither ${head_checkout} nor ${head_installed} is readable to take the head from"
        fi
    done <<< "${HEAD_SOURCES}"

    # The walker's own interpreter line over a script that imports a module the caller's PYTHONPATH names. The module
    # writes the log when it loads; the control is the same script on /usr/bin/python3 without an option.
    walker_source="${CHECKOUT_DIRS[0]}/ai-tools-relabel-tree.py"
    [[ -r "${walker_source}" ]] || walker_source="${INSTALLED_DIRS[0]}/ai-tools-relabel-tree"
    if [[ ! -r "${walker_source}" ]]; then
        skip "the walker's isolated start" "the walker is not readable to take its interpreter line from"
    else
        mkdir -p "${work}/pymod"
        printf 'open(%s, "a").write("python-module\\n")\n' "'${log}'" > "${work}/pymod/ai_tools_planted.py"
        {
            head -n 1 -- "${walker_source}"
            printf '%s\n' 'try:' '    import ai_tools_planted' 'except ImportError:' '    pass' 'print("end")'
        } > "${work}/walker"
        sed '1s|.*|#!/usr/bin/python3|' -- "${work}/walker" > "${work}/walker-not-isolated"
        chmod 0755 "${work}/walker" "${work}/walker-not-isolated"
        # run_walker <file>: sets start_out and start_log as run_start does.
        run_walker() {
            rm -f "${log}"
            start_out="$(env -i PATH=/usr/bin:/bin PYTHONPATH="${work}/pymod" PYTHONDONTWRITEBYTECODE=1 "$1" 2>/dev/null)" || true
            start_log=""
            [[ ! -f "${log}" ]] || start_log="$(tr '\n' ' ' < "${log}")"
        }
        run_walker "${work}/walker"
        if [[ "${start_out}" == end && -z "${start_log}" ]]; then
            pass "the walker's interpreter line keeps a module on the caller's PYTHONPATH out of the run"
        else
            fail "the run under the walker's interpreter line printed '${start_out}' and reached: ${start_log:-nothing}"
        fi
        run_walker "${work}/walker-not-isolated"
        if [[ "${start_out}" == end && "${start_log}" == 'python-module ' ]]; then
            pass "control: without -I the script imports the caller's module"
        else
            fail "control: python3 without -I printed '${start_out}' and reached: ${start_log:-nothing}"
        fi
    fi
fi

# ── 4. The installed programs ────────────────────────────────────────────────────────────────
section "program start: the installed programs (unit)"
if [[ "${EUID}" -ne 0 ]]; then
    skip "the installed programs" "the helper directory is root's alone, so this part runs as root"
elif [[ ! -d "${INSTALLED_DIRS[0]}" ]]; then
    skip "the installed programs" "not installed at ${INSTALLED_DIRS[0]}"
else
    for dir in "${INSTALLED_DIRS[@]}"; do
        if [[ -d "${dir}" ]]; then
            check_directory "installed" "${dir}"
        elif [[ "${dir}" == "${INSTALLED_DIRS[1]}" ]]; then
            note "installed programs" "${dir} is absent: no package on this host contributes a command"
        else
            fail "installed programs: ${dir} is absent beside ${INSTALLED_DIRS[0]}"
        fi
    done
    # ai-tools-base installs the shim beside the helpers. The updater ships with its unit
    # in ai-tools-integration-nodejs, so it is required where that unit is installed.
    require_program "installed" "${INSTALLED_DIRS[2]}" ai-tools-run
    if [[ -e "${NVM_UPDATE_UNIT}" || -L "${NVM_UPDATE_UNIT}" ]]; then
        require_program "installed" "${INSTALLED_DIRS[2]}" nvm-update.sh
    else
        note "installed programs" "${NVM_UPDATE_UNIT} is absent: ai-tools-integration-nodejs is not installed, so the updater is not required"
    fi

    # A root-owned recorder for each command the two runs resolve, first on PATH, in the directory the mechanics found
    # executable: root made it, and the sandbox account does not write it. The control shows a shell that does not set
    # its own PATH takes the recorder.
    root_plant="${work:+${work}/root-plant}"; root_log="${work:+${work}/root-plant.log}"
    if [[ -n "${root_plant}" ]]; then
        mkdir -p "${root_plant}"
        for name in bash python3 env id date logger; do
            printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexit 97\n' "${name}" "${root_log}" > "${root_plant}/${name}"
            chmod 0755 "${root_plant}/${name}"
        done
    fi
    if [[ -z "${root_plant}" ]] || ! x_bit_visible "${root_plant}"; then
        skip_required "installed helpers under a planted PATH" "no directory here reports a 0755 file as executable (a noexec mount)"
    else
        env -i PATH="${root_plant}:/usr/bin:/bin" /bin/sh -c 'date' > /dev/null 2>&1 || true
        if [[ "$(cat "${root_log}" 2>/dev/null)" != date ]]; then
            fail "control: a shell under the planted PATH did not run the planted date, so the runs below show nothing"
        else
            pass "control: a shell that keeps its caller's PATH runs the planted date"
            # The harness's log directory goes with the run, so a helper's refusal line lands there and not
            # in the host's own trail.
            planted_env=(PATH="${root_plant}:/usr/bin:/bin")
            [[ -z "${AI_TOOLS_LOG_DIR:-}" ]] || planted_env+=(AI_TOOLS_LOG_DIR="${AI_TOOLS_LOG_DIR}")
            # run_planted <want-status> <what> <helper> [<arg>...]: the helper under the planted PATH, held to its usage
            # status and to an empty recorder log.
            run_planted() {
                local want="$1" what="$2" status=0 reached=""; shift 2
                rm -f "${root_log}"
                env -i "${planted_env[@]}" "$@" > /dev/null 2>&1 < /dev/null || status=$?
                [[ ! -f "${root_log}" ]] || reached="$(tr '\n' ' ' < "${root_log}")"
                if [[ "${status}" == "${want}" && -z "${reached}" ]]; then
                    pass "${what} exits ${want} under a planted PATH and runs no planted command"
                else
                    fail "${what} under a planted PATH: exit ${status}, reached: ${reached:-no planted command}"
                fi
            }
            if [[ -x "${INSTALLED_DIRS[0]}/ai-tools-audit" ]]; then
                run_planted 2 "ai-tools-audit with a --since value date does not parse" \
                    "${INSTALLED_DIRS[0]}/ai-tools-audit" --since 'not a date'
            else
                skip "ai-tools-audit under a planted PATH" "not installed"
            fi
            if [[ -x "${INSTALLED_DIRS[0]}/ai-tools-relabel-tree" ]]; then
                run_planted 2 "ai-tools-relabel-tree with no directory" "${INSTALLED_DIRS[0]}/ai-tools-relabel-tree"
            else
                skip "ai-tools-relabel-tree under a planted PATH" "not installed"
            fi
        fi
    fi
fi

finish
