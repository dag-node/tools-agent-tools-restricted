// SPDX-License-Identifier: AGPL-3.0-only
// clients/typesafe/src/parsers.mts
// Turns a listing on stdin into items with stable ids. `lines` reads one item per line and takes a leading
// `path:line:` (grep, rg, `shellcheck -f gcc`) as the id, else `L<n>`; `prose-check` reads the checker's two-line
// records, `path:line: rule [token] -- hint` followed by the indented excerpt, so the rule travels apart from the
// text; `msbuild` reads a `dotnet build` or `dotnet test` log and keeps its diagnostics, since such a log carries
// its compiler command lines and its restore chatter in the same stream and one of those lines can be tens of
// kilobytes.
//
// `lines` and `prose-check` make an item of every non-empty line: a line that does not match a `prose-check`
// record raises an input error naming it. `msbuild` sets non-diagnostic lines aside by design -- that is what
// makes it a pre-filter -- and returns the count so the caller reports how much of the log it did not send.
//
// An id derived from a line is used only where core.mts would accept it. A prose sentence carrying a clock time
// ("Build started 9/22/2026 10:18:09 AM.") matches a `path:line:` prefix, so the derived id is checked against the
// same grammar that validates it later and the line falls back to `L<n>` rather than failing the whole listing.
//
// Every format reads input the session did not write -- a compiler's message quotes a source file, a dependency
// name and a string literal -- so `parse` holds stdin to text within a size bound before a format sees it, and
// refuses a stream carrying a NUL or a run of undecodable bytes rather than sending a binary file to the provider.
// A line past `maxParseLineChars` is not matched against a pattern at all: a build log's compiler invocation runs
// to tens of kilobytes, no diagnostic is that long, and a lazy pattern over a line of that size is work an input
// can ask for.
import { isItemId, LIMITS } from "./core.mjs";
import { inputError } from "./errors.mjs";
export const FORMATS = ["lines", "prose-check", "msbuild"];
const LOCATION = /^([^\s:][^:]*:\d+):\s?(.*)$/;
/** One item per non-empty line; the `path:line` prefix is the id when it is a well-formed one. */
export function parseLines(text) {
    const items = [];
    let n = 0;
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trimEnd();
        if (line.trim() === "")
            continue;
        n++;
        const m = line.length > LIMITS.maxParseLineChars ? null : LOCATION.exec(line);
        const derived = m?.[1];
        items.push(derived !== undefined && isItemId(derived) ? { id: derived, text: line } : { id: `L${n}`, text: line });
    }
    return { items, setAside: 0 };
}
const FINDING = /^([^\s:][^:]*:\d+):\s+(.+)$/;
/** prose-check.py records: a `path:line: rule...` line followed by one indented excerpt line. */
export function parseProseCheck(text) {
    const items = [];
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i] ?? "";
        if (line.trim() === "")
            continue;
        if (/^\d+ finding\(s\)/.test(line) || line.startsWith("See the "))
            continue; // the checker's trailer
        const m = FINDING.exec(line);
        if (!m)
            throw inputError(`line ${i + 1} is not a prose-check finding: ${line.slice(0, 80)}`, { line: i + 1 });
        const next = lines[i + 1] ?? "";
        if (!/^\s+\S/.test(next))
            throw inputError(`finding at line ${i + 1} has no excerpt line under it`, { line: i + 1 });
        items.push({ id: m[1], rule: m[2], text: next.trim() });
        i++;
    }
    return { items, setAside: 0 };
}
// A diagnostic as MSBuild and the compilers write it, with the optional node prefix (`2>`) the parallel build adds:
//     src/Service/ModelProfiles.cs(236,76): error CS1061: 'X' has no definition for 'Y' [/path/Service.csproj]
//     CSC : error CS2001: Source file '/path/.editorconfig' could not be found. [/path/Service.csproj]
const DIAGNOSTIC = /^\s*(?:\d+>)?\s*(.+?)\s*:\s*(error|warning)\s+([A-Za-z]+[0-9]+)\s*:\s*(.+?)\s*$/;
// The project a diagnostic is attributed to, which MSBuild appends in brackets.
const PROJECT_SUFFIX = /\s*\[([^\]]+\.(?:cs|fs|vb)proj)\]$/;
// `File.cs(line,col)` and `File.cs(line)` as the compilers write a location, against `path:line` everywhere else.
const CS_LOCATION = /^(.*?)\((\d+)(?:,\d+)?\)$/;
/**
 * A `dotnet build` / `dotnet test` log, reduced to its diagnostics. MSBuild reports each diagnostic twice -- once
 * under the project and once in the summary -- so a repeat of the same location, code and message is one item.
 */
