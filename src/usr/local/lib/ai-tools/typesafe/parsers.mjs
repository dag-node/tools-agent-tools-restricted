// SPDX-License-Identifier: AGPL-3.0-only
// clients/typesafe/src/parsers.mts
// Turns a listing on stdin into items with stable ids. `lines` reads one item per line and takes a leading
// `path:line:` (grep, rg, `shellcheck -f gcc`) as the id, else `L<n>`; `prose-check` reads the checker's two-line
// records, `path:line: rule [token] -- hint` followed by the indented excerpt, so the rule travels apart from the
// text. A parser never drops a non-empty line silently: a line it cannot place is an input error naming it.
import { inputError } from "./errors.mjs";
export const FORMATS = ["lines", "prose-check"];
const LOCATION = /^([^\s:][^:]*:\d+):\s?(.*)$/;
/** One item per non-empty line; the `path:line` prefix is the id when present. */
export function parseLines(text) {
    const items = [];
    let n = 0;
    for (const raw of text.split(/\r?\n/)) {
        const line = raw.trimEnd();
        if (line.trim() === "")
            continue;
        n++;
        const m = LOCATION.exec(line);
        items.push(m ? { id: m[1], text: line } : { id: `L${n}`, text: line });
    }
    return items;
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
    return items;
}
export function parse(format, text) {
    switch (format) {
        case "lines":
            return parseLines(text);
        case "prose-check":
            return parseProseCheck(text);
    }
}