export function parseMsbuild(text) {
    const items = [];
    const seen = new Set();
    let nonEmpty = 0;
    let n = 0;
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trimEnd();
        if (line.trim() === "")
            continue;
        nonEmpty++;
        // A compiler invocation line runs to tens of kilobytes, past any diagnostic: set it aside unmatched.
        if (line.length > LIMITS.maxParseLineChars)
            continue;
        const m = DIAGNOSTIC.exec(line);
        if (!m)
            continue;
        const [, rawLocation, severity, code, rawMessage] = m;
        const project = PROJECT_SUFFIX.exec(rawMessage)?.[1];
        const message = rawMessage.replace(PROJECT_SUFFIX, "");
        const key = `${rawLocation}|${code}|${message}`;
        if (seen.has(key))
            continue;
        seen.add(key);
        n++;
        const cs = CS_LOCATION.exec(rawLocation);
        const derived = cs === undefined || cs === null ? rawLocation : `${cs[1]}:${cs[2]}`;
        const item = {
            id: isItemId(derived) && !seen.has(`id:${derived}`) ? derived : `L${n}`,
            rule: `${severity} ${code}`,
            text: message,
            ...(project === undefined ? {} : { context: project }),
        };
        seen.add(`id:${item.id}`);
        items.push(item);
    }
    if (items.length === 0) {
        throw inputError(`the log holds no error or warning diagnostic in ${nonEmpty} non-empty lines; pipe it as --format lines to judge the lines themselves`, { lines: nonEmpty });
    }
    return { items, setAside: nonEmpty - items.length };
}
/**
 * Refuses a stream that is not text a listing could be: over the size bound, carrying a NUL, or holding more than
 * one control or undecodable character per hundred in its first 64 KiB. `readFileSync(0, "utf8")` decodes an
 * undecodable byte to U+FFFD rather than failing, so the replacement character is counted here as the evidence it
 * is. Tab, newline and carriage return are text.
 */
export function assertTextual(text) {
    if (text.length > LIMITS.maxInputChars) {
        throw inputError(`the input is ${text.length} characters; the bound is ${LIMITS.maxInputChars}. Narrow the listing at its source`, { chars: text.length });
    }
    const sample = text.slice(0, 65_536);
    if (sample.includes("\u0000"))
        throw inputError("the input holds a NUL byte, so it is not a text listing");
    let suspect = 0;
    for (const ch of sample) {
        const code = ch.codePointAt(0);
        if (ch === "\t" || ch === "\n" || ch === "\r")
            continue;
        if (code < 0x20 || code === 0x7f || ch === "\uFFFD")
            suspect++;
    }
    if (sample.length > 0 && suspect * 100 > sample.length) {
        throw inputError(`the input holds ${suspect} control or undecodable characters in its first ${sample.length}, so it is not a text listing`, { suspect });
    }
}
export function parse(format, text) {
    assertTextual(text);
    switch (format) {
        case "lines":
            return parseLines(text);
        case "prose-check":
            return parseProseCheck(text);
        case "msbuild":
            return parseMsbuild(text);
    }
}
